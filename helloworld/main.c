#include "PSRAM.h"
#include "UART.h"
#include "IRQ.h"

#define TRAIN_WORDS_PER_DIE (32u * 1024u) // 128 KiB per die and pattern
#define SWAP_TIMEOUT         1000000u

static void print_result(const char *name, uint32_t got, uint32_t want)
{
    UART_CStr(name);
    UART_CStr(": got=0x");
    UART_Hex32(got);
    UART_CStr(" want=0x");
    UART_Hex32(want);
    UART_CStr(got == want ? "  OK\r\n" : "  FAIL\r\n");
}

static void phase_settle(void)
{
    for (volatile uint32_t i = 0u; i < 512u; ++i)
        __asm__ volatile ("nop");
}

static int swap_back_die(void)
{
    uint32_t before = PSRAM_GetSwapCount();

    // Before HDMI exists, bit1 injects the frame boundary that will later come
    // from the display controller.  The switcher still waits for both PHYs idle.
    PSRAM_TestSwap();
    for (uint32_t i = 0u; i < SWAP_TIMEOUT; ++i) {
        if (PSRAM_GetSwapCount() != before)
            return 1;
    }
    return 0;
}

static int select_back_die(uint32_t die)
{
    if (PSRAM_GetBackDie() == (die & 1u))
        return 1;
    if (!swap_back_die())
        return 0;
    return PSRAM_GetBackDie() == (die & 1u);
}

static uint32_t training_pattern(uint32_t index, uint32_t seed)
{
    uint32_t x = index ^ (index << 16) ^ (index << 7) ^ (index >> 3);
    return seed ^ x;
}

static uint32_t probeFailure;

static uint32_t probe_visible_die(uint32_t seed)
{
    for (uint32_t i = 0u; i < TRAIN_WORDS_PER_DIE; ++i)
        PSRAM_U32[i] = training_pattern(i, seed);

    for (uint32_t i = 0u; i < TRAIN_WORDS_PER_DIE; ++i) {
        if (PSRAM_U32[i] != training_pattern(i, seed))
            return i;
    }
    return TRAIN_WORDS_PER_DIE;
}

static int probe_phase(uint32_t phase)
{
    uint32_t bad;

    probeFailure = 0u;
    PSRAM_SetPhase(phase);
    phase_settle();
    if (PSRAM_PHASE_REG != phase) {
        probeFailure = 0x10000000u | PSRAM_PHASE_REG;
        return 0;
    }

    if (!select_back_die(0u)) {
        probeFailure = 0x50000000u;
        return 0;
    }
    bad = probe_visible_die(0xa55a5aa5u);
    if (bad != TRAIN_WORDS_PER_DIE) {
        probeFailure = 0x01000000u | bad;
        return 0;
    }

    if (!select_back_die(1u)) {
        probeFailure = 0x50000001u;
        return 0;
    }
    bad = probe_visible_die(0x5aa5a55au);
    if (bad != TRAIN_WORDS_PER_DIE) {
        probeFailure = 0x02000000u | bad;
        return 0;
    }

    if (!select_back_die(0u)) {
        probeFailure = 0x50000000u;
        return 0;
    }
    bad = probe_visible_die(0x5aa5a55au);
    if (bad != TRAIN_WORDS_PER_DIE) {
        probeFailure = 0x03000000u | bad;
        return 0;
    }

    if (!select_back_die(1u)) {
        probeFailure = 0x50000001u;
        return 0;
    }
    bad = probe_visible_die(0xa55a5aa5u);
    if (bad != TRAIN_WORDS_PER_DIE) {
        probeFailure = 0x04000000u | bad;
        return 0;
    }

    if (!select_back_die(0u)) {
        probeFailure = 0x50000000u;
        return 0;
    }
    return 1;
}

static uint32_t choose_window_center(uint32_t passMask)
{
    uint32_t bestLength = 0u;
    uint32_t bestEnd = 0u;
    uint32_t length = 0u;

    for (uint32_t i = 0u; i < 32u; ++i) {
        if ((passMask & (1u << (i & 15u))) != 0u) {
            if (length < 16u)
                ++length;
            if (length > bestLength) {
                bestLength = length;
                bestEnd = i;
            }
        } else {
            length = 0u;
        }
    }

    if (bestLength == 0u)
        return 5u;
    return (bestEnd + 1u - bestLength + bestLength / 2u) & 15u;
}

