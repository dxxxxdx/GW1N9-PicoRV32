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

static void UART_Byte(uint8_t value)
{
    while (UART_TX_IDLE_REG == 0u) {
    }

    UART_TX_DATA_REG = value;
    UART_TX_ENABLE_REG = 1u;
}

void UART_CStr(const char *text)
{
    if (text == 0)
        return;

    while (*text != '\0')
        UART_Byte((uint8_t)*text++);
}

void UART_UInt(uint32_t value)
{
    uint8_t digits[10];
    uint8_t count = 0u;

    if (value == 0u) {
        UART_Byte('0');
        return;
    }

    while (value != 0u) {
        digits[count++] = (uint8_t)('0' + (value % 10u));
        value /= 10u;
    }

    while (count != 0u)
        UART_Byte(digits[--count]);
}

void UART_Hex32(uint32_t value)
{
    static const char kHex[] = "0123456789ABCDEF";
    int shift;

    for (shift = 28; shift >= 0; shift -= 4)
        UART_Byte((uint8_t)kHex[(value >> shift) & 0xFu]);
}
