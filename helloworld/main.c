#include "PSRAM.h"
#include "UART.h"
#include "IRQ.h"

#define SWAP_TIMEOUT         1000000u
#define HDMI_WIDTH            640u
#define HDMI_HEIGHT           480u
#define HDMI_FRAME_BYTES      (HDMI_WIDTH * HDMI_HEIGHT * 2u)
#define CURSOR_WIDTH            8u
#define CURSOR_HEIGHT           8u
#define CURSOR_WORDS_PER_ROW   (CURSOR_WIDTH / 2u)
#define CURSOR_DELAY_LOOPS     200000u

_Static_assert(HDMI_FRAME_BYTES <= PSRAM_SIZE,
               "RGB565 framebuffer exceeds one physical PSRAM die");

static void print_result(const char *name, uint32_t got, uint32_t want)
{
    UART_CStr(name);
    UART_CStr(": got=0x");
    UART_Hex32(got);
    UART_CStr(" want=0x");
    UART_Hex32(want);
    UART_CStr(got == want ? "  OK\r\n" : "  FAIL\r\n");
}

static int swap_before_hdmi(void)
{
    uint32_t before = PSRAM_GetSwapCount();

    // Before HDMI exists, bit1 injects the frame boundary that will later come
    // from the display controller.  The switcher still waits for both PHYs idle.
    PSRAM_BootSwap();
    for (uint32_t i = 0u; i < SWAP_TIMEOUT; ++i) {
        if (PSRAM_GetSwapCount() != before)
            return 1;
    }
    return 0;
}

static int swap_at_hdmi_frame(void)
{
    uint32_t before = PSRAM_GetSwapCount();

    // Production swap: HDMI supplies the safe frame boundary.  Do not inject
    // the software test pulse here, otherwise the visible frame may tear.
    PSRAM_RequestSwap();
    for (uint32_t i = 0u; i < SWAP_TIMEOUT; ++i) {
        if (PSRAM_GetSwapCount() != before)
            return 1;
    }
    return 0;
}

static int select_back_die_before_hdmi(uint32_t die)
{
    if (PSRAM_GetBackDie() == (die & 1u))
        return 1;
    if (!swap_before_hdmi())
        return 0;
    return PSRAM_GetBackDie() == (die & 1u);
}

static const uint16_t hdmiColors[8] = {
    0xffffu, 0xffe0u, 0x07ffu, 0x07e0u,
    0xf81fu, 0xf800u, 0x001fu, 0x0000u
};

static void draw_hdmi_color_bars(void)
{
    volatile uint32_t *frame = PSRAM_U32;

    // Each 32-bit CPU store places two adjacent RGB565 pixels into the single
    // two-beat physical burst used by the PSRAM bridge.
    for (uint32_t y = 0u; y < HDMI_HEIGHT; ++y) {
        uint32_t row = y * (HDMI_WIDTH / 2u);
        for (uint32_t bar = 0u; bar < 8u; ++bar) {
            uint32_t packed = (uint32_t)hdmiColors[bar] |
                              ((uint32_t)hdmiColors[bar] << 16);
            for (uint32_t pair = 0u; pair < HDMI_WIDTH / 16u; ++pair)
                frame[row + bar * (HDMI_WIDTH / 16u) + pair] = packed;
        }
    }
}

// Bit 0 is the left-most pixel.
static const uint8_t cursorShape[CURSOR_HEIGHT] = {
    0x01u,
    0x03u,
    0x07u,
    0x0fu,
    0x1fu,
    0x3fu,
    0x1bu,
    0x31u
};
static uint32_t cursorOldX[2];
static uint32_t cursorOldY[2];
static uint32_t cursorValid[2];

