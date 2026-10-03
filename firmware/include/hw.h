#ifndef HW_H
#define HW_H

#include <stdint.h>

/* game_top registers (word offsets); see hdl/src/game_top.v */
#define GAME_BASE        0x30001000u

#define REG_CTRL         0
#define REG_FRAME        1
#define REG_BUTTONS      2
#define REG_UART         3
#define REG_UART_RX      4
#define REG_COLOR_GAIN   5
#define REG_TRACK_C      6
#define REG_TRACK_Y      7
#define REG_TRACK_N      8
#define REG_TRACK_SX     9
#define REG_TRACK_SY     10
#define REG_BOX_X        11
#define REG_BOX_Y        12
#define REG_BOX_R        13
#define REG_BOX_G        14
#define REG_BOX_B        15
#define REG_BOX_N        16
#define REG_BALL         17
#define REG_PADDLE       18
#define REG_MARKER       19
#define REG_DIGITS       20
#define REG_LIVES        21
#define REG_BRICKS0      22   /* five rows, top first */
#define REG_COLORS       27

#define CTRL_ON          (1u << 0)
#define CTRL_MIRROR      (1u << 1)
#define CTRL_DIM         (1u << 2)
#define CTRL_BALL        (1u << 3)
#define CTRL_PADDLE      (1u << 4)
#define CTRL_MARKER      (1u << 5)
#define CTRL_BOX         (1u << 6)

static volatile uint32_t *const hw = (volatile uint32_t *)GAME_BASE;

#endif
