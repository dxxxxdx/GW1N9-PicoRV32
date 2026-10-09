#include "HDMI_PSRAM.h"
#include "SwapController.h"
#include "GPU.h"
#include "UART.h"
#include "IRQ.h"

#define SWAP_TIMEOUT         1000000u
#define CURSOR_WIDTH            8u
#define CURSOR_HEIGHT           8u
#define CURSOR_WORDS_PER_ROW   (CURSOR_WIDTH / 2u)
#define CURSOR_DELAY_LOOPS     200000u

_Static_assert(HDMI_FRAME_BYTES <= HDMI_PSRAM_SIZE,
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

static const uint16_t hdmiColors[8] = {
    0xffffu, 0xffe0u, 0x07ffu, 0x07e0u,
    0xf81fu, 0xf800u, 0x001fu, 0x0000u
};

static uint32_t test_rectangle_gpu(void)
{
    volatile uint32_t *frame = HDMI_PSRAM_U32;
    const uint32_t framePixels = HDMI_WIDTH * HDMI_HEIGHT;
    const uint32_t firstRow = 3u * HDMI_WIDTH;
    const uint32_t lastRow = (HDMI_HEIGHT - 1u) * HDMI_WIDTH;
    const uint16_t burstColor = 0xf81fu;
    const uint16_t clippedColor = 0x07e0u;
    const uint32_t burstPair = (uint32_t)burstColor |
                               ((uint32_t)burstColor << 16);
    const uint32_t clippedPair = (uint32_t)clippedColor |
                                 ((uint32_t)clippedColor << 16);
    const uint32_t guardPair = 0x12341234u;
    uint32_t completedBefore = GPU_GetCompletionCount();
    uint32_t failureMask = 0u;

    // CPU-side PSRAM accesses deliberately use only aligned lw/sw.  The GPU
    // still works in RGB565 pixels; each CPU word below observes two pixels.
    // 130 pixels crosses two 64-pixel/128-byte burst boundaries.
    frame[(firstRow + 8u) / 2u] = guardPair;
    frame[(firstRow + 140u) / 2u] = guardPair;
    GPU_FillRectangle(10u, 3u, 130u, 2u, burstColor);
    if (frame[(firstRow + 10u) / 2u] != burstPair ||
        frame[(firstRow + 72u) / 2u] != burstPair ||
        frame[(firstRow + 74u) / 2u] != burstPair ||
        frame[(firstRow + 138u) / 2u] != burstPair ||
        frame[(firstRow + HDMI_WIDTH + 10u) / 2u] != burstPair ||
        frame[(firstRow + HDMI_WIDTH + 138u) / 2u] != burstPair ||
        frame[(firstRow + 8u) / 2u] != guardPair ||
        frame[(firstRow + 140u) / 2u] != guardPair)
        failureMask |= 1u << 0;

    // Only x=638..639 on the final row may survive this clipping operation.
    frame[(lastRow + 636u) / 2u] = guardPair;
    frame[(framePixels + 638u) / 2u] = guardPair;
    GPU_FillRectangle(638u, 479u, 10u, 3u, clippedColor);
    if (frame[(lastRow + 636u) / 2u] != guardPair ||
        frame[(lastRow + 638u) / 2u] != clippedPair ||
        frame[(framePixels + 638u) / 2u] != guardPair)
        failureMask |= 1u << 1;

    // Empty commands must complete without issuing a PSRAM write.
    frame[0] = guardPair;
    GPU_FillRectangle(0u, 0u, 0u, 10u, 0xffffu);
    if (frame[0] != guardPair)
        failureMask |= 1u << 2;

    if (((GPU_GetCompletionCount() - completedBefore) & 0xffffu) != 3u)
        failureMask |= 1u << 3;
    return failureMask;
}

static void draw_hdmi_color_bars(void)
{
    // Eight MMIO commands replace 153,600 CPU stores.  Each 80-pixel row is
    // emitted by hardware as one 64-pixel and one 16-pixel PSRAM burst.
    for (uint32_t bar = 0u; bar < 8u; ++bar)
        GPU_FillRectangle(bar * (HDMI_WIDTH / 8u), 0u,
                          HDMI_WIDTH / 8u, HDMI_HEIGHT, hdmiColors[bar]);
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
            HDMI_PSRAM_U32[row + word] = packed;
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
                uint32_t pixels = HDMI_PSRAM_U32[row + word];
                HDMI_PSRAM_U32[row + word] = pixels ^ mask;
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
        uint32_t die = SwapController_GetBackDie();
        if (cursorValid[die])
            restore_cursor_background(cursorOldX[die], cursorOldY[die]);
        xor_cursor(x, y);
        cursorOldX[die] = x;
        cursorOldY[die] = y;
        cursorValid[die] = 1u;

        if (!SwapController_SwapAtHDMIFrame(SWAP_TIMEOUT)) {
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

    UART_CStr("\r\n=== PSRAM rectangle-GPU HDMI demo ===\r\n");
    UART_CStr("PHY: 80 MHz / 128-byte bursts / GPU writes logical back die\r\n");

    print_result("HPS magic", HDMI_PSRAM_MAGIC_REG, HDMI_PSRAM_MAGIC_EXPECTED);
    print_result("SWAP magic", SWAP_CONTROLLER_MAGIC_REG,
                 SWAP_CONTROLLER_MAGIC_EXPECTED);
    print_result("GPU magic", GPU_MAGIC_REG, GPU_MAGIC_EXPECTED);

    status = HDMI_PSRAM_STATUS_REG;
    UART_CStr("STATUS = 0x");
    UART_Hex32(status);
    UART_CStr(" initDone=");
    UART_UInt((status & HDMI_PSRAM_INIT_DONE) != 0u);
    UART_CStr(" die0=");
    UART_UInt((status & HDMI_PSRAM_DIE0_READY) != 0u);
    UART_CStr(" die1=");
    UART_UInt((status & HDMI_PSRAM_DIE1_READY) != 0u);
    UART_CStr(" front=");
    UART_UInt(SwapController_GetFrontDie());
    UART_CStr(" back=");
    UART_UInt(SwapController_GetBackDie());
    UART_CStr("\r\n");

    print_result("logical bytes", HDMI_PSRAM_BYTES_REG, HDMI_PSRAM_SIZE);
    print_result("physical bytes", HDMI_PSRAM_PHYS_BYTES_REG,
                 HDMI_PSRAM_PHYSICAL_SIZE);
    print_result("fixed phase", HDMI_PSRAM_PHASE_REG, 5u);

    UART_CStr("render both 640x480 RGB565 framebuffers...\r\n");
    if (!SwapController_SelectBackBeforeHDMI(0u, SWAP_TIMEOUT)) {
        UART_CStr("HDMI init failed: cannot select die0\r\n");
        for (;;) {}
    }
    UART_CStr("rectangle GPU readback test on die0...\r\n");
    print_result("GPU rectangle failure mask", test_rectangle_gpu(), 0u);
    draw_hdmi_color_bars();
    if (!SwapController_SelectBackBeforeHDMI(1u, SWAP_TIMEOUT)) {
        UART_CStr("HDMI init failed: cannot select die1\r\n");
        for (;;) {}
    }
    draw_hdmi_color_bars();
    if (SwapController_GetBackDie() == 1u) {
        HDMI_PSRAM_Enable();
        UART_CStr("HDMI enabled; GPU color bars initialized on both dies\r\n");
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
