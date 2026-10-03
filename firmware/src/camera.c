/* OV7725 camera set-up; see include/camera.h.
 *
 * After a reset, the sensor already runs at VGA and 30 frames per second.
 * The table below changes only what the reference design's LCD path
 * expects: RGB565 output, the image flipped vertically, the window width,
 * and the color processing that makes the LCD colors look right. */
#include "m2sxxx.h"
#include "system_m2sxxx.h"
#include "drivers/mss_i2c/mss_i2c.h"
#include "camera.h"

#define CAM_ADDR   0x21          /* 7-bit SCCB address */
#define COM7       0x12
#define COM7_RESET 0x80

static const uint8_t setup[][2] = {
    { 0x0C, 0x90 },   /* COM3: flip vertically, as the LCD path expects */
    { 0x0D, 0x00 },   /* COM4: PLL bypassed; 30 fps from the 24 MHz input */
    { COM7, 0x06 },   /* COM7: RGB output, RGB565 */
    { 0x18, 0xA3 },   /* HSIZE: sensor window a little wider than 640 */
    { 0x24, 0x40 },   /* AEW, AEB: target brightness range of the */
    { 0x25, 0x10 },   /*   automatic exposure, darker than the default */
    { 0x92, 0x02 },   /* sharpening: upper limit low, so less edge noise */
    { 0x9C, 0x80 },   /* contrast: 2x */
    { 0xA6, 0x04 },   /* special digital effects: hue control on */
    { 0xA9, 0xF0 },   /* hue cos and sin: the rotation the LCD's colors need */
    { 0xAA, 0xF0 },
    { CAM_COM8, CAM_COM8_AUTO },
};

/* camera_init() turns the cycle counter on. */
void delay_ms(uint32_t ms)
{
    uint32_t per_ms = SystemCoreClock / 1000u;
    while (ms--) {
        uint32_t start = DWT->CYCCNT;
        while (DWT->CYCCNT - start < per_ms)
            ;
    }
}

int camera_write(uint8_t reg, uint8_t val)
{
    uint8_t buf[2] = { reg, val };
    MSS_I2C_write(&g_mss_i2c0, CAM_ADDR, buf, 2, MSS_I2C_RELEASE_BUS);
    /* About 0.15 ms at the I2C clock below. Not MSS_I2C_wait_complete():
     * its timeout counts SysTick calls to MSS_I2C_system_tick(), so it would
     * wait forever before SysTick runs if the camera didn't answer. */
    uint32_t start = DWT->CYCCNT;
    mss_i2c_status_t st;
    while ((st = MSS_I2C_get_status(&g_mss_i2c0)) == MSS_I2C_IN_PROGRESS &&
           DWT->CYCCNT - start < SystemCoreClock / 100)
        ;
    return st == MSS_I2C_SUCCESS ? 0 : -1;
}

void camera_init(uint32_t settle_ms)
{
    /* PCLK1 / 256: about 200 kHz, under SCCB's 400 kHz. The address is
     * this bus master's own, which only matters to a slave. */
    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
    DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;
    MSS_I2C_init(&g_mss_i2c0, 0x7F, MSS_I2C_PCLK_DIV_256);
    camera_write(COM7, COM7_RESET);
    delay_ms(5);                        /* the reset takes 1 ms */
    for (unsigned i = 0; i < sizeof setup / sizeof setup[0]; i++)
        camera_write(setup[i][0], setup[i][1]);
    delay_ms(settle_ms);
    camera_write(CAM_COM8, CAM_COM8_LOCKED);
}
