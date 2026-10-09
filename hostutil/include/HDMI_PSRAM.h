/*
 * HDMI 帧缓冲与片内 PSRAM 软件接口。
 *
 * 芯片内有两颗物理 4 MiB PSRAM die。软件地址不直接选择物理 die：
 * 0x0200_0000..0x023f_ffff 永远指向逻辑 BACK（后台）die，HDMI 则读取另一颗
 * 逻辑 FRONT（前台）die。SwapController 在帧边界原子交换两颗 die 的逻辑角色，
 * 交换过程只改变路由，不复制任何像素数据。
 *
 * 因此，放在 PSRAM 地址上的对象总是指向“当前后台 die”里的内容。交换前后台后，
 * 同一个地址将访问另一颗物理 die；除非两颗 die 已写入相同数据，否则不能指望
 * 交换前后读到的内容保持不变。
 */
#ifndef GW1NR9_RV32_HDMI_PSRAM_H
#define GW1NR9_RV32_HDMI_PSRAM_H

#include <stdint.h>

/* 有效画面格式：单帧 640*480 RGB565，共 614400 字节。 */
#define HDMI_WIDTH                 640u
#define HDMI_HEIGHT                480u
#define HDMI_FRAME_BYTES           (HDMI_WIDTH * HDMI_HEIGHT * 2u)

/* CPU 可见的逻辑 BACK 窗口。 */
#define HDMI_PSRAM_BASE            0x02000000u
#define HDMI_PSRAM_SIZE            0x00400000u

/*
 * 把对象放入链接脚本的 .psram NOLOAD 段。NOLOAD 表示下载镜像和复位代码都不会
 * 初始化该对象，内容必须由软件或 GPU 主动写入。对象若超出 4 MiB 逻辑窗口，
 * 链接器会直接报错。
 */
#define HDMI_PSRAM_SECTION __attribute__((section(".psram"), aligned(4)))

/* .psram 已分配区域和完整 4 MiB 逻辑窗口的链接器符号。 */
extern uint8_t __psram_base[];   /* 完整逻辑窗口的第一个字节 */
extern uint8_t __psram_limit[];  /* 完整逻辑窗口末尾的下一字节 */
extern uint8_t __psram_start[];  /* .psram 对象区的第一个字节 */
extern uint8_t __psram_end[];    /* .psram 对象区末尾的下一字节 */

/* 以不同元素宽度访问逻辑 BACK 窗口的 volatile 指针。 */
#define HDMI_PSRAM_U32 ((volatile uint32_t *)HDMI_PSRAM_BASE)
#define HDMI_PSRAM_U16 ((volatile uint16_t *)HDMI_PSRAM_BASE)
#define HDMI_PSRAM_U8  ((volatile uint8_t  *)HDMI_PSRAM_BASE)

/*
 * HDMI/PSRAM 配置页：0x0300_0000..0x0300_0fff。
 *
 * +0x04 STATUS     R   同步到 CPU 时钟域的实时状态；各位定义见下方。
 * +0x0c MAGIC      R   页面/版本魔数 0x48505331，即 ASCII "HPS1"。
 * +0x1c CTRL       R/W 位 0 控制 HDMI 取帧/输出；复位值为 0（关闭）。
 *
 * 原 +0x00、+0x08、+0x10、+0x14、+0x18 槽位保留并读回 0。所有寄存器均为
 * 32 位；写 CTRL 时必须使能最低字节通道。PSRAM CK 相位已经在 PLL 中固定为
 * 实测稳定的档位 5，不再提供软件配置寄存器。
 */
#define HDMI_PSRAM_CFG_BASE        0x03000000u
#define HDMI_PSRAM_STATUS_REG      (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x04u))
#define HDMI_PSRAM_MAGIC_REG       (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x0cu))
#define HDMI_PSRAM_CTRL_REG        (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x1cu))

#define HDMI_PSRAM_MAGIC_EXPECTED  0x48505331u /* ASCII "HPS1" */

/* HDMI_PSRAM_STATUS_REG 位定义；[31:6] 固定读回 0。 */
#define HDMI_PSRAM_INIT_DONE       (1u << 0) /* 两颗 die 均已完成 PHY 初始化 */
#define HDMI_PSRAM_PHY_BUSY        (1u << 1) /* PSRAM 桥/交换器通路正忙 */
#define HDMI_PSRAM_DIE0_READY      (1u << 2) /* 物理 die 0 已初始化 */
#define HDMI_PSRAM_DIE1_READY      (1u << 3) /* 物理 die 1 已初始化 */
#define HDMI_PSRAM_GPU_ACTIVE      (1u << 4) /* GPU 作业/突发正占用 BACK 通路 */
#define HDMI_PSRAM_HDMI_ACTIVE     (1u << 5) /* HDMI 突发正占用 FRONT 通路 */

/* HDMI_PSRAM_CTRL_REG 位定义。 */
#define HDMI_PSRAM_ENABLE          (1u << 0) /* 1：启用 HDMI 读帧与输出 */

/* 仅当两颗物理 die 都完成上电初始化后返回非零。 */
int HDMI_PSRAM_Ready(void);

/*
 * 忙等到 HDMI_PSRAM_Ready() 成立，并返回轮询循环次数。本函数故意不设超时；
 * 返回值只是循环次数，不是微秒数。
 */
uint32_t HDMI_PSRAM_WaitReady(void);

/* 开启 HDMI 帧缓冲读取；调用前应先初始化两颗物理 die 上的帧缓冲。 */
void HDMI_PSRAM_Enable(void);

#endif /* GW1NR9_RV32_HDMI_PSRAM_H */
