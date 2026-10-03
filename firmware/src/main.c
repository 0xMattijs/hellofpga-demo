/* Camera breakout: hold up a colored object and move it to steer the
 * paddle. The fabric finds the object (hdl/src/color_track.v) and draws the
 * game over the live video (hdl/src/game_overlay.v); the Cortex-M3 runs the
 * game (game.c) once per camera frame.
 *
 * Buttons (left to right above the LCD: SW3, SW2, SW1):
 *   SW1  serve now; after a game over, a new game; before the first
 *        calibration, calibrate
 *   SW2  paddle width: wide, normal, narrow
 *   SW3  calibrate: hold the object in the box on screen
 *
 * With a PC on the serial port (tools/scoreboard.py), the firmware reports
 * calibrations, levels, and final scores. */
#include <stdint.h>
#include "m2sxxx.h"
#include "system_m2sxxx.h"
#include "config.h"
#include "game.h"
#include "hw.h"
#include "track.h"
#include "uart.h"
#include "camera.h"
#include "ili9488.h"

#define FRAME_W      640

/* A button counts as pressed or released once it has held still this long. */
#define DEBOUNCE_MS  20

/* gfedcba */
static const uint8_t seg7[10] = {
    0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F
};
#define SEG_DASH 0x40

/* Button presses, one bit per button (SW1 = bit 0), set by the SysTick
 * handler and cleared by the main loop. */
static volatile uint32_t button_events;

/* Debounces the three push buttons; called every millisecond. */
static void poll_buttons(void)
{
    static uint32_t stable;
    static uint8_t  held[3];
    uint32_t raw = hw[REG_BUTTONS];
    for (int i = 0; i < 3; i++) {
        uint32_t bit = 1u << i;
        if ((raw ^ stable) & bit) {
            if (++held[i] >= DEBOUNCE_MS) {
                stable ^= bit;
                held[i] = 0;
                if (stable & bit)
                    button_events |= bit;
            }
        } else {
            held[i] = 0;
        }
    }
}

void SysTick_Handler(void)
{
    poll_buttons();
}

static uint32_t take_buttons(void)
{
    uint32_t ev = button_events;
    button_events &= ~ev;       /* SysTick only sets bits */
    return ev;
}

static enum {
    APP_IDLE,           /* not calibrated yet */
    APP_CAL_SETTLE,     /* camera adjusting to the light */
    APP_CAL_MEASURE,    /* averaging the calibration box */
    APP_GAME,
} app = APP_IDLE;

static game_t game;
static int    game_started;
static int    width_ix = 1;
static const int widths[] = PADDLE_WIDTHS;
#define N_WIDTHS ((int)(sizeof widths / sizeof widths[0]))

/* Calibration */
static uint32_t cal_start;
static int      cal_skip, cal_frames;
static uint32_t cal_r, cal_g, cal_b, cal_n;

/* Tracking */
static int   tracked;           /* the object was found in the last frame */
static int   marker_x, marker_y;
static float paddle_smooth = -1;

static int host;                /* the PC is listening */
static int serve_requested;     /* SW1 while the ball waits on the paddle */

static void say(const char *s)
{
    if (host)
        uart_puts(s);
}

static void say_u(uint32_t v)
{
    if (host)
        uart_putu(v);
}

static void start_calibration(void)
{
    camera_write(CAM_COM8, CAM_COM8_AUTO);
    cal_start = DWT->CYCCNT;
    app = APP_CAL_SETTLE;
}

