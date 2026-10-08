//
// PSRAM（GW1NR-9C 封装内部）低速口 hostutil 库头
//
// 硬件：rv32/busMember/psramController.v
//   0x0200_0000  4 MiB  PSRAM 数据窗口，当普通内存读写
//   0x0300_0000  4 KiB  PSRAM 配置窗口
//
// 数据窗口支持 lw / lh / lhu / lb / lbu / sw / sh / sb，读写双向。
// 每一次访问都是一趟完整的 PSRAM 事务（CA + 延迟 + 数据），80MHz 下
// 大约 15~18 拍，也就是两百多纳秒。所以：
//
//   - 当普通内存用没问题
//   - 但不要指望它快，连续搬运请走以后的高速口
//

#ifndef GW1NR9_RV32_PSRAM_H
#define GW1NR9_RV32_PSRAM_H

#include <stdint.h>

/* 简写类型，方便写 PSRAM u8 buf[100]; 这种声明。 */
typedef uint8_t  u8;
typedef uint16_t u16;
typedef uint32_t u32;

/* ---------------------------------------------------------------- 数据窗口 */

#define PSRAM_BASE      0x02000000u
#define PSRAM_SIZE      0x00400000u     /* 4 MiB */

/*
 * 把变量放进 PSRAM 段，就这么一个属性：
 *
 *   PSRAM u8  data[100];
 *   PSRAM u32 frame[1280 * 720 / 4];
 *
 * 展开成 __attribute__((section(".psram"), aligned(4)))。
 *
 * aligned(4) 保证变量落在 4 字节边界，lw/sw 不会撞 CATCH_MISALIGN；
 * 段基址本身的对齐由链接脚本里的 ASSERT 兜底（C 的 _Static_assert 看不到
 * 链接期地址，拿它断言对齐是没有意义的，已经试过了）。
 *
 * 注意 .psram 是 NOLOAD 段：不进 .bin，_start 也不会初始化它，
 * 所以上电内容是随机的，必须自己赋初值。
 */
#define PSRAM __attribute__((section(".psram"), aligned(4)))

/* 用链接脚本给的符号，和上面两个宏是同一回事，选一个用就行。 */
extern uint8_t __psram_base[];
extern uint8_t __psram_limit[];
extern uint8_t __psram_start[];
extern uint8_t __psram_end[];

/* 把 PSRAM 当一整块内存用的便捷指针。 */
#define PSRAM_U32       ((volatile uint32_t *)PSRAM_BASE)
#define PSRAM_U8        ((volatile uint8_t  *)PSRAM_BASE)

/* ---------------------------------------------------------------- 配置窗口 */

#define PSRAM_CFG_BASE  0x03000000u

#define PSRAM_CFG_ADDR    0x03000000u   /* [3:0] rdLat  [7:4] wrLat */
#define PSRAM_STATUS_ADDR 0x03000004u   /* [0] initDone  [1] phyBusy */
#define PSRAM_CKPHASE_ADDR 0x03000008u  /* [3:0] PSRAM CK 相移 */
#define PSRAM_MAGIC_ADDR   0x0300000Cu  /* 位流版本戳，应为 0x50535238 */
#define PSRAM_CKPCNT_ADDR  0x03000010u  /* clk_p 活性计数（读两次比较） */
#define PSRAM_REGRD_CTRL   0x03000014u  /* 写一次触发 CR0 回读 */
#define PSRAM_REGRD_DATA   0x03000018u  /* CR0 回读结果 */
#define PSRAM_CR0VAL_ADDR  0x0300001Cu  /* 要写进 CR0 的 16bit 值 */
#define PSRAM_REGRW_ADDR   0x03000020u  /* 写一次触发 CR0 写 */

