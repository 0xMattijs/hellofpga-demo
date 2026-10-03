/* Breakout game logic; see include/game.h. */
#include <math.h>
#include "config.h"
#include "game.h"

#define ALL_BRICKS ((1u << BRICK_COLS) - 1)

static void new_wall(game_t *g)
{
    for (int r = 0; r < BRICK_ROWS; r++)
        g->bricks[r] = ALL_BRICKS;
}

static int bricks_left(const game_t *g)
{
    for (int r = 0; r < BRICK_ROWS; r++)
        if (g->bricks[r])
            return 1;
    return 0;
}

void game_reserve(game_t *g)
{
    g->state = GAME_SERVE;
    g->timer = SERVE_FRAMES;
    g->vx = g->vy = 0;
    g->x = g->pad_x + g->pad_w / 2 - BALL_SIZE / 2;
    g->y = PADDLE_Y - BALL_SIZE;
}

void game_set_paddle_width(game_t *g, int pad_w)
{
    int center = g->pad_x + g->pad_w / 2;
    g->pad_w = pad_w;
    g->pad_x = center - pad_w / 2;
    if (g->pad_x < 0)
        g->pad_x = 0;
    if (g->pad_x > SCREEN_W - pad_w)
        g->pad_x = SCREEN_W - pad_w;
}

void game_new(game_t *g, int pad_w)
{
    new_wall(g);
    g->pad_w = pad_w;
    g->pad_x = (SCREEN_W - pad_w) / 2;
    g->score = 0;
    g->lives = LIVES;
    g->level = 1;
    g->speed = BALL_SPEED;
    g->frames = 0;
    game_reserve(g);
}

/* Points for a brick in row r: the top row is worth most. */
static int brick_points(int r)
{
    return 10 * (BRICK_ROWS - r);
}

/* Removes every brick the ball overlaps at (x, y) and returns how many. */
static int hit_bricks(game_t *g, float x, float y)
{
    int x0 = (int)x, y0 = (int)y;
    int x1 = x0 + BALL_SIZE - 1, y1 = y0 + BALL_SIZE - 1;
    if (y1 < BRICK_Y0 || y0 >= BRICK_Y0 + BRICK_ROWS * BRICK_PITCH_Y)
        return 0;
    int hits = 0;
    for (int r = 0; r < BRICK_ROWS; r++) {
        int by0 = BRICK_Y0 + r * BRICK_PITCH_Y + BRICK_INSET;
        int by1 = by0 + BRICK_PITCH_Y - 2 * BRICK_INSET - 1;
        if (y1 < by0 || y0 > by1)
            continue;
        for (int c = 0; c < BRICK_COLS; c++) {
            if (!(g->bricks[r] & (1u << c)))
                continue;
            int bx0 = c * BRICK_PITCH_X + BRICK_INSET;
            int bx1 = bx0 + BRICK_PITCH_X - 2 * BRICK_INSET - 1;
            if (x1 < bx0 || x0 > bx1)
                continue;
            g->bricks[r] &= ~(1u << c);
            g->score += brick_points(r);
            hits++;
        }
    }
    return hits;
}

/* Starts the ball up and to one side, alternating. */
static void serve(game_t *g)
{
    float s = g->speed;
    g->vx = (g->frames & 1) ? 0.4f * s : -0.4f * s;
    g->vy = -sqrtf(s * s - g->vx * g->vx);
    g->state = GAME_PLAY;
}

uint32_t game_step(game_t *g, int paddle_center, int serve_now)
{
    uint32_t ev = 0;
    if (g->state == GAME_OVER)
        return 0;
    g->frames++;

    if (paddle_center >= 0) {
        int px = paddle_center - g->pad_w / 2;
        if (px < 0)
            px = 0;
        if (px > SCREEN_W - g->pad_w)
            px = SCREEN_W - g->pad_w;
        g->pad_x = px;
    }

    if (g->state == GAME_SERVE) {
        g->x = g->pad_x + g->pad_w / 2 - BALL_SIZE / 2;
        g->y = PADDLE_Y - BALL_SIZE;
        if (serve_now || --g->timer <= 0)
            serve(g);
        return 0;
    }

    /* x first, then y, so a hit knows which side it came from. */
    float nx = g->x + g->vx;
    if (nx < 0) {
        nx = -nx;
        g->vx = -g->vx;
        ev |= EV_WALL;
    } else if (nx > SCREEN_W - BALL_SIZE) {
        nx = 2 * (SCREEN_W - BALL_SIZE) - nx;
        g->vx = -g->vx;
        ev |= EV_WALL;
    }
    if (hit_bricks(g, nx, g->y)) {
        g->vx = -g->vx;
        nx = g->x;
        ev |= EV_BRICK;
    }
    g->x = nx;

    float ny = g->y + g->vy;
    if (ny < HUD_H) {
        ny = 2 * HUD_H - ny;
        g->vy = -g->vy;
        ev |= EV_WALL;
    }
    if (hit_bricks(g, g->x, ny)) {
        g->vy = -g->vy;
        ny = g->y;
        ev |= EV_BRICK;
    }

    /* The paddle: only from above, when the ball's bottom crosses its top. */
    float bottom = g->y + BALL_SIZE, nbottom = ny + BALL_SIZE;
    if (g->vy > 0 && bottom <= PADDLE_Y && nbottom > PADDLE_Y &&
        g->x + BALL_SIZE > g->pad_x && g->x < g->pad_x + g->pad_w) {
        /* The farther from the middle, the flatter the bounce. */
        float half = g->pad_w / 2.0f;
        float off = (g->x + BALL_SIZE / 2.0f - (g->pad_x + half)) / (half + BALL_SIZE / 2.0f);
        if (off < -1)
            off = -1;
        if (off > 1)
            off = 1;
        float s = g->speed;
        g->vx = 0.75f * s * off;
        g->vy = -sqrtf(s * s - g->vx * g->vx);
        ny = PADDLE_Y - BALL_SIZE;
        ev |= EV_PADDLE;
    }
    g->y = ny;

    if (g->y >= SCREEN_H) {
        ev |= EV_LOST;
        if (--g->lives <= 0) {
            g->lives = 0;
            g->state = GAME_OVER;
            return ev | EV_OVER;
        }
        game_reserve(g);
        return ev;
    }

    if (!bricks_left(g)) {
        g->level++;
        g->speed += BALL_SPEEDUP;
        if (g->speed > BALL_SPEED_MAX)
            g->speed = BALL_SPEED_MAX;
        new_wall(g);
        game_reserve(g);
        ev |= EV_LEVEL;
    }
    return ev;
}
