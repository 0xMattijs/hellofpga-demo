/* Color tracker calibration; see include/track.h. */
#include <math.h>
#include "config.h"
#include "track.h"

void track_ycbcr(float r, float g, float b, float *y, float *cb, float *cr)
{
    *y  =          ( 77 * r + 150 * g +  29 * b) / 256;
    *cb = 128.0f + (-43 * r -  85 * g + 128 * b) / 256;
    *cr = 128.0f + (128 * r - 107 * g -  21 * b) / 256;
}

static uint8_t clamp8(float v)
{
    if (v < 0)
        return 0;
    if (v > 255)
        return 255;
    return (uint8_t)(v + 0.5f);
}

float track_fit(uint32_t sum_r, uint32_t sum_g, uint32_t sum_b, uint32_t n,
                track_limits_t *lim)
{
    if (n == 0)
        return -1;
    float y, cb, cr;
    track_ycbcr((float)sum_r / n, (float)sum_g / n, (float)sum_b / n, &y, &cb, &cr);
    lim->cb_min = clamp8(cb - FIT_CHROMA);
    lim->cb_max = clamp8(cb + FIT_CHROMA);
    lim->cr_min = clamp8(cr - FIT_CHROMA);
    lim->cr_max = clamp8(cr + FIT_CHROMA);
    /* Brighter is fine (the object turns toward a light); much darker is
     * shadow, where Cb and Cr are noisy. */
    lim->y_min = clamp8(y * FIT_Y_FLOOR);
    lim->y_max = 255;
    return sqrtf((cb - 128) * (cb - 128) + (cr - 128) * (cr - 128));
}
