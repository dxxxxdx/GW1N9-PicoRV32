# 双 die PSRAM 与 720p 帧缓冲规划

## 当前已实现

PicoRV32 可见的 PSRAM 窗口为 `0x0200_0000`–`0x027f_ffff`，共 8 MiB：

| CPU 地址 | PSRAM die | 容量 |
|---|---:|---:|
| `0x0200_0000`–`0x023f_ffff` | die 0 | 4 MiB |
| `0x0240_0000`–`0x027f_ffff` | die 1 | 4 MiB |

两个 die 各有一套独立的 CK、CS、RWDS 和 8 位 DQ PHY。CPU 的 32 位访问在选中的
die 内拆成两个 16 位事务；`sb/sh/sw` 通过 RWDS 写掩码保持正确的字节语义。

- CPU / 总线：40 MHz
- 两路 PSRAM PHY：80 MHz，latency 3
- PSRAM CK：80 MHz、上电相位 4（90 度），固件可在 16 个 `PSDA` tap 中训练
- CPU 与 PHY：request/ack toggle 跨时钟握手
- CR0：`0x9FEF`，35 Ω drive、固定 2× latency
- 复位释放后等待 160 us，再分别初始化两颗 die

PicoRV32 启用了原生 `TWO_CYCLE_ALU` 和 `TWO_CYCLE_COMPARE`，使双 PHY 加入后 CPU
仍能在 40 MHz 下通过时序。当前布局布线报告中 CPU 40 MHz、PHY 80 MHz 均无
setup/hold 违例。

## 为什么使用两个独立 bank

目标显示模式是 1280×720、60 Hz、RGB565。一帧大小为：

```text
1280 × 720 × 2 = 1,843,200 bytes
```

每颗 4 MiB die 都能单独放下一整帧。后续显示控制器采用 bank ping-pong：

- HDMI/DMA 始终只读 front die；
- CPU/MMIO 写入引擎始终只写 back die；
- CPU 没有提交新帧时，HDMI 重复扫描当前 front die；
- back die 写满并提交后，只在垂直消隐/帧边界交换 front/back；
- 两颗 die 的读写物理独立，因此显示扫描与软核准备下一帧可以真正并行。

这比把相邻字或半字交错到两个 die 更适合无撕裂双缓冲。

## HDMI 阶段需要增加的接口

当前 CPU 数据窗口仍是非突发调试路径，不能直接持续供应 720p60。RGB565 的平均
有效像素读取量约为 110.6 MB/s；80 MHz 单 die 的 x8 DDR 数据阶段理论值为
160 MB/s，因此视频端必须使用长突发和行缓冲摊薄 CA/latency 开销。

计划的视频数据路径：

1. front die 使用 128-byte 对齐读突发；
2. 每行 2560 bytes，正好是 20 个 128-byte 块；
3. 两个 2560-byte BSRAM 行缓冲交替填充/显示；
4. 74.25 MHz 像素域只读取行缓冲，不直接等待 PSRAM；
5. 垂直消隐期间预取首行，并在帧边界处理 bank swap。

计划的软核 MMIO 是流式写入口，而不是把整个 PSRAM 暴露成普通低延迟 RAM：

- `FRAME_DATA`：写两个 RGB565 像素（32 bit），满时通过总线 backpressure；
- `FRAME_STATUS`：back bank、已接收字节数、FIFO/写引擎状态；
- `FRAME_COMMIT`：仅在完整收到 1,843,200 bytes 且写 FIFO 排空后接受；
- `FRAME_ID`：提交号和实际显示号，供软件确认交换完成。

## 诊断寄存器

诊断窗口位于 `0x0300_0000`：

| 偏移 | 内容 |
|---:|---|
| `0x00` | PHY 频率，当前 `80_000_000` |
| `0x04` | bit0=双 die ready，bit1=busy，bit2=die0 ready，bit3=die1 ready |
| `0x08` | CK 动态相位；低 4 bit 可读写，复位值为 4 |
| `0x0c` | 版本戳 `0x50535246`（`PSRF`，固定 latency） |
| `0x10` | `clk_p` 活性计数 |
| `0x14` | CPU 可见容量，`0x00800000` |

测试固件先逐一扫描 16 个相位。每个相位在两颗 die 上各测试 128 KiB、两套互补
地址相关图案，然后从两颗 die 共同通过的最长连续相位窗口选择中心 tap。训练会覆盖
每颗 die 开头的 128 KiB，必须在帧缓冲或应用数据写入前运行。随后固件再检查两颗
die 的边界、所有字节/半字通道以及完整 8 MiB 地址相关图案；成功时最后输出
`full 8 MiB: PASS`。

PHY 参考：<https://github.com/zf3/psram-tang-nano-9k>（Apache-2.0）。80 MHz
驱动强度修正来自该项目 pull request #10。
