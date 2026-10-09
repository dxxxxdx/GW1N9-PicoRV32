#include "GPU.h"

int GPU_IsBusy(void)
{
    return (GPU_STATUS_REG & GPU_STATUS_BUSY) != 0u;
}

uint32_t GPU_GetCompletionCount(void)
{
    return GPU_STATUS_REG >> GPU_STATUS_COUNT_SHIFT;
}

/*
 * 硬件会一直保持 BUSY，直到最后一个 PSRAM done 脉冲到来，而不是只保持到最后
 * 一个突发被提交。因此这里轮询 BUSY 可以确认实际写操作已经全部结束。
 */
void GPU_WaitIdle(void)
{
    while (GPU_IsBusy()) {
    }
}

int GPU_FillRectangleAsync(uint32_t x, uint32_t y, uint32_t width,
                           uint32_t height, uint16_t color)
{
    /*
     * 忙状态下的写入会被硬件静默丢弃，所以必须在修改任何参数寄存器前直接拒绝，
     * 保证当前正在执行的命令不受影响。
     */
    if (GPU_IsBusy())
        return 0;

    GPU_X_REG = x;
    GPU_Y_REG = y;
    GPU_WIDTH_REG = width;
    GPU_HEIGHT_REG = height;
    GPU_COLOR_REG = color;
    /* START 把全部参数锁存成一个跨时钟域传输的完整作业。 */
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
