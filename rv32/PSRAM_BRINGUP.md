# PSRAM 低速口 bring-up 说明

PicoRV32 系统在 **40MHz** 下挂了 GW1NR-9C 封装内部的 PSRAM，**4 MiB 当普通内存读写**。
这一版只有低速口（随机 32bit），高速口（128 字节长突发）后面挂到 MMIO 段。

## 为什么是 40MHz 而不是 80 或 50

同一份逻辑，只换时钟源，实测（Gowin V1.9.11.03，GW1NR-9C C6/I5）：

| 配置 | setup 违反 | 最差路径 |
|---|---|---|
| 引脚 50MHz 直连（改之前的基线） | 0 | 19.884ns（周期 20ns） |
| 同一份逻辑改走 PLL 50MHz | 47 | 21.688ns |
| PLL 80MHz | 584 | 19.48ns（周期 12.5ns） |
| **PLL 40MHz（当前）** | **0** | 24.933ns（周期 25ns） |

结论：
1. **PLL 出来的时钟本身要吃约 1.8ns**（同样的 CPU 内部路径，直连 19.5ns，走 PLL 21.7ns）。
2. PicoRV32 在这颗片子上走 PLL 时 Fmax 只有 **~40MHz**，走引脚直连才勉强够 50MHz。
3. 所以系统跑 40MHz，PSRAM PHY 也 1:1 跑 40MHz。要提带宽得另想办法（见文末）。

注意 40MHz 那份报告的 slack 只有 +0.024ns —— Gowin 的布线器**满足约束就停**，
不会继续优化，所以 Fmax 报出来 40.038 是"刚好够"，不代表只有 0.1% 余量。
想知道真实余量就把约束卡紧（改 `SYS_CLK_HZ` + PLL）再跑一次。

## 地址映射

```
0x0000_0000  16 KiB  程序 BSRAM
0x0000_4000  16 KiB  数据 BSRAM
0x0100_0000  64 KiB  UART MMIO
0x0200_0000  4 MiB   PSRAM 数据窗口   <- 当普通内存用
0x0300_0000  4 KiB   PSRAM 配置窗口
```

配置窗口（局部偏移）：

| 偏移 | 名称 | 说明 |
|---|---|---|
| 0x000 | CFG | bit[3:0] `rdLat`（默认 6），bit[7:4] `wrLat`（默认 4），用 `sw` 一次写两个 |
| 0x004 | STATUS | bit0 `initDone`，bit1 `phyBusy` |

## 新增 / 改动

| 文件 | 说明 |
|---|---|
| `rv32/gowin_rpll.v` | 新增，50MHz → 80MHz + 相移输出 |
| `rv32/busMember/psramPhy.v` | 新增，1:1 DDR 物理层（22 ODDR + 17 IDDR） |
| `rv32/busMember/psramController.v` | 新增，总线翻译 + 上电 CR0 配置 |
| `rv32/busMember/busManager.v` | 预留窗口改成 PSRAM 数据 + 配置两个窗口 |
| `rv32/rv32top.v` | 换成 80MHz，加 PLL、PSRAM magic 端口、控制器 |
| `rv32/busMember/UARTRX.v` | 采样分频 27 → 43 拍（115200 波特） |
| `rv32/busMember/UARTTX.v` | 位周期 434 → 694 拍 |

## 上电序列

`cpuReset_n` 释放后，控制器自己走：

1. 等 20000 拍（250µs > tRPU 150µs）
2. 写一次 CR0 = `0x8FEF`
   （正常 / 25Ω / 32 字节 burst / 初始延迟 3 拍 / **固定延迟 = 6 拍** / wrap）
3. `initDone = 1`，才开始接受 CPU 访问

在这之前 CPU 对 0x0200_0000 的访问会一直等 `mem_ready`，不会错，只是慢。

## 第一次测试

固件侧已经备好：

* `dxxdxLink.ld` 里有 `PSRAM` / `PSRAM_CFG` 两个 MEMORY 区，和一个
  `.psram`（NOLOAD）段，符号 `__psram_base` / `__psram_limit` /
  `__psram_start` / `__psram_end` / `__psram_cfg_base`
* `hostutil/include/PSRAM.h` + `PSRAM.c`，已加进 CMakeLists
* `start.S` 在进 `main` 之前会先等 `initDone`，所以 main 里不用自己等

两种用法：

