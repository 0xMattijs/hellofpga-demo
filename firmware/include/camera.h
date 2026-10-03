#ifndef CAMERA_H
#define CAMERA_H

#include <stdint.h>

/* OV7725 camera over the MSS I2C_0 bus (SCCB). */

#define CAM_COM8          0x13
#define CAM_COM8_AUTO     0x0F   /* automatic exposure, white balance, and gain */
#define CAM_COM8_LOCKED   0x08   /* all three off: the sensor keeps the last values */

/* Sets the camera up for 640 x 480 RGB565 at 30 frames per second, lets
 * its automatic exposure, gain, and white balance settle for settle_ms,
 * then locks them. */
void camera_init(uint32_t settle_ms);

/* Writes one register. Returns 0, or -1 if the camera didn't answer. */
int camera_write(uint8_t reg, uint8_t val);

/* Busy-waits, timed by the Cortex-M3 cycle counter. */
void delay_ms(uint32_t ms);

#endif
