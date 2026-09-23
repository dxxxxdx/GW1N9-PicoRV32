//
// Created by dxxdx on 2026/9/24.
//

#ifndef GW1NR9_RV32_UART_H
#define GW1NR9_RV32_UART_H

#include <stdint.h>

/* UART TX MMIO byte registers. */
#define UART_TX_DATA_ADDR       0x01000000u
#define UART_TX_ENABLE_ADDR     0x01000001u
#define UART_TX_IDLE_ADDR       0x01000002u

#define UART_TX_DATA_REG        (*(volatile uint8_t *)UART_TX_DATA_ADDR)
#define UART_TX_ENABLE_REG      (*(volatile uint8_t *)UART_TX_ENABLE_ADDR)
#define UART_TX_IDLE_REG        (*(volatile uint8_t *)UART_TX_IDLE_ADDR)

/* Poll the UART and send exactly len bytes. */
void UART_String(const uint8_t *data, uint8_t len);

#endif /* GW1NR9_RV32_UART_H */
