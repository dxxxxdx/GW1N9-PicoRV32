/*
 * 纯色矩形 GPU 的 MMIO 驱动。
 *
 * 坐标和尺寸的单位都是像素。帧缓冲采用紧密排列的 RGB565，固定每行 640 像素
 * （1280 字节），起点是逻辑 PSRAM BACK die 的偏移 0。硬件先把矩形裁剪到画面
 * 范围内，再把每一行转换成每次 1..64 像素的 PSRAM 写突发，并保证任何突发都
 * 不跨越 128 字节的物理回绕边界。在 BACK die 的事务边界上，GPU 优先于 CPU。
 */
#ifndef GW1NR9_RV32_GPU_H
#define GW1NR9_RV32_GPU_H

#include <stdint.h>

/*
 * 矩形 GPU 页面：0x0300_f000..0x0300_ffff。
 *
 * +0x00 MAGIC      R   页面/版本魔数 0x47505531，即 ASCII "GPU1"。
 * +0x04 STATUS     R   [31:16] 已完成命令计数，达到 65536 后回绕
 *                       位 0 = GPU 正忙；[15:1] 固定为 0。
 * +0x08 X          R/W 矩形左边缘的像素坐标，有效值位于 [15:0]。
 * +0x0c Y          R/W 矩形上边缘的像素坐标，有效值位于 [15:0]。
 * +0x10 WIDTH      R/W 请求绘制的宽度，单位像素，有效值位于 [15:0]。
 * +0x14 HEIGHT     R/W 请求绘制的高度，单位像素，有效值位于 [15:0]。
 * +0x18 COLOR      R/W RGB565 填充颜色，位于 [15:0]：R[15:11]、
 *                       G[10:5]、B[4:0]。
 * +0x1c COMMAND    W   位 0 START：锁存上述五个参数并启动一次绘制。
 *                       其他位被忽略；读该寄存器返回 0。
 * +0x20 FRAME_SIZE R   [31:16] 为画面高度，[15:0] 为宽度，即 480、640。
 *
 * 参数寄存器只使用低 16 位。BUSY=1 时，所有参数写入和 START 写入都会正常应答，
 * 但实际被丢弃；硬件没有命令队列。X/Y 已在画面右侧/下方，或者宽高为 0、裁剪后
 * 变成 0 时，不会发出 PSRAM 写事务，但该命令仍会完成并增加完成计数。
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

/* 从 START 被接收到矩形最后一个突发完成之前返回非零。 */
int GPU_IsBusy(void);

/* 返回低 16 位已完成命令计数，并零扩展成 uint32_t。 */
uint32_t GPU_GetCompletionCount(void);

/* 无超时忙等，直到当前矩形命令完全结束。 */
void GPU_WaitIdle(void);

/*
 * GPU 空闲时写入一个矩形的全部参数，发出 START 后立即返回 1。如果调用时 GPU
 * 已经忙，则不修改任何参数寄存器并返回 0。
 *
 * 本函数依次进行五次参数写入，最后再写 START。因此不能同时从主程序和中断处理
 * 函数调用。硬件先把各参数截断为 16 位，再将矩形裁剪到 640x480 画面范围内。
 */
int GPU_FillRectangleAsync(uint32_t x, uint32_t y, uint32_t width,
                           uint32_t height, uint16_t color);

/*
 * 阻塞式矩形填充：先等待上一条命令结束，再提交本次矩形，最后等待它的全部
 * PSRAM 突发完成。本函数没有超时机制。
 */
void GPU_FillRectangle(uint32_t x, uint32_t y, uint32_t width,
                       uint32_t height, uint16_t color);

#endif /* GW1NR9_RV32_GPU_H */