static void restore_cursor_background(uint32_t x, uint32_t y)
{
    uint32_t xWord = x / 2u;

    // The demo background is deterministic.  Reconstructing it is safer than
    // relying on an XOR toggle to have run exactly once on each physical die.
    for (uint32_t line = 0u; line < CURSOR_HEIGHT; ++line) {
        uint32_t row = (y + line) * (HDMI_WIDTH / 2u) + xWord;
        for (uint32_t word = 0u; word < CURSOR_WORDS_PER_ROW; ++word) {
            uint32_t pixel0 = x + word * 2u;
            uint32_t pixel1 = pixel0 + 1u;
            uint32_t packed = (uint32_t)hdmiColors[pixel0 / (HDMI_WIDTH / 8u)] |
                              ((uint32_t)hdmiColors[pixel1 / (HDMI_WIDTH / 8u)] << 16);
            PSRAM_U32[row + word] = packed;
        }
    }
}

static void xor_cursor(uint32_t x, uint32_t y)
{
    uint32_t xWord = x / 2u;

    for (uint32_t line = 0u; line < CURSOR_HEIGHT; ++line) {
        uint32_t row = (y + line) * (HDMI_WIDTH / 2u) + xWord;
        for (uint32_t word = 0u; word < CURSOR_WORDS_PER_ROW; ++word) {
            uint32_t pair = (cursorShape[line] >> (word * 2u)) & 3u;
            uint32_t mask = (pair & 1u ? 0x0000ffffu : 0u) |
                            (pair & 2u ? 0xffff0000u : 0u);
            if (mask != 0u) {
                // One aligned lw returns {pixel[x+1], pixel[x]}; the mask
                // changes only arrow pixels before the full word is sw'd back.
                uint32_t pixels = PSRAM_U32[row + word];
                PSRAM_U32[row + word] = pixels ^ mask;
            }
        }
    }
}

static void cursor_delay(void)
{
    // Deliberately simple bring-up delay; volatile prevents optimization.
    for (volatile uint32_t i = 0u; i < CURSOR_DELAY_LOOPS; ++i)
        __asm__ volatile ("nop");
}

static void animate_cursor(void)
{
    uint32_t x = 0u;
    uint32_t y = (HDMI_HEIGHT - CURSOR_HEIGHT) / 2u;
    int32_t dx = 2;

    UART_CStr("moving 8x8 arrow cursor: masked lw/sw on back buffer\r\n");
    for (;;) {
        uint32_t die = PSRAM_GetBackDie();
        if (cursorValid[die])
            restore_cursor_background(cursorOldX[die], cursorOldY[die]);
        xor_cursor(x, y);
        cursorOldX[die] = x;
        cursorOldY[die] = y;
        cursorValid[die] = 1u;

        if (!swap_at_hdmi_frame()) {
            UART_CStr("cursor swap timeout\r\n");
            return;
        }

        if (dx > 0 && x + CURSOR_WIDTH + (uint32_t)dx > HDMI_WIDTH)
            dx = -dx;
        else if (dx < 0 && x < (uint32_t)(-dx))
            dx = -dx;
        x = (uint32_t)((int32_t)x + dx);
        cursor_delay();
    }
}

int main(void)
{
    uint32_t status;

    IRQ_Init();
    IRQ_Enable(IRQ_CH0);

    UART_CStr("\r\n=== PSRAM double-buffer HDMI demo ===\r\n");
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
    print_result("fixed phase", PSRAM_PHASE_REG, 5u);

    UART_CStr("render both 640x480 RGB565 framebuffers...\r\n");
    if (!select_back_die_before_hdmi(0u)) {
        UART_CStr("HDMI init failed: cannot select die0\r\n");
        for (;;) {}
    }
    draw_hdmi_color_bars();
    if (!select_back_die_before_hdmi(1u)) {
        UART_CStr("HDMI init failed: cannot select die1\r\n");
        for (;;) {}
    }
    draw_hdmi_color_bars();
    if (PSRAM_GetBackDie() == 1u) {
        PSRAM_HDMIEnable();
        UART_CStr("HDMI enabled; front/back color bars initialized\r\n");
        animate_cursor();
    } else {
        UART_CStr("HDMI enable failed: framebuffer select timeout\r\n");
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
