/* Runs the game logic (src/game.c) and the calibration fit (src/track.c)
 * on the PC and checks their invariants. Run with: make -C firmware/test */
#include <stdio.h>
#include <stdlib.h>
#include "config.h"
#include "game.h"
#include "track.h"

static int errors;

#define CHECK(cond, ...) do {                                   \
        if (!(cond)) {                                          \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);         \
            printf(__VA_ARGS__);                                \
            printf("\n");                                       \
            errors++;                                           \
        }                                                       \
    } while (0)

/* The ball must never sit inside a brick that is still there. */
static int overlaps_brick(const game_t *g)
{
    int x0 = (int)g->x, y0 = (int)g->y;
    for (int r = 0; r < BRICK_ROWS; r++)
        for (int c = 0; c < BRICK_COLS; c++) {
            if (!(g->bricks[r] & (1u << c)))
                continue;
            int bx0 = c * BRICK_PITCH_X + BRICK_INSET, bx1 = bx0 + 55;
            int by0 = BRICK_Y0 + r * BRICK_PITCH_Y + BRICK_INSET, by1 = by0 + 23;
            if (x0 + BALL_SIZE - 1 >= bx0 && x0 <= bx1 &&
                y0 + BALL_SIZE - 1 >= by0 && y0 <= by1)
                return 1;
        }
    return 0;
}

/* A player who keeps the paddle under the ball, with an offset that varies
 * so the bounces spread over the wall. Clears levels; counts frames. */
static void test_good_player(void)
{
    game_t g;
    game_new(&g, 112);
    int levels = 0, frames = 0, last_score = 0;
    while (g.level < 4 && frames < 200000) {
        int aim = (int)g.x + BALL_SIZE / 2 + ((frames / 97) % 7 - 3) * 12;
        uint32_t ev = game_step(&g, aim, 0);
        frames++;
        CHECK(g.x >= 0 && g.x <= SCREEN_W - BALL_SIZE, "ball x %.1f out of range", g.x);
        CHECK(g.y >= HUD_H, "ball y %.1f in the HUD", g.y);
        CHECK(g.y < SCREEN_H, "ball y %.1f below the screen", g.y);
        CHECK(!overlaps_brick(&g), "ball inside a brick at (%.1f, %.1f)", g.x, g.y);
        CHECK(g.score >= last_score, "score went down");
        CHECK(!(ev & EV_LOST), "good player lost a ball at frame %d", frames);
        last_score = g.score;
        if (ev & EV_LEVEL)
            levels++;
        if (errors > 10)
            return;
    }
    CHECK(levels == 3, "cleared %d levels in %d frames", levels, frames);
    /* Every brick of three walls: (10 + 20 + ... + 50) * 10 per wall. */
    CHECK(g.score == 3 * 1500, "score %d after three walls", g.score);
    CHECK(g.speed == BALL_SPEED + 3 * BALL_SPEEDUP, "speed %.1f", g.speed);
    printf("good player: 3 walls in %d frames (%.0f s at 30 fps)\n", frames, frames / 30.0);
}

/* A paddle parked in the corner loses every ball. */
static void test_absent_player(void)
{
    game_t g;
    game_new(&g, 112);
    int lost = 0, over = 0, frames = 0;
    while (g.state != GAME_OVER && frames < 10000) {
        uint32_t ev = game_step(&g, 0, 0);
        frames++;
        if (ev & EV_LOST)
            lost++;
        if (ev & EV_OVER)
            over++;
        /* Serves alternate sides, so park under the other side after the
         * ball leaves the paddle. */
        if (g.state == GAME_PLAY && g.y < 300)
            game_step(&g, g.x < SCREEN_W / 2 ? SCREEN_W - 1 : 0, 0), frames++;
    }
    CHECK(g.state == GAME_OVER, "no game over after %d frames", frames);
    CHECK(lost == LIVES && over == 1, "lost %d balls, %d game overs", lost, over);
    CHECK(g.lives == 0, "%d lives left", g.lives);
    CHECK(game_step(&g, 100, 1) == 0 && g.state == GAME_OVER, "game over is final");
}

