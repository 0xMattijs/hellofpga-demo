/* UART through game_top; see include/uart.h. */
#include <stdint.h>
#include "hw.h"
#include "uart.h"

#define UART_BUSY      (1u << 0)
#define UART_HOST_SEEN (1u << 1)   /* the PC has put the PIC32 in relay mode */
#define RX_VALID       (1u << 8)

int uart_host_seen(void)
{
    return (hw[REG_UART] & UART_HOST_SEEN) != 0;
}

void uart_putc(char c)
{
    while (hw[REG_UART] & UART_BUSY)
        ;
    hw[REG_UART] = (uint8_t)c;
}

void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

void uart_putu(uint32_t v)
{
    char buf[10];
    int n = 0;
    do {
        buf[n++] = '0' + v % 10;
        v /= 10;
    } while (v);
    while (n)
        uart_putc(buf[--n]);
}

void uart_drain(void)
{
    while (hw[REG_UART_RX] & RX_VALID)  /* reading a valid byte removes it */
        ;
}
