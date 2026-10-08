# testpsram —— 1:1 @80MHz 内嵌 PSRAM DDR PHY 冒烟测试

**这个工程不是功能设计**，它只干一件事：把 GW1NR-9C 内嵌 PSRAM 的
**16 根 DQ DDR 收发路径**完整搭出来，让 Gowin 综合 + 布局布线跑一遍，回答三个问题：

1. 综合器认不认这套 `ODDR` / `IDDR` / `rPLL` 写法
2. `O_psram_*` / `IO_psram_*` 这些 magic 端口能不能自动绑到封装内部的 PSRAM
3. 80MHz 下 DDR 输出路径和 DDR 输入路径能不能收敛

读写结果只在内部打转，不输出到任何引脚。

## 打开

Gowin EDA → `File → Open Project` → 选 `testpsram.gprj`
（器件已写成 `GW1NR-9C / GW1NR-LV9QN88PC6/I5`）

然后依次：`Synthesize` → `Place & Route` → 看 `Timing Analysis`。

## 结构

```
clock50MHz (pin 63)
    └─ rPLL (IDIV=5, FBDIV=8, ODIV=8) 
         ├─ clk    80MHz  → fabric
         └─ clk_p  80MHz 相移 → 推 PSRAM CK
                │
          psram_phy (1:1 DDR PHY)
                ├─ 16 × ODDR  → IO_psram_dq[15:0]   写
                ├─ 16 × IDDR  ← IO_psram_dq[15:0]   读
                ├─ ODDR/IDDR  → IO_psram_rwds
                ├─ ODDR       → O_psram_ck[1:0]
                └─ ODDR       → O_psram_cs_n[1:0]
```

一次传输（两个 die 并行，16 根 DQ）：

| 阶段 | 拍数 | 说明 |
|---|---|---|
| CA | 3 | 48bit 命令地址，每个 die 各收到一遍同样的 48bit |
| 延迟 | LATENCY(6) | 固定延迟 = 2 × CR0[7:4] |
| 数据 | 32 | 128B，每拍 4B（16 线 × DDR） |
| 间隔 | 16 | CS 拉高，让器件插 refresh |

数据段效率 `32/38 ≈ 84%`，80MHz 下单通道理论 **~270MB/s**。

## 看什么

**1) 综合**
- 有没有 error
- 有没有关于 `O_psram_*` 未约束 / 无法分配的 warning

**2) 布局布线**
- 是否报 “IO 未约束”。**如果 PSRAM 那些口被当成普通用户 IO 要求约束，说明 magic 端口名没被识别**，这是最重要的一个信号。
- 资源占用（预期：几十个 LUT + 32 个 DDR 寄存器）

**3) 时序报告**
- 确认 PLL 输出被识别成 80MHz（周期 12.5ns）
- 重点看这两类的 setup/hold 余量：
  - `clk` → `ODDR` → pad（输出路径）
  - pad → `IDDR` → `clk`（输入路径）
- 报出来的 Fmax 是多少，余量多少

**4) 通过 / 不通过**
- 收敛：这套 PHY 可以继续往 128B burst 引擎上搭
- 不收敛：把 `MEM_CLK` 降到 60~70MHz 试，或者改走官方 IP 那种 1:2 变速（fabric 80MHz / memory 160MHz + IDES4/OSER4）

## 可调的旋钮

**换频率**（改 `gowin_rpll.v` 的 defparam）：

| 目标 | IDIV_SEL | FBDIV_SEL | ODIV_SEL | fPFD | fVCO |
|---|---|---|---|---|---|
| **80MHz**（当前） | 4 | 7 | 8 | 10 | 640 |
| 100MHz | 1 | 3 | 8 | 25 | 800 |
| 160MHz | 4 | 15 | 4 | 10 | 640 |
| 60MHz | 4 | 5 | 8 | 10 | 480 |

公式：`fCLKOUT = 50 × (FBDIV_SEL+1) / (IDIV_SEL+1)`，
`fVCO = fCLKOUT × ODIV_SEL`（要求 400~1200MHz）。

**CK 相位**：`PSDA_SEL`（当前 `"0010"`）。上板后用示波器看 CK 和 DQ 边沿关系，
要的是 DQ 跳变落在 CK 边沿中间。调不到就改用 2 倍频 + CLKDIV 方案。

**单 die / 双 die**：现在两个 die 一起选（16bit 并行）。
想看单 die 就把 `O_psram_cs_n[1]`、`O_psram_ck[1]`、`IO_psram_dq[15:8]`
那半边的 ODDR 删掉（参考开源工程只驱动 `[0]` 和 `dq[7:0]`）。

## 这个工程故意没做的（别拿它当能跑的控制器）

- **没有 CR0 配置**。真机上电后必须发一次寄存器写，把 burst length 设成 128、
  latency 设成对应时钟、fixed/variable latency 选好：
  ```
  CR0[15]   = 1        正常
  CR0[14:12]= 001      50Ω
  CR0[11:9] = 111      保留位写 1
  CR0[8,1,0] = 100     128 字节 burst
  CR0[7:4]  = 1110     3 clock latency (≤85MHz)
  CR0[3]    = 1        fixed latency（= 2 × 上面那个值）
  CR0[2]    = 1        wrapped（CA[45]=1 线性 burst 时无所谓）
  ```
  这个配置在 `psram_phy.v` 里没实现，写在 README 里提醒你。
