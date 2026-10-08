//
// PSRAM hostutil 库实现
//

#include "PSRAM.h"
#include "UART.h"

#define PSRAM_TRAIN_WORDS_PER_DIE (32u * 1024u)
#define PSRAM_TRAIN_SWAP_TIMEOUT   1000000u
#define PSRAM_TRAIN_FALLBACK_PHASE 5u

static void training_phase_settle(void)
{
    for (volatile uint32_t i = 0u; i < 512u; ++i)
        __asm__ volatile ("nop");
}

static int training_swap_back_die(void)
{
    uint32_t before = PSRAM_GetSwapCount();

    PSRAM_TestSwap();
    for (uint32_t i = 0u; i < PSRAM_TRAIN_SWAP_TIMEOUT; ++i) {
        if (PSRAM_GetSwapCount() != before)
            return 1;
    }
    return 0;
}

static int training_select_back_die(uint32_t die)
{
    if (PSRAM_GetBackDie() == (die & 1u))
        return 1;
    if (!training_swap_back_die())
        return 0;
    return PSRAM_GetBackDie() == (die & 1u);
}

static uint32_t training_pattern(uint32_t index, uint32_t seed)
{
    uint32_t x = index ^ (index << 16) ^ (index << 7) ^ (index >> 3);
    return seed ^ x;
}

static uint32_t training_probe_failure;

static uint32_t training_probe_visible_die(uint32_t seed)
{
    for (uint32_t i = 0u; i < PSRAM_TRAIN_WORDS_PER_DIE; ++i)
        PSRAM_U32[i] = training_pattern(i, seed);

    for (uint32_t i = 0u; i < PSRAM_TRAIN_WORDS_PER_DIE; ++i) {
        if (PSRAM_U32[i] != training_pattern(i, seed))
            return i;
    }
    return PSRAM_TRAIN_WORDS_PER_DIE;
}

static int training_probe_phase(uint32_t phase)
{
    uint32_t bad;

    training_probe_failure = 0u;
    PSRAM_SetPhase(phase);
    training_phase_settle();
    if (PSRAM_PHASE_REG != phase) {
        training_probe_failure = 0x10000000u | PSRAM_PHASE_REG;
        return 0;
    }

    if (!training_select_back_die(0u)) {
        training_probe_failure = 0x50000000u;
        return 0;
    }
    bad = training_probe_visible_die(0xa55a5aa5u);
    if (bad != PSRAM_TRAIN_WORDS_PER_DIE) {
        training_probe_failure = 0x01000000u | bad;
        return 0;
    }

    if (!training_select_back_die(1u)) {
        training_probe_failure = 0x50000001u;
        return 0;
    }
    bad = training_probe_visible_die(0x5aa5a55au);
    if (bad != PSRAM_TRAIN_WORDS_PER_DIE) {
        training_probe_failure = 0x02000000u | bad;
        return 0;
    }

    if (!training_select_back_die(0u)) {
        training_probe_failure = 0x50000000u;
        return 0;
    }
    bad = training_probe_visible_die(0x5aa5a55au);
    if (bad != PSRAM_TRAIN_WORDS_PER_DIE) {
        training_probe_failure = 0x03000000u | bad;
        return 0;
    }

    if (!training_select_back_die(1u)) {
        training_probe_failure = 0x50000001u;
        return 0;
    }
    bad = training_probe_visible_die(0xa55a5aa5u);
    if (bad != PSRAM_TRAIN_WORDS_PER_DIE) {
        training_probe_failure = 0x04000000u | bad;
        return 0;
    }

    if (!training_select_back_die(0u)) {
        training_probe_failure = 0x50000000u;
        return 0;
    }
    return 1;
}

static uint32_t training_choose_window_center(uint32_t pass_mask)
{
    uint32_t best_length = 0u;
    uint32_t best_end = 0u;
    uint32_t length = 0u;

    for (uint32_t i = 0u; i < 32u; ++i) {
        if ((pass_mask & (1u << (i & 15u))) != 0u) {
            if (length < 16u)
                ++length;
            if (length > best_length) {
                best_length = length;
                best_end = i;
            }
        } else {
            length = 0u;
        }
    }

    if (best_length == 0u)
        return PSRAM_TRAIN_FALLBACK_PHASE;
    return (best_end + 1u - best_length + best_length / 2u) & 15u;
}

uint32_t PSRAM_TrainPhase(void)
{
    uint32_t pass_mask = 0u;

    UART_CStr("phase training through logical back window (two dies):\r\n");
    for (uint32_t phase = 0u; phase < 16u; ++phase) {
        int pass = training_probe_phase(phase);
        if (pass)
            pass_mask |= 1u << phase;
        UART_CStr("  phase ");
        UART_UInt(phase);
        if (pass) {
            UART_CStr(": PASS\r\n");
        } else {
            UART_CStr(": FAIL code=0x");
            UART_Hex32(training_probe_failure);
            UART_CStr("\r\n");
        }
    }

    uint32_t selected = training_choose_window_center(pass_mask);
    UART_CStr("phase pass mask=0x");
    UART_Hex32(pass_mask);
    UART_CStr(" selected=");
    UART_UInt(selected);
    UART_CStr(pass_mask == 0u ? "  NO WINDOW\r\n" : "  WINDOW CENTER\r\n");

    PSRAM_SetPhase(selected);
    training_phase_settle();
    training_select_back_die(0u);
    return selected;
}

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
