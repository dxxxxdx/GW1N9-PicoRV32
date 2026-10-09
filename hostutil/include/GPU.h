/*
 * MMIO driver for the solid-rectangle GPU.
 *
 * Coordinates and sizes are in pixels. The framebuffer is packed RGB565 with
 * a fixed 640-pixel (1280-byte) row stride and begins at offset zero of the
 * logical PSRAM BACK die. Hardware clips rectangles to the framebuffer, then
 * turns each row into 1..64-pixel PSRAM bursts without crossing a 128-byte
 * physical wrap group. GPU has priority over CPU at BACK-die burst boundaries.
 */
#ifndef GW1NR9_RV32_GPU_H
#define GW1NR9_RV32_GPU_H

#include <stdint.h>

/*
 * Rectangle-GPU page: 0x0300_f000..0x0300_ffff.
 *
 * +0x00 MAGIC      R   Page/version signature 0x47505531 (ASCII "GPU1").
 * +0x04 STATUS     R   bits [31:16] completed-command counter (wraps at 65536)
 *                       bit 0 = busy; bits [15:1] = zero.
 * +0x08 X          R/W left edge in pixels; value is in bits [15:0].
 * +0x0c Y          R/W top edge in pixels; value is in bits [15:0].
 * +0x10 WIDTH      R/W requested width in pixels; bits [15:0].
 * +0x14 HEIGHT     R/W requested height in pixels; bits [15:0].
 * +0x18 COLOR      R/W RGB565 fill color in bits [15:0]: R[15:11],
 *                       G[10:5], B[4:0].
 * +0x1c COMMAND    W   bit 0 START snapshots all five parameter registers.
 *                       Other bits are ignored; reads return zero.
 * +0x20 FRAME_SIZE R   height in [31:16], width in [15:0] (480, 640).
 *
 * Parameter writes use the low 16 bits. If BUSY=1, ALL parameter and START
 * writes are acknowledged but discarded; there is no command queue. X/Y past
 * the right/bottom edge, or a zero/clipped-to-zero size, performs no PSRAM
 * write but still completes and increments the completion counter.
 */
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

#define GPU_MAGIC_EXPECTED        0x47505531u /* ASCII "GPU1" */
#define GPU_STATUS_BUSY           (1u << 0)
#define GPU_STATUS_COUNT_SHIFT    16u
#define GPU_COMMAND_START         (1u << 0)

/* Return nonzero from START acceptance until every rectangle burst is done. */
int GPU_IsBusy(void);

/* Return the low 16-bit completed-command counter, zero-extended to uint32_t. */
uint32_t GPU_GetCompletionCount(void);

/* Busy-wait with no timeout until the current rectangle command completes. */
void GPU_WaitIdle(void);

/*
 * If idle, program one rectangle and issue START, then return 1 immediately.
 * Return 0 without changing any register if the GPU was already busy.
 *
 * This function serializes five parameter writes followed by START. Do not
 * call it concurrently from main code and an interrupt handler. Arguments are
 * truncated to 16 bits by hardware; the rectangle is then clipped to 640x480.
 */
int GPU_FillRectangleAsync(uint32_t x, uint32_t y, uint32_t width,
                           uint32_t height, uint16_t color);

/*
 * Blocking rectangle fill: wait for an older command, submit this rectangle,
 * and wait until all of its PSRAM bursts finish. There is no timeout.
 */
void GPU_FillRectangle(uint32_t x, uint32_t y, uint32_t width,
                       uint32_t height, uint16_t color);

#endif /* GW1NR9_RV32_GPU_H */