static void finish_calibration(void)
{
    track_limits_t lim;
    float chroma = track_fit(cal_r, cal_g, cal_b, cal_n, &lim);
    hw[REG_TRACK_C] = (uint32_t)lim.cr_max << 24 | (uint32_t)lim.cr_min << 16 |
                      (uint32_t)lim.cb_max << 8 | lim.cb_min;
    hw[REG_TRACK_Y] = (uint32_t)lim.y_max << 8 | lim.y_min;
    paddle_smooth = -1;

    say("CAL Y ");   say_u(lim.y_min);  say(" "); say_u(lim.y_max);
    say(" Cb ");     say_u(lim.cb_min); say(" "); say_u(lim.cb_max);
    say(" Cr ");     say_u(lim.cr_min); say(" "); say_u(lim.cr_max);
    say(" chroma "); say_u(chroma < 0 ? 0 : (uint32_t)chroma);
    say("\r\n");
    if (chroma >= 0 && chroma < FIT_MIN_CHROMA)
        say("# the object is close to gray; try a strongly colored one\r\n");

    if (!game_started || game.state == GAME_OVER) {
        game_new(&game, widths[width_ix]);
        game_started = 1;
        say("START\r\n");
    } else {
        game_reserve(&game);
    }
    app = APP_GAME;
}

/* Called once per frame while calibrating. */
static void poll_calibration(void)
{
    if (app == APP_CAL_SETTLE) {
        uint32_t ms = (DWT->CYCCNT - cal_start) / (SystemCoreClock / 1000);
        if (ms < CAL_SETTLE_MS)
            return;
        camera_write(CAM_COM8, CAM_COM8_LOCKED);
        /* The frame in progress may have been exposed before the lock. */
        cal_skip = 2;
        cal_frames = 0;
        cal_r = cal_g = cal_b = cal_n = 0;
        app = APP_CAL_MEASURE;
    } else if (app == APP_CAL_MEASURE) {
        if (cal_skip > 0) {
            cal_skip--;
            return;
        }
        cal_r += hw[REG_BOX_R];
        cal_g += hw[REG_BOX_G];
        cal_b += hw[REG_BOX_B];
        cal_n += hw[REG_BOX_N];
        if (++cal_frames >= CAL_FRAMES)
            finish_calibration();
    }
}

/* Reads the tracker; returns the paddle's screen x, or -1 if the object is
 * lost. */
static int read_tracker(void)
{
    uint32_t n = hw[REG_TRACK_N];
    if (app != APP_GAME || n < TRACK_MIN_PIXELS) {
        tracked = 0;
        return -1;
    }
    tracked = 1;
    marker_x = hw[REG_TRACK_SX] / n;
    marker_y = hw[REG_TRACK_SY] / n;
    float x = UI_MIRROR ? FRAME_W - 1 - marker_x : marker_x;
    if (paddle_smooth < 0)
        paddle_smooth = x;
    else
        paddle_smooth += TRACK_SMOOTH * (x - paddle_smooth);
    return (int)(paddle_smooth + 0.5f);
}

static void handle_buttons(void)
{
    uint32_t ev = take_buttons();
    if (ev & 4) {
        start_calibration();
        return;
    }
    if (ev & 2) {
        width_ix = (width_ix + 1) % N_WIDTHS;
        game_set_paddle_width(&game, widths[width_ix]);
    }
    if (ev & 1) {
        if (app == APP_IDLE)
            start_calibration();
        else if (app == APP_GAME && game.state == GAME_OVER) {
            game_new(&game, widths[width_ix]);
            say("START\r\n");
        } else if (app == APP_GAME && game.state == GAME_SERVE)
            serve_requested = 1;
    }
}

static uint32_t digits_of(int n, int blank_zeros)
{
    uint32_t segs = 0;
    for (int i = 3; i >= 0; i--) {
        uint32_t s = seg7[n % 10];
        if (blank_zeros && n == 0 && i < 3)
            s = 0;
        segs |= s << (7 * i);
        n /= 10;
    }
    return segs;
}

