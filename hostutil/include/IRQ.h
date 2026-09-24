//
// Created by dxx on 2026/9/24.
//

/*
 * PicoRV32 中断（hostutil 库）—— 静态分发
 *
 * 硬件侧：rv32top.v 把外设中断线拼成 32 位送进 core 的 irq 端口。core 只有
 * 一个中断入口（PROGADDR_IRQ = 0x00000000），进入时把“这次要处理哪几条线”
 * 放进 q1。vectors.S 的 _irq_entry 压好栈后，用
 *
 *     getq a0, q1          把 q1（本次 pending 掩码）放进 a0
 *     call irq_dispatch    a0 就是 C 的第一个参数
 *
 * 交给下面的 irq_dispatch()，所以分发逻辑是纯 C。
 *
 * 本文件是静态分发：没有函数表、没有注册接口，4 个处理函数就是 4 个普通函数，
 * 库里给了 weak 空实现，你在自己的 .c 里定义同名函数即可覆盖。
 *
 * 通道号 == 硬件 irq 位号。core 自己占了 3 条线，不能接外部源：
 *
 *     bit 0 = timer        bit 1 = EBREAK / 非法指令       bit 2 = 总线错误
 *
 * 所以外部通道从 bit 3 开始。
 */

#ifndef GW1NR9_RV32_FIRMWARE_IRQ_H
#define GW1NR9_RV32_FIRMWARE_IRQ_H

#include <stdint.h>

/* 通道号就是硬件 irq 位号，直接当参数传给 IRQ_Enable() / IRQ_Disable()。 */
#define IRQ_CH0     3u
#define IRQ_CH1     4u
#define IRQ_CH2     5u
#define IRQ_CH3     6u

/*
 * 4 个通道的处理函数，你在自己的 .c 里定义同名函数覆盖库里的空实现。
 *
 * 注意：这里故意不写 __attribute__((weak))。如果头文件的声明带了 weak，你包含
 * 头文件后写的定义也会继承成 weak，于是和库里的空实现变成两个 weak 抢符号，
 * 谁赢取决于链接顺序——处理函数可能根本不执行。weak 只写在 IRQ.c 的定义处。
 *
 * 处理函数运行在 core 的 irq_active 保护下，不会嵌套，可以放心读写全局变量。
 */
void IRQ_Ch0_Handler(void);
void IRQ_Ch1_Handler(void);
void IRQ_Ch2_Handler(void);
void IRQ_Ch3_Handler(void);

/* 屏蔽全部通道并清零统计。core 复位后本来就是全屏蔽的。 */
void IRQ_Init(void);

/*
 * 放开 / 屏蔽单条线，参数就是 IRQ_CHn。
 * 屏蔽期间来的中断不会丢：pending 位仍然被硬件记住，解除屏蔽后立刻补上。
 */
void IRQ_Enable(uint16_t channel);
void IRQ_Disable(uint16_t channel);

/*
 * 调试用：累计出现过的、不属于这 4 个通道的 pending 位，也就是 core 内部的
 * bit 0/1/2 以及没用到的线。里面出现 0x02 就说明踩了 EBREAK / 非法指令。
 */
uint16_t IRQ_Unhandled(void);

/* 调试用：进入分发函数的累计次数（uint16_t，溢出回绕）。 */
uint16_t IRQ_Count(void);

/* 由 vectors.S 的 _irq_entry 调用，正常应用代码不用管。 */
void irq_dispatch(uint32_t pending);

#endif //GW1NR9_RV32_FIRMWARE_IRQ_H