static uint32_t train_phase(void)
{
    uint32_t passMask = 0u;

    UART_CStr("phase training through logical back window (two dies):\r\n");
    for (uint32_t phase = 0u; phase < 16u; ++phase) {
        int pass = probe_phase(phase);
        if (pass)
            passMask |= 1u << phase;
        UART_CStr("  phase ");
        UART_UInt(phase);
        if (pass) {
            UART_CStr(": PASS\r\n");
        } else {
            UART_CStr(": FAIL code=0x");
            UART_Hex32(probeFailure);
            UART_CStr("\r\n");
        }
    }

    uint32_t selected = choose_window_center(passMask);
    UART_CStr("phase pass mask=0x");
    UART_Hex32(passMask);
    UART_CStr(" selected=");
    UART_UInt(selected);
    UART_CStr(passMask == 0u ? "  NO WINDOW\r\n" : "  WINDOW CENTER\r\n");

    PSRAM_SetPhase(selected);
    phase_settle();
    select_back_die(0u);
    return selected;
}

static uint32_t test_boundaries(void)
{
    static const uint32_t offsets[] = {
        0x000000u, 0x000004u, 0x000100u,
        0x0ffffcu, 0x100000u, 0x1ffffcu,
        0x200000u, 0x2ffffcu, 0x300000u, 0x3ffffcu
    };
    uint32_t failures = 0u;

    for (uint32_t i = 0u; i < sizeof(offsets) / sizeof(offsets[0]); ++i) {
        volatile uint32_t *p = (volatile uint32_t *)(PSRAM_BASE + offsets[i]);
        *p = 0x6d3a0000u ^ offsets[i] ^ i;
    }

    for (uint32_t i = 0u; i < sizeof(offsets) / sizeof(offsets[0]); ++i) {
        volatile uint32_t *p = (volatile uint32_t *)(PSRAM_BASE + offsets[i]);
        uint32_t want = 0x6d3a0000u ^ offsets[i] ^ i;
        if (*p != want)
            ++failures;
    }
    return failures;
}

static uint32_t test_byte_lanes(void)
{
    volatile uint32_t *word = PSRAM_U32;
    volatile uint16_t *half = PSRAM_U16;
    volatile uint8_t *byte = PSRAM_U8;
    uint32_t failures = 0u;

    *word = 0x11223344u;
    byte[0] = 0xa0u;
    if (*word != 0x112233a0u) ++failures;
    byte[1] = 0xb1u;
    if (*word != 0x1122b1a0u) ++failures;
    byte[2] = 0xc2u;
    if (*word != 0x11c2b1a0u) ++failures;
    byte[3] = 0xd3u;
    if (*word != 0xd3c2b1a0u) ++failures;

    half[0] = 0x5aa5u;
    if (*word != 0xd3c25aa5u) ++failures;
    half[1] = 0xa55au;
    if (*word != 0xa55a5aa5u) ++failures;

    return failures;
}

static uint32_t test_swap_isolation(void)
{
    volatile uint32_t *p = PSRAM_U32 + 16u;
    uint32_t failures = 0u;

    if (!select_back_die(0u)) return 1u;
    *p = 0x0d1e0000u;
    if (!select_back_die(1u)) return 1u;
    *p = 0x1d1e1111u;
    if (!select_back_die(0u)) return 1u;
    if (*p != 0x0d1e0000u) ++failures;
    if (!select_back_die(1u)) return failures + 1u;
    if (*p != 0x1d1e1111u) ++failures;
    if (!select_back_die(0u)) return failures + 1u;
    return failures;
}

static uint32_t test_full_die(uint32_t die)
{
    uint32_t bad;

    UART_CStr("full 4 MiB die");
    UART_UInt(die);
    UART_CStr(" through logical window...\r\n");
    if (!select_back_die(die)) {
        UART_CStr("swap timeout\r\n");
        return 0u;
    }

    bad = PSRAM_TestPattern(PSRAM_SIZE / sizeof(uint32_t));
    if (bad == PSRAM_SIZE / sizeof(uint32_t)) {
        UART_CStr("  PASS\r\n");
    } else {
        UART_CStr("  FAIL at byte offset 0x");
        UART_Hex32(bad * sizeof(uint32_t));
        UART_CStr(" want=0x");
        UART_Hex32(0xa5a50000u ^ bad);
        UART_CStr("\r\n  rereads:");
        for (uint32_t i = 0u; i < 8u; ++i) {
            UART_CStr(" 0x");
            UART_Hex32(PSRAM_U32[bad]);
        }
        UART_CStr("\r\n");
    }
    return bad;
}

