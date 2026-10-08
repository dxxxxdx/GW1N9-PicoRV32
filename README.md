# GW1N-9 PicoRV32 最小系统

程序通过 UART 下载到 FPGA 内部程序 BSRAM，按下 `START` 后 CPU 从地址
`0x0000_0000` 开始执行。系统还直接驱动 GW1NR-9C 的两个片内 x8 PSRAM die，
组成前台显示缓冲和后台绘制缓冲；没有使用官方 PSRAM IP。

当前内核启用的具体指令和关闭的扩展见 [INSTRUCTION_SET.md](INSTRUCTION_SET.md)。

## 当前硬件结构

```text
UART RX -> 裸字节程序加载器 -> 16 KiB 程序 BSRAM
                                      |
                                      v
                                 PicoRV32
                                      |
                           PicoRV32 native memory bus
                                      |
              +-----------------------+-----------------------+
              |                       |                       |
       16 KiB 数据 BSRAM          UART TX MMIO      4 MiB 后台 PSRAM 窗口
                                                               |
                                         CPU / GPU -> switcher <- HDMI
                                                        |   |
                                                     PHY0   PHY1
```

50 MHz 板载晶振经一个 rPLL 产生 40 MHz CPU/总线时钟、80 MHz PSRAM PHY
时钟以及可动态调相的 80 MHz PSRAM CK。当前实测相位通过窗口为 2..7，默认
选择窗口中点 5。

## 目录

```text
GW1N-9_rv32/
├── README.md
├── INSTRUCTION_SET.md       # 当前 RV32I 指令、伪指令和未启用扩展
├── firmware/
│   ├── hi.S                 # 手写 RV32I 示例：打印 hi 后死循环
│   ├── hi.bin               # UART 下载用裸二进制，36 字节
│   └── hi.hex               # 仿真 testbench 使用的逐字节十六进制文件
├── rv32/
│   ├── picorv32.v           # PicoRV32 原始核心
│   ├── rv32top.v            # 当前 FPGA 顶层
│   ├── busMember/
│   │   ├── busManager.v     # 地址译码与 native bus 路由
│   │   ├── psramController.v # CPU 32 位访问、跨时钟和 PSRAM 配置寄存器
│   │   ├── psramSwitcher.v   # front/back die 交换与 CPU/GPU 仲裁
│   │   ├── psramPhy.v        # 单个 x8 die 的 CA/RWDS/DDR PHY 状态机
│   │   ├── uartProgramMemory.v # 16 KiB UART 装载程序 BSRAM
│   │   ├── rv32RegisterRam.v   # 16 KiB 数据 BSRAM
│   │   ├── UARTRX.v         # 50 MHz / 115200 / 8-N-1 接收器
│   │   ├── UARTTX.v         # 50 MHz / 115200 / 8-N-1 发送器
│   │   └── UARTTX_MMIO.v    # PicoRV32 总线到 UART TX 的 MMIO 包装
│   └── miscmodule/
│       └── ButtonDebounce.v # RESET/START/IRQ 低有效按键消抖
├── tools/
│   └── uart_loader_gui.py   # 图形化程序下载和串口监听工具
├── legacy/
│   └── UART_Flash.v         # 旧字节核心实验代码，当前系统不使用
├── tb_busManager.v
├── tb_UARTTX_MMIO.v
├── tb_rv32top.v
└── uartVerifyTest/          # 早期独立 UART 上板验证工程
```

`legacy/UART_Flash.v` 是旧实验模块，不被当前 `rv32top` 例化，并且依赖旧的
`GowinFlash` 模块。构建当前 RV32 系统时不要把它加入源文件列表。

## Gowin 工程源文件

顶层模块选择 `rv32top`，只需添加：

```text
rv32/rv32top.v
rv32/picorv32.v
rv32/busMember/busManager.v
rv32/busMember/psramController.v
rv32/busMember/psramSwitcher.v
rv32/busMember/psramPhy.v
rv32/busMember/uartProgramMemory.v
rv32/busMember/rv32RegisterRam.v
rv32/busMember/UARTRX.v
rv32/busMember/UARTTX.v
rv32/busMember/UARTTX_MMIO.v
rv32/miscmodule/ButtonDebounce.v
```

顶层端口：

| 端口 | 方向 | 说明 |
|---|---|---|
| `clock50MHz` | 输入 | 50 MHz 主时钟 |
| `reset_n` | 输入 | 低有效物理按键，板上默认上拉 |
| `start` | 输入 | 低有效物理按键，确认下载完成并启动 CPU |
| `irq_n` | 输入 | 低有效物理按键，按下产生一拍脉冲，接 PicoRV32 的 irq bit 3（`IRQ_CH0`） |
| `uartRx` | 输入 | 115200 baud、8-N-1 |
| `uartTx` | 输出 | 115200 baud、8-N-1，空闲为高 |
| `trap` | 输出 | PicoRV32 非法指令、地址错误等陷阱指示 |

引脚位置和 IO 电平标准在板级 CST 中配置。主时钟还应加入 SDC 时序约束：

```tcl
create_clock -name clock50MHz -period 20.000 \
    -waveform {0.000 10.000} [get_ports {clock50MHz}]
```

## 地址空间

