/*
 * PSRAM 前后台角色交换控制器。
 *
 * HDMI 独占读取逻辑 FRONT die，CPU 和矩形 GPU 共享逻辑 BACK die。一次交换只会
 * 改变访问路由，不复制内存内容。改变映射前，硬件会先等已经接收的事务全部结束。
 */
#ifndef GW1NR9_RV32_SWAP_CONTROLLER_H
#define GW1NR9_RV32_SWAP_CONTROLLER_H

#include <stdint.h>

/*
 * 交换控制页：0x0300_1000..0x0300_1fff。
 *
 * +0x00 MAGIC  R   页面/版本魔数 0x53575031，即 ASCII "SWP1"。
 * +0x04 STATUS R   [31:16] 已完成交换计数，达到 65536 后回绕
 *                  位 3  当前送给 HDMI 的交换请求电平
 *                  位 2  当前作为 BACK 的物理 die 编号
 *                  位 1  当前作为 FRONT 的物理 die 编号
 *                  位 0  有交换请求正在等待执行
 *                  [15:4] 固定为 0；FRONT 和 BACK 的 die 编号必然互补。
 * +0x08 CTRL   W   位 0 提交一次交换请求
 *                  位 1 注入一次软件模拟的帧结束事件
 *                  其他位被忽略；读该寄存器返回 0。
 *
 * 写 CTRL 时必须使能最低字节通道。交换请求没有队列深度：已有交换等待执行时，
 * 再写一次位 0 不会额外排队第二次交换。
 */
#define SWAP_CONTROLLER_BASE       0x03001000u
#define SWAP_CONTROLLER_MAGIC_REG  (*(volatile uint32_t *)(SWAP_CONTROLLER_BASE + 0x00u))
#define SWAP_CONTROLLER_STATUS_REG (*(volatile uint32_t *)(SWAP_CONTROLLER_BASE + 0x04u))
#define SWAP_CONTROLLER_CTRL_REG   (*(volatile uint32_t *)(SWAP_CONTROLLER_BASE + 0x08u))

#define SWAP_CONTROLLER_MAGIC_EXPECTED 0x53575031u /* ASCII "SWP1" */

/* SWAP_CONTROLLER_STATUS_REG 位定义。 */
#define SWAP_STATUS_PENDING        (1u << 0) /* 请求已接收但尚未完成 */
#define SWAP_STATUS_FRONT_DIE      (1u << 1) /* 0 = die0, 1 = die1 */
#define SWAP_STATUS_BACK_DIE       (1u << 2) /* 0 = die0, 1 = die1 */
#define SWAP_STATUS_HDMI_REQUEST   (1u << 3) /* 送给 HDMI 的同一等待请求 */
#define SWAP_STATUS_COUNT_SHIFT    16u

/* SWAP_CONTROLLER_CTRL_REG 写入位定义。 */
#define SWAP_REQUEST               (1u << 0) /* 请求交换前后台映射 */
#define SWAP_SOFT_FRAME_DONE       (1u << 1) /* 模拟一次帧边界 */

/* 返回当前映射为逻辑 BACK 的物理 die 编号（0 或 1）。 */
uint32_t SwapController_GetBackDie(void);

/* 返回当前映射为逻辑 FRONT 的物理 die 编号（0 或 1）。 */
uint32_t SwapController_GetFrontDie(void);

/* 返回低 16 位已完成交换计数，并零扩展成 uint32_t。 */
uint32_t SwapController_GetCount(void);

/*
 * 提交一次交换请求并立即返回。真正的 HDMI 帧边界到来后，硬件暂停接收新的 CPU
 * 和 HDMI 事务，但允许已经开始的 GPU 作业继续发完后续突发。GPU 作业结束且两颗
 * die 上已接收的事务全部排空后，才会原子交换 FRONT/BACK 角色。
 */
void SwapController_Request(void);

/*
 * 在同一次 MMIO 写入中提交交换请求并模拟帧边界。只能在 HDMI 尚未开启的启动阶段
 * 使用，让软件能够通过唯一的逻辑 BACK 窗口依次初始化或测试两颗物理 die。
 */
void SwapController_BootRequest(void);

/*
 * HDMI 开启前使用的阻塞交换，通过软件模拟帧边界触发。timeout 是 CPU 轮询次数，
 * 不是时间单位。交换完成返回 1，超时返回 0；超时不会撤销已经发给硬件的请求。
 */
int SwapController_SwapBeforeHDMI(uint32_t timeout);

/*
 * 请求在下一个真实 HDMI 帧边界交换并阻塞等待完成。timeout 是轮询次数，不是时间
 * 单位。交换完成返回 1，超时返回 0；超时同样不会撤销硬件中的等待请求。
 */
int SwapController_SwapAtHDMIFrame(uint32_t timeout);

/*
 * 在 HDMI 关闭时，把物理 die (die&1) 选为逻辑 BACK。选择成功返回 1；目标原本
 * 已经是 BACK 也返回 1；等待交换超时则返回 0。
 */
int SwapController_SelectBackBeforeHDMI(uint32_t die, uint32_t timeout);

#endif /* GW1NR9_RV32_SWAP_CONTROLLER_H */