/* The ball waits SERVE_FRAMES on the paddle, or less with serve. */
static void test_serve(void)
{
    game_t g;
    game_new(&g, 112);
    for (int i = 0; i < SERVE_FRAMES - 1; i++) {
        game_step(&g, 320, 0);
        CHECK(g.state == GAME_SERVE, "served early, frame %d", i);
        CHECK((int)g.x == 320 - BALL_SIZE / 2, "ball not on the paddle: %.1f", g.x);
    }
    game_step(&g, 320, 0);
    CHECK(g.state == GAME_PLAY, "not served after %d frames", SERVE_FRAMES);
    CHECK(g.vy < 0, "served downward");

    game_new(&g, 112);
    game_step(&g, 320, 1);
    CHECK(g.state == GAME_PLAY, "serve button ignored");

    /* A lost object leaves the paddle where it was. */
    game_new(&g, 112);
    game_step(&g, 100, 0);
    int px = g.pad_x;
    game_step(&g, -1, 0);
    CHECK(g.pad_x == px, "paddle moved without the object");
    /* The paddle stays on the screen. */
    game_step(&g, 5, 0);
    CHECK(g.pad_x == 0, "paddle past the left edge: %d", g.pad_x);
    game_step(&g, 639, 0);
    CHECK(g.pad_x == SCREEN_W - 112, "paddle past the right edge: %d", g.pad_x);
    game_set_paddle_width(&g, 160);
    CHECK(g.pad_x == SCREEN_W - 160, "wider paddle past the edge: %d", g.pad_x);
}

/* The paddle's edges send the ball sideways, its middle straight up. */
static void test_paddle_angle(void)
{
    game_t g;
    for (int side = -1; side <= 1; side++) {
        game_new(&g, 112);
        game_step(&g, 320, 1);
        g.x = 320 - BALL_SIZE / 2 + side * 56;
        g.y = PADDLE_Y - BALL_SIZE - 3;
        g.vx = 0;
        g.vy = g.speed;
        uint32_t ev = game_step(&g, 320, 0);
        CHECK(ev & EV_PADDLE, "no paddle hit, side %d", side);
        CHECK(g.vy < 0, "still going down, side %d", side);
        CHECK(side == 0 ? g.vx == 0 : side * g.vx > 0.5f * g.speed,
              "vx %.2f for side %d", g.vx, side);
    }
}

static void test_fit(void)
{
    track_limits_t lim;
    float y, cb, cr;

    /* A saturated green ball: its color must be inside the box. */
    track_ycbcr(40, 200, 60, &y, &cb, &cr);
    float chroma = track_fit(40 * 1000, 200 * 1000, 60 * 1000, 1000, &lim);
    CHECK(cb >= lim.cb_min && cb <= lim.cb_max && cr >= lim.cr_min && cr <= lim.cr_max,
          "green outside its own box");
    CHECK(y >= lim.y_min && y <= lim.y_max, "green's Y outside its box");
    CHECK(chroma >= FIT_MIN_CHROMA, "green not colorful: %.1f", chroma);
    /* Gray and skin must fall outside it. */
    track_ycbcr(128, 128, 128, &y, &cb, &cr);
    CHECK(!(cb >= lim.cb_min && cb <= lim.cb_max && cr >= lim.cr_min && cr <= lim.cr_max),
          "gray inside the green box");
    track_ycbcr(200, 150, 120, &y, &cb, &cr);
    CHECK(!(cb >= lim.cb_min && cb <= lim.cb_max && cr >= lim.cr_min && cr <= lim.cr_max),
          "skin inside the green box");

    chroma = track_fit(128 * 50, 128 * 50, 128 * 50, 50, &lim);
    CHECK(chroma < 1, "gray chroma %.1f", chroma);
    CHECK(track_fit(0, 0, 0, 0, &lim) < 0, "empty box accepted");
}

int main(void)
{
    test_serve();
    test_paddle_angle();
    test_absent_player();
    test_good_player();
    test_fit();
    if (errors) {
        printf("%d errors\n", errors);
        return 1;
    }
    printf("PASS\n");
    return 0;
}