static void draw(uint32_t frame)
{
    uint32_t ctrl = CTRL_ON | (UI_MIRROR ? CTRL_MIRROR : 0) | (UI_DIM ? CTRL_DIM : 0) |
                    CTRL_PADDLE;
    uint32_t digits;

    switch (app) {
    case APP_IDLE:
        ctrl |= CTRL_BOX;
        digits = SEG_DASH * (1u | 1u << 7 | 1u << 14 | 1u << 21);
        break;
    case APP_CAL_SETTLE: {
        uint32_t ms = (DWT->CYCCNT - cal_start) / (SystemCoreClock / 1000);
        uint32_t left = ms < CAL_SETTLE_MS ? (CAL_SETTLE_MS - ms + 999) / 1000 : 0;
        ctrl |= CTRL_BOX;
        digits = seg7[left % 10];       /* 3, 2, 1 in the rightmost digit */
        break;
    }
    case APP_CAL_MEASURE:
        ctrl |= CTRL_BOX;
        digits = SEG_DASH;
        break;
    default:
        if (game.state != GAME_OVER)
            ctrl |= CTRL_BALL;
        if (tracked)
            ctrl |= CTRL_MARKER;
        digits = digits_of(game.score, 1);
        if (game.state == GAME_OVER && (frame & 16))
            digits = 0;                 /* the final score blinks */
        break;
    }

    hw[REG_BALL]   = (uint32_t)(int)game.y << 16 | (uint32_t)(int)game.x;
    hw[REG_PADDLE] = (uint32_t)game.pad_w << 16 | (uint32_t)game.pad_x;
    hw[REG_MARKER] = (uint32_t)marker_y << 16 | (uint32_t)marker_x;
    hw[REG_DIGITS] = digits;
    hw[REG_LIVES]  = app == APP_GAME ? game.lives : 0;
    for (int r = 0; r < BRICK_ROWS; r++)
        hw[REG_BRICKS0 + r] = game.bricks[r];
    hw[REG_CTRL] = ctrl;
}

int main(void)
{
    /* The camera first: its exposure settles for 2 s and then locks. The
     * LCD then switches from its start-up screen to video. */
    camera_init(2000);
    ILI9488_init();

    /* The instruction cache in front of the eNVM is off after reset, and
     * every fetch then waits for the eNVM. Turn it on after the start-up
     * delays, which the reference times with busy loops. */
    SYSREG->FLUSH_CR = 1u;
    SYSREG->CC_CR |= 1u;                /* CC_CACHE_ENB */

    hw[REG_COLOR_GAIN] = LCD_GAIN << 20 | LCD_GAIN << 10 | LCD_GAIN;
    hw[REG_COLORS] = (uint32_t)UI_DIGIT_COLOR << 16 | UI_FG_COLOR;
    hw[REG_BOX_X] = (uint32_t)CAL_BOX_X1 << 16 | CAL_BOX_X0;
    hw[REG_BOX_Y] = (uint32_t)CAL_BOX_Y1 << 16 | CAL_BOX_Y0;
    game_new(&game, widths[width_ix]);  /* a wall to show while idle */
    SysTick_Config(SystemCoreClock / 1000);

    uint32_t last_frame = hw[REG_FRAME];
    for (;;) {
        /* Until the PIC32 relays, a byte sent to it overruns its UART, which
         * then stops receiving until the board is power-cycled. So the game
         * works from power-on, and the UART waits for the PC. */
        if (!host && uart_host_seen()) {
            host = 1;
            say("# hellofpga-demo: camera breakout\r\n");
        }
        if (host)
            uart_drain();

        handle_buttons();

        uint32_t frame = hw[REG_FRAME];
        if (frame == last_frame)
            continue;
        last_frame = frame;

        poll_calibration();
        int paddle = read_tracker();
        if (app == APP_GAME) {
            uint32_t ev = game_step(&game, paddle, serve_requested);
            serve_requested = 0;
            if (ev & EV_LEVEL) {
                say("LEVEL ");
                say_u(game.level);
                say("\r\n");
            }
            if (ev & EV_OVER) {
                say("OVER ");
                say_u(game.score);
                say(" ");
                say_u(game.level);
                say("\r\n");
            }
        }
        draw(frame);
    }
}
