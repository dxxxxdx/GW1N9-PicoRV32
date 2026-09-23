//
// Created by dxxdx on 2026/9/24.
//

#include "UART.h"

void UART_String(const uint8_t *data, uint8_t len)
{
    uint8_t index;

    if (data == 0)
        return;

    for (index = 0; index < len; ++index) {
        while (UART_TX_IDLE_REG == 0u) {
        }

        UART_TX_DATA_REG = data[index];
        UART_TX_ENABLE_REG = 1u;
    }
}
