#ifndef TRACK_H
#define TRACK_H

#include <stdint.h>

/* The color tracker's YCbCr box (hdl/src/color_track.v), limits inclusive. */
typedef struct {
    uint8_t y_min, y_max, cb_min, cb_max, cr_min, cr_max;
} track_limits_t;

/* Full-range BT.601, the tracker's conversion. */
void track_ycbcr(float r, float g, float b, float *y, float *cb, float *cr);

/* Fits the box to the mean color of the calibration box, from the sums the
 * tracker reports. Returns the mean color's distance from gray in Cb/Cr,
 * or -1 if the box held no pixels. */
float track_fit(uint32_t sum_r, uint32_t sum_g, uint32_t sum_b, uint32_t n,
                track_limits_t *lim);

#endif