int main(void)
{
    uint32_t status;
    uint32_t laneFailures = 0u;
    uint32_t boundaryFailures = 0u;
    uint32_t selectedPhase;
    uint32_t swapFailures;
    uint32_t bad0;
    uint32_t bad1;

    IRQ_Init();
    IRQ_Enable(IRQ_CH0);

    UART_CStr("\r\n=== PSRAM front/back die switcher test ===\r\n");
    UART_CStr("PHY: 80 MHz / fixed 2x latency / CPU sees logical back die\r\n");

    UART_CStr("MAGIC  = 0x");
    UART_Hex32(PSRAM_MAGIC_REG);
    UART_CStr(PSRAM_MAGIC_REG == PSRAM_MAGIC_EXPECTED ? "  OK\r\n" :
                                                       "  WRONG BITSTREAM\r\n");

    status = PSRAM_STATUS_REG;
    UART_CStr("STATUS = 0x");
    UART_Hex32(status);
    UART_CStr(" initDone=");
    UART_UInt((status & PSRAM_STATUS_INIT_DONE) != 0u);
    UART_CStr(" die0=");
    UART_UInt((status & PSRAM_STATUS_DIE0_READY) != 0u);
    UART_CStr(" die1=");
    UART_UInt((status & PSRAM_STATUS_DIE1_READY) != 0u);
    UART_CStr(" front=");
    UART_UInt((status & PSRAM_STATUS_FRONT_DIE) != 0u);
    UART_CStr(" back=");
    UART_UInt((status & PSRAM_STATUS_BACK_DIE) != 0u);
    UART_CStr("\r\n");

    print_result("logical bytes", PSRAM_BYTES_REG, PSRAM_SIZE);
    print_result("physical bytes", PSRAM_PHYS_BYTES_REG, PSRAM_PHYSICAL_SIZE);
    print_result("power-up phase", PSRAM_PHASE_REG, 5u);

    selectedPhase = train_phase();
    print_result("trained phase", PSRAM_PHASE_REG, selectedPhase);

    for (uint32_t die = 0u; die < 2u; ++die) {
        if (!select_back_die(die)) {
            ++laneFailures;
            ++boundaryFailures;
            continue;
        }
        laneFailures += test_byte_lanes();
        boundaryFailures += test_boundaries();
    }
    select_back_die(0u);

    UART_CStr("byte/halfword lanes, both dies: failures=");
    UART_UInt(laneFailures);
    UART_CStr(laneFailures == 0u ? "  OK\r\n" : "  FAIL\r\n");
    UART_CStr("4 MiB boundaries, both dies: failures=");
    UART_UInt(boundaryFailures);
    UART_CStr(boundaryFailures == 0u ? "  OK\r\n" : "  FAIL\r\n");

    swapFailures = test_swap_isolation();
    UART_CStr("die swap preserves separate contents: failures=");
    UART_UInt(swapFailures);
    UART_CStr(swapFailures == 0u ? "  OK\r\n" : "  FAIL\r\n");

    bad0 = test_full_die(0u);
    bad1 = test_full_die(1u);
    select_back_die(0u);
    if (bad0 == PSRAM_SIZE / sizeof(uint32_t) &&
        bad1 == PSRAM_SIZE / sizeof(uint32_t))
        UART_CStr("both physical dies: PASS\r\n");
    else
        UART_CStr("both physical dies: FAIL\r\n");

    UART_CStr("final swap status=0x");
    UART_Hex32(PSRAM_SWAP_REG);
    UART_CStr("\r\ndone\r\n");
    for (;;) {
    }
}

const uint8_t ch0msg[] = "CH0 triggered!";
void IRQ_Ch0_Handler(void)
{
    UART_String(ch0msg, 14);
}
