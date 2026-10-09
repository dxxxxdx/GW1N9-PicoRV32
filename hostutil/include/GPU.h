#ifndef GW1NR9_RV32_GPU_H
#define GW1NR9_RV32_GPU_H

#include <stdint.h>

#define GPU_MMIO_BASE       0x0300f000u
#define GPU_MAGIC_REG       (*(volatile uint32_t *)(GPU_MMIO_BASE + 0x00u))
#define GPU_STATUS_REG      (*(volatile uint32_t *)(GPU_MMIO_BASE + 0x04u))
#define GPU_X_REG           (*(volatile uint32_t *)(GPU_MMIO_BASE + 0x08u))
#define GPU_Y_REG           (*(volatile uint32_t *)(GPU_MMIO_BASE + 0x0cu))
#define GPU_WIDTH_REG       (*(volatile uint32_t *)(GPU_MMIO_BASE + 0x10u))
#define GPU_HEIGHT_REG      (*(volatile uint32_t *)(GPU_MMIO_BASE + 0x14u))
#define GPU_COLOR_REG       (*(volatile uint32_t *)(GPU_MMIO_BASE + 0x18u))
#define GPU_COMMAND_REG     (*(volatile uint32_t *)(GPU_MMIO_BASE + 0x1cu))
#define GPU_FRAME_SIZE_REG  (*(volatile uint32_t *)(GPU_MMIO_BASE + 0x20u))

#define GPU_MAGIC_EXPECTED  0x47505531u // "GPU1"
#define GPU_STATUS_BUSY     (1u << 0)
#define GPU_COMMAND_START   (1u << 0)

int GPU_IsBusy(void);
uint32_t GPU_GetCompletionCount(void);
void GPU_WaitIdle(void);
int GPU_FillRectangleAsync(uint32_t x, uint32_t y, uint32_t width,
                           uint32_t height, uint16_t color);
void GPU_FillRectangle(uint32_t x, uint32_t y, uint32_t width,
                       uint32_t height, uint16_t color);

#endif