| CPU 字节地址 | 大小 | 当前用途 |
|---|---:|---|
| `0x0000_0000`–`0x0000_3fff` | 16 KiB | UART 装载的程序 BSRAM，只供 CPU 读取 |
| `0x0000_4000`–`0x0000_7fff` | 16 KiB | 数据 BSRAM |
| `0x0100_0000`–`0x0100_ffff` | 64 KiB | MMIO 窗口 |
| `0x0200_0000`–`0x023f_ffff` | 4 MiB | 当前后台 die 的逻辑 PSRAM 窗口 |
| `0x0300_0000`–`0x0300_0fff` | 4 KiB | PSRAM 状态、相位和换帧控制 |

PicoRV32 的复位入口是 `0x0000_0000`，初始栈顶配置为 `0x0000_8000`。
程序区和数据区各为 `4096 x 32 bit`，两者都带有 Gowin
`syn_ramstyle="block_ram"` 推导属性。存储数组本身不会在复位时清零，以免
破坏 BSRAM 推导；软件不能读取尚未写入的数据 RAM。

PSRAM 两个物理 die 各为 4 MiB。HDMI 端独占逻辑前台 die；CPU 与预留 GPU
端口共享逻辑后台 die，GPU 在事务边界拥有更高优先级。向 `0x0300_0018`
写 bit 0 只挂起交换请求，只有 HDMI 给出一帧完成脉冲、在途事务全部结束后，
switcher 才原子翻转 front/back 映射。没有 HDMI 时可同时写 bit 1 注入软件
帧完成脉冲做上板测试；详细寄存器定义见 `hostutil/include/PSRAM.h`。

PHY、switcher 与预留 GPU/HDMI 端口现在统一使用 1..64 个 16-bit beat 的
突发接口（最大 128 字节）。CPU 的一次 `lw/sw` 只发送一次 CA，随后用两个
连续的低 16 位 beat 完成；32 位拆分和拼接留在 CPU bridge 内，软件看到的
访问语义不变。读突发启动后不能反压，因此后续 HDMI 读取器必须先在 BSRAM
行缓冲中预留完整突发的空间。

## UART TX MMIO

三个寄存器位于同一个 32 位总线字的不同字节通道：

| CPU 地址 | 访问 | 作用 |
|---|---|---|
| `0x0100_0000` | 写 | 暂存待发送数据 |
| `0x0100_0001` | 写 | 写非零值触发发送 |
| `0x0100_0002` | 读 | `1` 表示空闲，`0` 表示忙 |

如果 UART 正忙，对发送使能字节的写访问会保持 `mem_ready=0`，CPU 自动停在
该总线事务上；上一帧完整停止位发送完后，访问才完成。

## 下载和启动

下载器接收的是原始 `.bin` 字节流，没有包头、长度字段和结束字符。物理
`START` 按键相当于“文件已经发完”的确认信号。镜像最大为 16384 字节；串口
帧错误或继续发送第 16385 字节会进入错误状态，必须复位后重传。

从仓库根目录启动 GUI：

```bash
python3 GW1N-9_rv32/tools/uart_loader_gui.py
```

上板顺序：

1. 按下并松开 `RESET`，等待复位释放消抖完成。
2. 在 GUI 中选择 `/dev/ttyACM*` 或 `/dev/ttyUSB*` 和 `.bin` 文件。
3. 点击“下载并监听串口”。
4. GUI 提示下载完成后，按下并松开 `START`。
5. CPU 的 UART 输出会直接显示在 GUI 日志框中。

`RESET` 按下后约两级同步器延迟便会停止 CPU；松开必须稳定约 50 ms 才释放。
复位会清除装载长度、错误状态和 `programLoaded`，所以复位后必须重新下载。

## 自检仿真

以下命令均在仓库根目录执行。

总线路由测试：

```bash
iverilog -g2012 -s tb_busManager -o /tmp/tb_busManager \
    GW1N-9_rv32/rv32/busMember/busManager.v \
    GW1N-9_rv32/tb_busManager.v
vvp /tmp/tb_busManager
```

UART TX MMIO 回环测试：

```bash
iverilog -g2012 -s tb_UARTTX_MMIO -o /tmp/tb_UARTTX_MMIO \
    GW1N-9_rv32/rv32/busMember/UARTRX.v \
    GW1N-9_rv32/rv32/busMember/UARTTX.v \
    GW1N-9_rv32/rv32/busMember/UARTTX_MMIO.v \
    GW1N-9_rv32/tb_UARTTX_MMIO.v
vvp /tmp/tb_UARTTX_MMIO
```

整机测试（UART 下载 `hi.bin`、按键启动、输出 `hi`、进入死循环）：

```bash
iverilog -g2012 -s tb_rv32top -o /tmp/tb_rv32top \
    GW1N-9_rv32/rv32/picorv32.v \
    GW1N-9_rv32/rv32/rv32top.v \
    GW1N-9_rv32/rv32/busMember/busManager.v \
    GW1N-9_rv32/rv32/busMember/uartProgramMemory.v \
    GW1N-9_rv32/rv32/busMember/rv32RegisterRam.v \
    GW1N-9_rv32/rv32/busMember/UARTRX.v \
    GW1N-9_rv32/rv32/busMember/UARTTX.v \
    GW1N-9_rv32/rv32/busMember/UARTTX_MMIO.v \
    GW1N-9_rv32/rv32/miscmodule/ButtonDebounce.v \
    GW1N-9_rv32/tb_rv32top.v
vvp /tmp/tb_rv32top
```

综合完成后应检查程序 RAM 和数据 RAM 都被推导为 BSRAM，并确认 50 MHz
时钟的 setup/hold 时序均无违例。