#define PSRAM_CFG_REG       (*(volatile uint32_t *)PSRAM_CFG_ADDR)
#define PSRAM_STATUS_REG    (*(volatile uint32_t *)PSRAM_STATUS_ADDR)
#define PSRAM_CKPHASE_REG   (*(volatile uint32_t *)PSRAM_CKPHASE_ADDR)
#define PSRAM_MAGIC_REG     (*(volatile uint32_t *)PSRAM_MAGIC_ADDR)
#define PSRAM_CKPCNT_REG    (*(volatile uint32_t *)PSRAM_CKPCNT_ADDR)
#define PSRAM_REGRD_CTRL_REG (*(volatile uint32_t *)PSRAM_REGRD_CTRL)
#define PSRAM_REGRD_DATA_REG (*(volatile uint32_t *)PSRAM_REGRD_DATA)
#define PSRAM_CR0VAL_REG    (*(volatile uint32_t *)PSRAM_CR0VAL_ADDR)
#define PSRAM_REGRW_REG     (*(volatile uint32_t *)PSRAM_REGRW_ADDR)

#define PSRAM_MAGIC_EXPECTED 0x50535238u

/* 触发一次 CR0 回读；结果从 PSRAM_REGRD_DATA_REG 读。
 * 器件正常应答时，两个 die 各回一个 16bit，拼出来是 0x8F8FEFEF（就是我们写进去
 * 的 CR0）——因为 x8 die 上第一个字节在上升沿、第二个在下降沿。 */
static inline void PSRAM_ReadCR0(void)
{
    PSRAM_REGRD_CTRL_REG = 1u;
}

/* 写一次 CR0。用来验证"写进去再读回来"这条链路：
 * 写几个不同的合法值，看回读跟不跟着变。 */
static inline void PSRAM_WriteCR0(uint32_t value)
{
    PSRAM_CR0VAL_REG = value & 0xFFFFu;
    PSRAM_REGRW_REG = 1u;
}

#define PSRAM_STATUS_INIT_DONE  (1u << 0)
#define PSRAM_STATUS_PHY_BUSY   (1u << 1)

/* 初始化是否完成；没完成时对数据窗口的访问会一直等 ready，不会出错。 */
static inline int PSRAM_Ready(void)
{
    return (PSRAM_STATUS_REG & PSRAM_STATUS_INIT_DONE) != 0u;
}

/* 设置采样对齐。rdLat = CA 结束后读方向额外等的拍数，wrLat 同理，范围都是 0~63。
 * 默认 rdLat = 6 / wrLat = 4，实际值必须上板扫，不要盲信默认值。
 * 位映射：rdLat 在 [5:0]，wrLat 在 [13:8]。
 *
 * 为什么是 6 位：4 位（0~15）扫不到数据。实测寄存器读只在 rd=15 蹭到尾巴，
 * 说明整个链路（ODDR 流水 + 器件 tACC + IDDR 采样）的延迟超过 15 拍。 */
static inline void PSRAM_SetLatency(uint32_t rdLat, uint32_t wrLat)
{
    PSRAM_CFG_REG = ((wrLat & 0x3Fu) << 8) | (rdLat & 0x3Fu);
}

/* PSRAM CK 相对 fabric 时钟的相移（0~15，直接喂 rPLL 的 PSDA 输入）。
 * 这个决定采样点落在数据眼的哪个位置，是三个旋钮里最关键的：
 * rdLat 只能挪整拍，相位不对时怎么挪都对不上。默认 4。 */
static inline void PSRAM_SetCkPhase(uint32_t phase)
{
    PSRAM_CKPHASE_REG = phase & 0xFu;
}

static inline uint32_t PSRAM_GetCkPhase(void)
{
    return PSRAM_CKPHASE_REG & 0xFu;
}

/* 等初始化完成，返回等待用的循环次数（用于粗测）。 */
static inline uint32_t PSRAM_WaitReady(void)
{
    uint32_t spin = 0;
    while (!PSRAM_Ready())
        spin++;
    return spin;
}

/*
 * 搬运自检：往 [0, words) 写图案再读回比对。
 * 返回第一个不一致的字下标，全对返回 words。
 *
 * 注意先扫好 rdLat / wrLat 再调用，否则一定失败。
 */
uint32_t PSRAM_TestPattern(uint32_t words);

#endif /* GW1NR9_RV32_PSRAM_H */
