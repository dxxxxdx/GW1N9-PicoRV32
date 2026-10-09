#include "HDMI_PSRAM.h"
#include "SwapController.h"
#include "GPU.h"
#include "UART.h"
#include "IRQ.h"

#define SWAP_TIMEOUT       1000000u
#define PANEL_X                 80u
#define PANEL_Y                 40u
#define PANEL_WIDTH            480u
#define PANEL_HEIGHT           400u
#define SQUARE_SIZE             24u
#define ORBIT_PHASES            64u
#define COLOR_BACKGROUND    0x0841u
#define COLOR_PANEL         0x8410u
#define COLOR_SQUARE        0x07e0u

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
    // From x=10, 130 pixels become 54 + 64 + 12 word bursts so that no
    // transaction crosses a physical 128-byte group boundary.
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

// First-quadrant samples for a 180 x 140 ellipse, in 5.625-degree steps.
// Symmetry expands these 17 pairs into a complete 64-frame orbit without
// pulling a software floating-point or trigonometry library into the firmware.
static const int16_t orbitRxCos[17] = {
    180, 179, 177, 172, 166, 159, 150, 139, 127,
    114, 100, 85, 69, 52, 35, 18, 0
};
static const int16_t orbitRySin[17] = {
    0, 14, 27, 41, 54, 66, 78, 89, 99,
    108, 116, 123, 129, 134, 137, 139, 140
};

static uint32_t squareOldX[2];
static uint32_t squareOldY[2];
static uint32_t squareValid[2];

static void orbit_position(uint32_t phase, uint32_t *x, uint32_t *y)
{
    uint32_t quadrant = (phase >> 4) & 3u;
    uint32_t step = phase & 15u;
    int32_t dx;
    int32_t dy;

    if (quadrant == 0u) {
        dx = orbitRxCos[step];
        dy = orbitRySin[step];
    } else if (quadrant == 1u) {
        dx = -orbitRxCos[16u - step];
        dy = orbitRySin[16u - step];
    } else if (quadrant == 2u) {
        dx = -orbitRxCos[step];
        dy = -orbitRySin[step];
    } else {
        dx = orbitRxCos[16u - step];
        dy = -orbitRySin[16u - step];
    }

    *x = (uint32_t)((int32_t)(HDMI_WIDTH / 2u) + dx -
                    (int32_t)(SQUARE_SIZE / 2u));
    *y = (uint32_t)((int32_t)(HDMI_HEIGHT / 2u) + dy -
                    (int32_t)(SQUARE_SIZE / 2u));
}

static void draw_gpu_scene(uint32_t die)
{
    uint32_t x;
    uint32_t y;

    GPU_FillRectangle(0u, 0u, HDMI_WIDTH, HDMI_HEIGHT, COLOR_BACKGROUND);
    GPU_FillRectangle(PANEL_X, PANEL_Y, PANEL_WIDTH, PANEL_HEIGHT, COLOR_PANEL);
    orbit_position(0u, &x, &y);
    GPU_FillRectangle(x, y, SQUARE_SIZE, SQUARE_SIZE, COLOR_SQUARE);
    squareOldX[die] = x;
    squareOldY[die] = y;
    squareValid[die] = 1u;
}

static void animate_gpu_square(void)
{
    uint32_t phase = 1u;

    UART_CStr("GPU animation: green square orbiting on gray panel\r\n");
    for (;;) {
        uint32_t die = SwapController_GetBackDie();
        uint32_t x;
        uint32_t y;

        if (squareValid[die])
            GPU_FillRectangle(squareOldX[die], squareOldY[die],
                              SQUARE_SIZE, SQUARE_SIZE, COLOR_PANEL);

        orbit_position(phase, &x, &y);
        GPU_FillRectangle(x, y, SQUARE_SIZE, SQUARE_SIZE, COLOR_SQUARE);
        squareOldX[die] = x;
        squareOldY[die] = y;
        squareValid[die] = 1u;

        if (!SwapController_SwapAtHDMIFrame(SWAP_TIMEOUT)) {
            UART_CStr("GPU animation swap timeout\r\n");
            return;
        }
        phase = (phase + 1u) & (ORBIT_PHASES - 1u);
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
    draw_gpu_scene(0u);
    if (!SwapController_SelectBackBeforeHDMI(1u, SWAP_TIMEOUT)) {
        UART_CStr("HDMI init failed: cannot select die1\r\n");
        for (;;) {}
    }
    draw_gpu_scene(1u);
    if (SwapController_GetBackDie() == 1u) {
        HDMI_PSRAM_Enable();
        UART_CStr("HDMI enabled; GPU scene initialized on both dies\r\n");
        animate_gpu_square();
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
