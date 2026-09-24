//
// Created by dxx on 2026/9/24.
//

#include "IRQ.h"

/* 4 个通道对应的硬件位。加通道时这里、头文件、irq_dispatch 一起改。 */
#define IRQ_ALL_BITS    ((1u << IRQ_CH0) | (1u << IRQ_CH1) | \
                         (1u << IRQ_CH2) | (1u << IRQ_CH3))

/*
 * irq_mask 是「1 = 屏蔽」，复位值全 1。core 没提供只读它的办法，所以本模块
 * 自己维护影子，每次整份写回去。
 */
static uint32_t s_masked = 0xFFFFFFFFu;

static uint16_t s_unhandled = 0u;
static uint16_t s_count = 0u;

/*
 * maskirq：把 rs1 写进 irq_mask 并返回旧值，是 PicoRV32 的私有指令
 * （custom-0，funct7 = 0b0000011）。binutils 不认识，只能手写编码：
 *
 *     funct7(0b0000011) << 25 | rs1(a0=10) << 15 | rd(x0=0) << 7 | opcode
 *   = 0x0605000b
 *
 * 收下 C 的第一个参数（按 ABI 就在 a0），旧值写进 x0 丢弃——我们不需要，
 * 影子变量 s_masked 已经记着当前掩码。
 */
static void IRQ_WriteMask(uint32_t mask)
{
    register uint32_t value __asm__("a0") = mask;

    __asm__ volatile (".word 0x0605000b" : : "r"(value) : "memory");
}

/*
 * 4 个处理函数的 weak 空实现。weak 只加在这里（定义处），上面头文件的声明不带
 * 属性，所以你在别的 .c 里写的同名函数是强符号，链接时会盖掉这些空壳。
 */
__attribute__((weak)) void IRQ_Ch0_Handler(void) { }
__attribute__((weak)) void IRQ_Ch1_Handler(void) { }
__attribute__((weak)) void IRQ_Ch2_Handler(void) { }
__attribute__((weak)) void IRQ_Ch3_Handler(void) { }

void IRQ_Init(void)
{
    s_unhandled = 0u;
    s_count = 0u;

    /* 和 core 复位值一致：全部屏蔽。 */
    s_masked = 0xFFFFFFFFu;
    IRQ_WriteMask(s_masked);
}

void IRQ_Enable(uint16_t channel)
{
    if (channel > 31u)
        return;

    s_masked &= ~((uint32_t)1u << channel);
    IRQ_WriteMask(s_masked);
}

void IRQ_Disable(uint16_t channel)
{
    if (channel > 31u)
        return;

    s_masked |= ((uint32_t)1u << channel);
    IRQ_WriteMask(s_masked);
}

uint16_t IRQ_Unhandled(void)
{
    return s_unhandled;
}

uint16_t IRQ_Count(void)
{
    return s_count;
}

/*
 * 由 vectors.S 的 _irq_entry 调用，pending 就是 core 放在 q1 里的掩码。
 *
 * 硬件在进入中断时已经把待处理的 pending 位清掉了，所以这里的每一位都必须被
 * 处理——漏掉一个就等于把那次中断丢了。因此下面用 4 个独立的 if，绝不能写成
 * else if。
 *
 * 本函数执行期间新来的中断不在这个掩码里（irq_active 挡着进不来），硬件会
 * 记住它们，并在 retirq 之后重新进入一次。
 */
void irq_dispatch(uint32_t pending)
{
    ++s_count;

    if (pending & (1u << IRQ_CH0))
        IRQ_Ch0_Handler();

    if (pending & (1u << IRQ_CH1))
        IRQ_Ch1_Handler();

    if (pending & (1u << IRQ_CH2))
        IRQ_Ch2_Handler();

    if (pending & (1u << IRQ_CH3))
        IRQ_Ch3_Handler();

    /* 不属于这 4 条线的位（core 内部的 0/1/2、以及没用到的线）记下来方便调试。 */
    s_unhandled |= (uint16_t)(pending & ~IRQ_ALL_BITS);
}
