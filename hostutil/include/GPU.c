#include "GPU.h"

int GPU_IsBusy(void)
{
    return (GPU_STATUS_REG & GPU_STATUS_BUSY) != 0u;
}

uint32_t GPU_GetCompletionCount(void)
{
    return GPU_STATUS_REG >> GPU_STATUS_COUNT_SHIFT;
}

/* A blocking helper is safe because the hardware keeps BUSY set through the
 * final PSRAM done pulse, not merely until the last burst has been submitted. */
void GPU_WaitIdle(void)
{
    while (GPU_IsBusy()) {
    }
}

int GPU_FillRectangleAsync(uint32_t x, uint32_t y, uint32_t width,
                           uint32_t height, uint16_t color)
{
    /* Busy-time writes would be silently discarded, so reject before touching
     * any parameter register and leave the existing command intact. */
    if (GPU_IsBusy())
        return 0;

    GPU_X_REG = x;
    GPU_Y_REG = y;
    GPU_WIDTH_REG = width;
    GPU_HEIGHT_REG = height;
    GPU_COLOR_REG = color;
    /* START snapshots all parameters into a cross-clock-domain job bundle. */
    GPU_COMMAND_REG = GPU_COMMAND_START;
    return 1;
}

void GPU_FillRectangle(uint32_t x, uint32_t y, uint32_t width,
                       uint32_t height, uint16_t color)
{
    GPU_WaitIdle();
    (void)GPU_FillRectangleAsync(x, y, width, height, color);
    GPU_WaitIdle();
}
