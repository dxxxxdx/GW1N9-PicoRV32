#include "PSRAM.h"
#include "UART.h"
#include "IRQ.h"

#define TRAIN_WORDS_PER_BANK (32u * 1024u) // 128 KiB per die and pattern

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
    // Dynamic PSDA is asynchronous to the CPU bus.  Transactions are already
    // quiescent here; leave several microseconds for CLKOUTP to settle before
    // asserting either PSRAM chip select again.
    for (volatile uint32_t i = 0u; i < 512u; ++i)
        __asm__ volatile ("nop");
}

static uint32_t training_pattern(uint32_t index, uint32_t seed)
{
    uint32_t x = index ^ (index << 16) ^ (index << 7) ^ (index >> 3);
    return seed ^ x;
}

static uint32_t probeFailure;

static uint32_t probe_bank(volatile uint32_t *mem, uint32_t seed)
{
    for (uint32_t i = 0u; i < TRAIN_WORDS_PER_BANK; ++i)
        mem[i] = training_pattern(i, seed);

    for (uint32_t i = 0u; i < TRAIN_WORDS_PER_BANK; ++i) {
        if (mem[i] != training_pattern(i, seed))
            return i;
    }
    return TRAIN_WORDS_PER_BANK;
}

static int probe_phase(uint32_t phase)
{
    volatile uint32_t *bank0 = (volatile uint32_t *)PSRAM_BANK0_BASE;
    volatile uint32_t *bank1 = (volatile uint32_t *)PSRAM_BANK1_BASE;
    uint32_t bad;

    probeFailure = 0u;
    PSRAM_SetPhase(phase);
    phase_settle();
    if (PSRAM_PHASE_REG != phase) {
        probeFailure = 0x10000000u | PSRAM_PHASE_REG;
        return 0;
    }

    // A phase is usable only if both physical dies pass two complementary
    // address-dependent patterns.  This catches bad upper and lower DDR bytes.
    bad = probe_bank(bank0, 0xa55a5aa5u);
    if (bad != TRAIN_WORDS_PER_BANK) {
        probeFailure = 0x01000000u | bad;
        return 0;
    }
    bad = probe_bank(bank1, 0x5aa5a55au);
    if (bad != TRAIN_WORDS_PER_BANK) {
        probeFailure = 0x02000000u | bad;
        return 0;
    }
    bad = probe_bank(bank0, 0x5aa5a55au);
    if (bad != TRAIN_WORDS_PER_BANK) {
        probeFailure = 0x03000000u | bad;
        return 0;
    }
    bad = probe_bank(bank1, 0xa55a5aa5u);
    if (bad != TRAIN_WORDS_PER_BANK) {
        probeFailure = 0x04000000u | bad;
        return 0;
    }
    return 1;
}

static uint32_t choose_window_center(uint32_t passMask)
{
    uint32_t bestLength = 0u;
    uint32_t bestEnd = 0u;
    uint32_t length = 0u;

    // Search two copies because tap 15 and tap 0 are adjacent phases.  Cap a
    // run at 16 so an all-pass mask still has a well-defined center.
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
        return 4u;
    return (bestEnd + 1u - bestLength + bestLength / 2u) & 15u;
}

static uint32_t train_phase(void)
{
    uint32_t passMask = 0u;

    UART_CStr("phase training (two dies, 16 taps):\r\n");
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
    return selected;
}

static uint32_t test_boundaries(void)
{
    static const uint32_t offsets[] = {
        0x000000u, 0x000004u, 0x000100u,
        0x0ffffcu, 0x100000u, 0x1ffffcu,
        0x200000u, 0x2ffffcu, 0x300000u, 0x3ffffcu,
        0x400000u, 0x400004u, 0x4ffffcu, 0x500000u,
        0x5ffffcu, 0x600000u, 0x6ffffcu, 0x700000u, 0x7ffffcu
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

int main(void)
{
    uint32_t status;
    uint32_t bad;
    uint32_t boundaryFailures;
    uint32_t laneFailures;
    uint32_t selectedPhase;

    IRQ_Init();
    IRQ_Enable(IRQ_CH0);

    UART_CStr("\r\n=== PSRAM 8 MiB dual-bank test ===\r\n");
    UART_CStr("PHY: 80 MHz / two x8 dies / fixed 2x latency\r\n");

    UART_CStr("MAGIC  = 0x");
    UART_Hex32(PSRAM_MAGIC_REG);
    UART_CStr(PSRAM_MAGIC_REG == PSRAM_MAGIC_EXPECTED ? "  OK\r\n" :
                                                       "  WRONG BITSTREAM\r\n");

    status = PSRAM_STATUS_REG;
    UART_CStr("STATUS = 0x");
    UART_Hex32(status);
    UART_CStr("  initDone=");
    UART_UInt(status & PSRAM_STATUS_INIT_DONE);
    UART_CStr(" phyBusy=");
    UART_UInt((status & PSRAM_STATUS_PHY_BUSY) != 0u);
    UART_CStr(" die0=");
    UART_UInt((status & PSRAM_STATUS_DIE0_READY) != 0u);
    UART_CStr(" die1=");
    UART_UInt((status & PSRAM_STATUS_DIE1_READY) != 0u);
    UART_CStr("\r\n");

    print_result("power-up phase", PSRAM_PHASE_REG, 4u);

    selectedPhase = train_phase();
    print_result("trained phase", PSRAM_PHASE_REG, selectedPhase);

    laneFailures = test_byte_lanes();
    UART_CStr("byte/halfword lanes: failures=");
    UART_UInt(laneFailures);
    UART_CStr(laneFailures == 0u ? "  OK\r\n" : "  FAIL\r\n");

    boundaryFailures = test_boundaries();
    UART_CStr("8 MiB / bank boundaries: failures=");
    UART_UInt(boundaryFailures);
    UART_CStr(boundaryFailures == 0u ? "  OK\r\n" : "  FAIL\r\n");

    UART_CStr("full 8 MiB write/read test...\r\n");
    bad = PSRAM_TestPattern(PSRAM_SIZE / sizeof(uint32_t));
    if (bad == PSRAM_SIZE / sizeof(uint32_t)) {
        UART_CStr("full 8 MiB: PASS\r\n");
    } else {
        UART_CStr("full 8 MiB: FAIL at byte offset 0x");
        UART_Hex32(bad * sizeof(uint32_t));
        UART_CStr(" want=0x");
        UART_Hex32(0xa5a50000u ^ bad);
        UART_CStr("\r\nrereads:");
        for (uint32_t i = 0u; i < 8u; ++i) {
            UART_CStr(" 0x");
            UART_Hex32(PSRAM_U32[bad]);
        }
        UART_CStr("\r\n");
    }

    UART_CStr("done\r\n");
    for (;;) {
    }
}

const uint8_t ch0msg[] = "CH0 triggered!";
void IRQ_Ch0_Handler(void)
{
    UART_String(ch0msg, 14);
}