```c
#include "PSRAM.h"

/* 方式一：变量直接进 .psram 段（只有一个属性） */
PSRAM u8  data[100];
PSRAM u32 frame[1280 * 720 / 4];

/* 方式二：当一整块内存，手工寻址 */
volatile u32 *fb = PSRAM_U32;
```

`PSRAM` 就是 `__attribute__((section(".psram"), aligned(4)))`。
`aligned(4)` 保证每个变量都落在 4 字节边界；段基址的对齐由链接脚本里的
`ASSERT((__psram_start & 3) == 0, ...)` 兜底。

> C 的 `_Static_assert` 拿不到链接期地址，用它断言变量对齐是没用的
> （拿一个故意不 `aligned` 的变量试过，照样编译通过），所以放在链接脚本。

测试：

```c
PSRAM_WaitReady();                      /* 其实 start.S 已经等过了 */

uint32_t bad = PSRAM_TestPattern(1024); /* 第一个不一致的字下标 */
if (bad != 1024) { /* 失败 */ }

/* 字节操作：sb 只改一个字节 */
PSRAM_U32[0] = 0x11223344u;
*(volatile u8 *)&PSRAM_U32[0] = 0x77;
if (PSRAM_U32[0] != 0x11223377u) { /* 字节通道不对 */ }
```

`.psram` 是 NOLOAD 段：不会进 .bin，`_start` 也不会初始化它，所以
`PSRAM` 声明的变量上电是随机值。已经验证过：段放在 0x02000000，
`objcopy -O binary` 出来的 .bin 仍然是几百字节，不会被撑成 4MB。

**`sw`/`lw` 通不通和 die 的字节顺序无关**：PHY 的发送和接收是逐位对称的，
写进去读出来一定一样。只有 `sb` 才会暴露字节通道的问题，而通道映射在
`psramPhy.v` 里是自洽的（`mem_wstrb` 的 bit L ↔ tx/rx 的字节 L），所以
上面第三段测试应该也能过。

## rdLat / wrLat 怎么扫

默认 `rdLat=6`、`wrLat=4`，是按"CR0 固定延迟 6 拍 + 写方向 ODDR 自带一拍流水"
推出来的，**但 CA 从哪一拍算起、IO 绕一圈多久只有实测知道**。

现象和做法：

* 读回来全 `0` 或全 `0xFFFFFFFF` -> 采样点完全错，从 0 开始每次 +1 扫到 15
* 读回来是**相邻地址的数据** -> 差一两拍，微调 `rdLat`
* 写不进去（读回来是旧值）-> 调 `wrLat`，同样从 0 扫到 15

扫描循环：

```c
PSRAM_WaitReady();

for (uint32_t d = 0; d < 16; d++) {
    PSRAM_SetLatency(d, 4);            /* rdLat = d，wrLat 先固定 4 */
    PSRAM_U32[0] = 0x12345678u;
    uint32_t v = PSRAM_U32[0];
    /* 打印 d 和 v，v == 0x12345678 就是扫到了 */
}
```

`wrLat` 同理：先用一个已知的 `rdLat` 把读调对，再扫 `wrLat` 写到固定地址，
读回来比对。

## 已知不确定的地方

* **容量**。现在只映射 4 MiB。CA 里的地址字段只到 `字节地址[21:1]`，
  再往上要一位，得先确认这颗 die 到底是 32Mbit 还是 64Mbit，以及两个 die
  是"同一地址各出一个字节"还是别的组织方式。用 `PSRAM[N]` 往高地址写图案
  试探就知道边界在哪。
* **CK 相位**。`gowin_rpll.v` 里 `PSDA_SEL = "0010"` 是拍的，上板看示波器调。
  相位不对时 `rdLat` 怎么扫都对不上。
* **复位期间**。`O_psram_reset_n` 跟的是 `cpuReset_n`，也就是按下 START
  之后才释放，所以 PSRAM 的 250µs 等待发生在程序开始跑之后。第一次访问
  会卡 ~250µs，属正常。
* **命名**。`UARTRX` / `UARTTX` / `ButtonDebounce` 的时钟端口还叫
  `clock50MHz`，实际接的是 80MHz 的 `sysClk`，只是没改名的历史包袱。

## 还没做

* 高速口（128 字节长突发）——按计划挂到 MMIO 段，PHY 的 `len` 已经改成
  运行时输入，加个描述符/窗口就行
* 命令流水（现在一次事务完才能发下一次，显示通道吞吐还不够）
* 行缓冲 + 显示扫描引擎
* 2CH 拆分
