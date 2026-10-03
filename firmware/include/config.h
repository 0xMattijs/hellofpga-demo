#ifndef CONFIG_H
#define CONFIG_H

/* Display */
#define UI_MIRROR          1      /* 1 if the LCD shows the camera image mirrored, as
                                     the kit's does: the game then runs right to left
                                     in camera coordinates, so it reads right on screen */
#define UI_DIM             1      /* darken the video behind the game */
/* RGB565. The panel's green is strong: full white looks mint, so the white
 * has less green. */
#define UI_FG_COLOR        0xFE5A /* ball, paddle, lives */
#define UI_DIGIT_COLOR     0xFE5A /* score, calibration box */
#define LCD_GAIN           0x80   /* video color gains, 0x80 = 1.0 */

/* Calibration (SW3): the camera's automatic exposure, gain, and white
 * balance run this long, the digits counting down, then lock. Then the
 * tracker's color box is fitted to the object in the calibration box. */
#define CAL_SETTLE_MS      3000
#define CAL_FRAMES         5      /* frames averaged for the fit */
#define CAL_BOX_X0         280    /* camera coordinates; the middle of the image */
#define CAL_BOX_X1         360
#define CAL_BOX_Y0         200
#define CAL_BOX_Y1         280
#define FIT_CHROMA         16     /* Cb and Cr limits: the object's mean +/- this */
#define FIT_Y_FLOOR        0.35f  /* Y floor as a fraction of the object's mean Y */
#define FIT_MIN_CHROMA     24     /* below this distance from gray, warn that the
                                     object isn't colorful enough to track well */

/* Tracking */
#define TRACK_MIN_PIXELS   200    /* fewer matches: the object is lost */
#define TRACK_SMOOTH       0.5f   /* EMA weight of each new paddle position */

/* Game */
#define PADDLE_WIDTHS      { 160, 112, 80 }   /* SW2 steps through these */
#define BALL_SPEED         6.0f   /* pixels per frame at level 1 */
#define BALL_SPEEDUP       1.0f   /* added per level */
#define BALL_SPEED_MAX     12.0f  /* stays under the ball size, so the ball can't
                                     skip over a brick or the paddle */
#define LIVES              3
#define SERVE_FRAMES       45     /* the ball waits on the paddle this long */

#endif