- **没有 cycle 级对齐验证**。ODDR/IDDR 有 1 拍流水，CA 和数据段的实际相位
  必须仿真确认，别直接上板。
- **没有在线校准**（真机上 CK 相位/DQS 采样窗要标定）。
- **没有 refresh 管理**，只靠两次传输之间抬 CS。

## 实测结果（V1.9.11.03 Education，2026-10-08）

**综合**：0 warning / 0 error，magic 端口没有被抱怨。

**布局布线**：通过。

| 项目 | 结果 |
|---|---|
| Setup 违反端点 | **0** |
| Hold 违反端点 | **0** |
| Setup TNS | 0.000 |
| 最差 setup slack | **+6.146 ns**（周期 12.5ns，路径只用了 ~6.35ns） |
| 最差 hold slack | +0.561 ns |
| **Fmax（80MHz 约束下）** | **157.377 MHz**，Logic Level 2 |
| 分析路径 / 端点 | 731 / 369 |
| Setup 模型 | Slow 1.14V 85℃ C6/I5 |
| Hold 模型 | Fast 1.26V 0℃ C6/I5 |

**结论：1:1 @80MHz 收得很松，fabric 侧还有约 2 倍余量。**

**magic 端口自动绑定验证通过**（这是最关键的结论）：

| 端口 | 落点 |
|---|---|
| `O_psram_ck[0]` / `[1]` | p1-7 / p2-7 |
| `O_psram_cs_n[0]` / `[1]` | p1-9 / p2-9 |
| `IO_psram_rwds[0]` / `[1]` | p1-2 / p2-2 |
| `IO_psram_dq[7:0]` | p1-13 … p1-3（die1） |
| `IO_psram_dq[15:8]` | p2-13 … p2-3（die2） |

全部落在 `p1-*` / `p2-*` **封装内部 pad** 上，一个都没占外部引脚
（用户 I/O 只有 `clock50MHz` 1 个）。所以：
**两片 die 并行做 16bit 是成立的，dq[7:0]=die1、dq[15:8]=die2 的假设也对。**

**资源**：133 LUT / 129 FF / CLS 88 / **IOLOGIC 39/97（22 ODDR + 17 IDDR）**。
IOLOGIC 用掉 41%，后面加 HDMI 的 OSER10 还有余量（4 lane 大概再吃 4~8 个）。

## 这份报告**没有**证明的三件事

1. **外部时序没验**。SDC 里没写 `set_input_delay` / `set_output_delay`，
   那 731 条路径**全是 fabric 内部**的。pad→IDDR、ODDR→pad 的板级走线、
   CK 与 DQ 的 skew、PSRAM 的 tDVW 窗口，这份报告一个字都没管。
2. **IDDR 用转发 CK 采数据的采样窗口，STA 原理上就验不了**，
   只能上板用示波器扫 `PSDA_SEL`，或者做门级仿真。
3. **25 条最差路径里没有一条涉及 ODDR**（timing 报告里 `oddr` 0 命中，
   只有 `g_dq[*].iddr_dq`），说明输出方向比输入方向松。
   别误以为输出路径被严格卡过。

## 下一步

1. 把 burst 引擎补上（现在 FSM 更简单，157MHz 的余量足够容纳更复杂的控制逻辑）
2. 想再压就改 PLL 试 100MHz / 160MHz，看还能不能收敛
3. 板子回来后第一件事是扫 `PSDA_SEL` 定 CK 相位，**在示波器上量，不是在报告里看**

## 踩坑记录

**1. `ERROR (CK0021) ... cannot drive instance 'IO_psram_rwds_1_s0'(TBUF) by wire`**

`ODDR` / `IDDR` 在高云里是 **IOB 里的硬资源，一个实例绑定一个 pad**。
一个 ODDR 不能扇出到两根顶层线——给第二根线推断出的 TBUF 拿不到驱动源，就报这个。

所以 2 个 die 的 CK / CS / RWDS **必须每个 bit 各自一个 ODDR / IDDR**，
不能写 `assign O_psram_ck[1] = O_psram_ck[0];` 这种。DQ 本来就是 16 个 ODDR，
所以没踩到。现在代码里 CK/CS/RWDS/DQ 全是 generate 出来的独立实例。

**2. ODDR 的 `TX` 别悬空**

`TX=1` 是高阻，`TX=0` 是常输出。常输出的 CK / CS 显式接 `.TX(1'b0)`，
不然工具可能给 warning，或者行为不确定。

## 参考

- 开源 1:1 控制器（PHY 写法来源，Apache-2.0）：
  https://github.com/dominicbeesley/psram-tang-nano-9k
- 官方 HS IP 的完整用法示例：
  https://github.com/zf3/some-tang-nano-9k-examples/tree/main/02.psram
- HyperRAM CR0/CR1 位定义（这颗 die 是 Winbond W955D8MBYA）：
  Winbond HyperRAM Application Note
