//
// PSRAM hostutil 库实现
//

#include "PSRAM.h"

uint32_t PSRAM_TestPattern(uint32_t words)
{
    volatile uint32_t *mem = PSRAM_U32;

    for (uint32_t i = 0; i < words; i++)
        mem[i] = 0xA5A50000u ^ i;

    for (uint32_t i = 0; i < words; i++)
        if (mem[i] != (0xA5A50000u ^ i))
            return i;

    return words;
}
