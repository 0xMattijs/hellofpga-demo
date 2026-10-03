#ifndef UART_H
#define UART_H

#include <stdint.h>

/* UART to the PC through the PIC32 (game_top's uart_tx and uart_rx). Only
 * send once uart_host_seen() is true: a byte that reaches the PIC32 before
 * the PC has put it in relay mode jams its receiver until a power cycle. */

int  uart_host_seen(void);
void uart_putc(char c);
void uart_puts(const char *s);
void uart_putu(uint32_t v);
/* Drops whatever the PC has sent. */
void uart_drain(void);

#endif
