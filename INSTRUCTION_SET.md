# 当前 PicoRV32 指令集

当前 `rv32top.v` 中的 PicoRV32 配置可以称为 **RV32I**：32 位基础整数
指令集、32 个通用寄存器，不包含乘除法、压缩指令、中断和硬件计数器。

汇编及编译工具链应使用：

```text
-march=rv32i -mabi=ilp32
```

手写汇编建议加入：

```asm
.option norvc
```

## 当前配置

与指令集直接相关的 PicoRV32 参数如下：

```verilog
.ENABLE_COUNTERS(0),
.ENABLE_COUNTERS64(0),
.ENABLE_REGS_16_31(1),
.COMPRESSED_ISA(0),
.CATCH_MISALIGN(1),
.CATCH_ILLINSN(1),
.ENABLE_PCPI(0),
.ENABLE_MUL(0),
.ENABLE_FAST_MUL(0),
.ENABLE_DIV(0),
.ENABLE_IRQ(0),
```

`ENABLE_REGS_16_31=1` 表示 `x0`～`x31` 全部存在。遇到不支持的指令或
未对齐访问时，核心会进入 `trap`。

## 支持的硬件指令

### 高位立即数和跳转

| 指令 | 作用 |
|---|---|
| `lui` | 将 20 位立即数写入目的寄存器高 20 位 |
| `auipc` | PC 加高位立即数 |
| `jal` | PC 相对跳转并保存返回地址 |
| `jalr` | 寄存器间接跳转并保存返回地址 |

### 条件分支

| 指令 | 条件 |
|---|---|
| `beq` | 相等 |
| `bne` | 不相等 |
| `blt` | 有符号小于 |
| `bge` | 有符号大于等于 |
| `bltu` | 无符号小于 |
| `bgeu` | 无符号大于等于 |

### 内存读取

| 指令 | 作用 |
|---|---|
| `lb` | 读取有符号字节 |
| `lbu` | 读取无符号字节 |
| `lh` | 读取有符号半字 |
| `lhu` | 读取无符号半字 |
| `lw` | 读取 32 位字 |

### 内存写入

| 指令 | 作用 |
|---|---|
| `sb` | 写入字节 |
| `sh` | 写入半字 |
| `sw` | 写入 32 位字 |

### 立即数整数运算

| 指令 | 作用 |
|---|---|
| `addi` | 加立即数 |
| `slti` | 有符号小于立即数则置 1 |
| `sltiu` | 无符号小于立即数则置 1 |
| `xori` | 按位异或立即数 |
| `ori` | 按位或立即数 |
| `andi` | 按位与立即数 |
| `slli` | 逻辑左移立即数 |
| `srli` | 逻辑右移立即数 |
| `srai` | 算术右移立即数 |

### 寄存器整数运算

| 指令 | 作用 |
|---|---|
| `add` | 加法 |
| `sub` | 减法 |
| `sll` | 逻辑左移 |
| `slt` | 有符号小于则置 1 |
| `sltu` | 无符号小于则置 1 |
| `xor` | 按位异或 |
| `srl` | 逻辑右移 |
| `sra` | 算术右移 |
| `or` | 按位或 |
| `and` | 按位与 |

当前没有桶形移位器，但上述所有移位指令仍然可用，只是由多周期迭代移位
电路执行。

### 环境和同步指令

| 指令 | 当前行为 |
|---|---|
| `fence` | 可以识别；当前单核、无缓存系统中基本等于空操作 |
| `ecall` | 进入 `trap`，没有操作系统系统调用处理程序 |
| `ebreak` | 进入 `trap` |

`fence.i` 当前不支持。

## 当前不支持的指令和扩展

### RV32M 乘除法扩展

以下指令均不可用：

```asm
mul
mulh
mulhsu
mulhu
div
divu
rem
remu
```

如有需要，可以在软件里实现乘除法，也可以重新启用 PicoRV32 的
`ENABLE_MUL`、`ENABLE_FAST_MUL` 和 `ENABLE_DIV` 参数。

### RV32C 压缩指令扩展

`COMPRESSED_ISA=0`，所以不支持任何 16 位压缩指令。每条机器指令固定为
32 位，PC 必须保持四字节对齐。

### CSR 和硬件计数器

当前不支持通用 CSR 读写指令：

```asm
csrrw
csrrs
csrrc
```

由于 `ENABLE_COUNTERS=0`，以下计数器读取指令同样不可用：

```asm
rdcycle
rdcycleh
rdtime
rdinstret
```

### 其他未启用功能

- RV32A 原子操作扩展；
- RV32F/RV32D 浮点扩展；
- RV32B 位操作扩展；
- PCPI 外部协处理器指令；
- PicoRV32 自定义 IRQ 指令和中断功能；
- 特权架构指令，例如 `mret` 和 `wfi`。

## 地址对齐要求

当前启用了 `CATCH_MISALIGN=1`，访问地址必须满足：

| 操作 | 对齐要求 |
|---|---|
| 取指 | 四字节对齐 |
| `lw`、`sw` | 四字节对齐 |
| `lh`、`lhu`、`sh` | 两字节对齐 |
| `lb`、`lbu`、`sb` | 无额外对齐要求 |

违反对齐要求会进入 `trap`。

## 汇编伪指令

以下写法可以交给汇编器使用，但它们不是 CPU 直接译码的真实指令，而是被
展开成一条或多条 RV32I 指令：

| 伪指令 | 典型展开 |
|---|---|
| `nop` | `addi x0, x0, 0` |
| `mv rd, rs` | `addi rd, rs, 0` |
| `li rd, imm` | `addi` 或 `lui` 加 `addi` |
| `j label` | `jal x0, label` |
| `ret` | `jalr x0, 0(ra)` |
| `call label` | `auipc` 加 `jalr` |

只要汇编器目标设置为 `rv32i`，这些伪指令最终就会被展开成当前内核支持的
机器指令。

## 推荐写法

纯手写汇编文件可以从下面的结构开始：

```asm
    .section .text.start, "ax", @progbits
    .globl _start
    .option norvc

_start:
    # 只使用 RV32I 指令

hang:
    jal x0, hang
```

当前内核应称为 **PicoRV32 RV32I**，不能称为 `RV32IM`、`RV32IC` 或
`RV32IMC`。
