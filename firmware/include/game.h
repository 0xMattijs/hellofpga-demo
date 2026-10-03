#ifndef GAME_H
#define GAME_H

#include <stdint.h>

/* Breakout in screen coordinates (640 x 480, x to the right on the LCD).
 * The layout matches hdl/src/game_overlay.v. Plain C, no hardware, so
 * test/host_game.c can run it on the PC. */

#define SCREEN_W     640
#define SCREEN_H     480
#define HUD_H        56          /* the ball bounces off its lower edge */
#define BRICK_COLS   10
#define BRICK_ROWS   5
#define BRICK_Y0     72
#define BRICK_PITCH_X 64
#define BRICK_PITCH_Y 32
#define BRICK_INSET  4           /* bricks are 56 x 24 inside each cell */
#define PADDLE_Y     440
#define PADDLE_H     16
#define BALL_SIZE    16

enum game_state { GAME_SERVE, GAME_PLAY, GAME_OVER };

/* game_step() events */
#define EV_BRICK   (1u << 0)
#define EV_PADDLE  (1u << 1)
#define EV_WALL    (1u << 2)
#define EV_LOST    (1u << 3)     /* a ball fell past the paddle */
#define EV_OVER    (1u << 4)     /* that was the last life */
#define EV_LEVEL   (1u << 5)     /* all bricks cleared; a new wall is up */

typedef struct {
    enum game_state state;
    float    x, y;               /* ball top left */
    float    vx, vy;             /* pixels per frame */
    float    speed;
    uint16_t bricks[BRICK_ROWS]; /* bit c: column c, from the left */
    int      pad_x, pad_w;       /* paddle left end and width */
    int      score, lives, level;
    int      timer;              /* frames left in GAME_SERVE */
    uint32_t frames;             /* for the serve direction */
} game_t;

void game_new(game_t *g, int pad_w);

/* One frame. paddle_center is the paddle's screen x, or -1 to leave it
 * where it is (the object is lost). serve starts the ball early in
 * GAME_SERVE. Returns EV_* bits. Does nothing in GAME_OVER. */
uint32_t game_step(game_t *g, int paddle_center, int serve);

/* Puts the ball back on the paddle, for after a recalibration. */
void game_reserve(game_t *g);

void game_set_paddle_width(game_t *g, int pad_w);

#endif
