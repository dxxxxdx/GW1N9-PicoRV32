`timescale 1ns / 1ps
`default_nettype none

// 第一版最小 RV32 系统：
//   - UART RX 裸字节流装载 16 KiB 程序 reg 数组；
//   - start 按键确认装载完成并释放 PicoRV32；
//   - 16 KiB 数据 RAM 使用普通 reg 数组；
//   - UART TX 位于 MMIO 0x0100_0000 的前三个字节；
//   - irq_n 按键经消抖后产生一个时钟周期的脉冲，接到 PicoRV32 的 irq bit 3
//     （hostutil 里的 IRQ_CH0），固件侧由 IRQ_Ch0_Handler() 处理；
//   - 不实例化 SPI Flash，4 MiB 预留窗口为空。
//
// reset_n、start、irq_n 都是低有效物理按键：默认上拉为 1，按下接地为 0。
// 三者都经过消抖，
// start 应在最后一个 UART 字节发送完成后再按下。
module rv32top #(
    // 50 MHz 下 2,500,000 拍 = 50 ms；仿真可覆盖成较小值。
    parameter [21:0] BUTTON_FILTER_CYCLES = 22'd2_500_000
) (
    input  wire        clock50MHz,
    input  wire        reset_n,
    input  wire        start,
    input  wire        irq_n,
    input  wire        uartRx,
    output wire        uartTx,
    output wire        trap
);
    // 复位按下只等待两级同步，尽快让系统停下；松开必须稳定满消抖时间。
    // POWERUP_PRESSED 让 FPGA 上电后先保持复位，再等待 reset_n 稳定为高。
    wire systemReset_n;
    wire unused_resetPressPulse;
    ButtonDebounce #(
        .FILTER_CYCLES(BUTTON_FILTER_CYCLES),
        .FAST_PRESS(1),
        .POWERUP_PRESSED(1)
    ) resetButton (
        .clock50MHz(clock50MHz),
        .reset_n(1'b1),
        .button_n(reset_n),
        .debounced_n(systemReset_n),
        .pressPulse(unused_resetPressPulse)
    );

    // start 按键默认上拉，按下接地。pressPulse 只持续一个系统时钟周期，
    // 长按不会重复启动。
    wire startRequest;
    wire unused_startDebounced_n;
    ButtonDebounce #(
        .FILTER_CYCLES(BUTTON_FILTER_CYCLES)
    ) startButton (
        .clock50MHz(clock50MHz),
        .reset_n(systemReset_n),
        .button_n(start),
        .debounced_n(unused_startDebounced_n),
        .pressPulse(startRequest)
    );

    // 中断按键：同样默认上拉、按下接地。pressPulse 只高一个 50 MHz 周期，
    // 正好适合直接接中断线——线必须在 handler 执行 retirq 之前落下，脉冲源
    // 天然满足；换成电平的话按住不放会反复重进中断。
    wire irqRequest;
    wire unused_irqDebounced_n;
    ButtonDebounce #(
        .FILTER_CYCLES(BUTTON_FILTER_CYCLES)
    ) irqButton (
        .clock50MHz(clock50MHz),
        .reset_n(systemReset_n),
        .button_n(irq_n),
        .debounced_n(unused_irqDebounced_n),
        .pressPulse(irqRequest)
    );

    // 中断线向量：目前只用了 bit 3，也就是 hostutil 里的 IRQ_CH0。
    // bit 0/1/2 被 core 内部占用（timer / EBREAK / 总线错误），不要接外部信号。
    wire [31:0] irqLines = {28'd0, irqRequest, 3'd0};

    // ---------------------------------------------------------------------
    // UART 程序装载
    // ---------------------------------------------------------------------
    wire [7:0] rxByteData;
    wire rxByteValid;
    wire rxFramingError;
    wire rxBusy;

    UARTRX receiver (
        .clock50MHz(clock50MHz),
        .reset_n(systemReset_n),
        .uartRx(uartRx),
        .byteData(rxByteData),
        .byteValid(rxByteValid),
        .framingError(rxFramingError),
        .busy(rxBusy)
    );

    reg startPending;
    reg programLoaded;
    reg loadError;
    reg [15:0] loadedBytes;

    // 最大正好接收 0x4000 个字节。第 16384 个字节写入地址 0x3fff
    // 后 loadedBytes 变为 0x4000；继续发送会置 loadError。
    wire loaderWrite = systemReset_n && !programLoaded && !loadError &&
                       rxByteValid && (loadedBytes < 16'h4000);

    always @(posedge clock50MHz) begin
        if (!systemReset_n) begin
            startPending <= 1'b0;
            programLoaded <= 1'b0;
            loadError <= 1'b0;
            loadedBytes <= 16'd0;
        end else begin
            if (!programLoaded) begin
                if (rxFramingError ||
                    (rxByteValid && loadedBytes == 16'h4000)) begin
                    loadError <= 1'b1;
                    startPending <= 1'b0;
                end else begin
                    if (loaderWrite)
                        loadedBytes <= loadedBytes + 16'd1;

                    // 空程序不启动；出错后必须 reset 再重新上传。
                    if (startRequest && loadedBytes != 16'd0 && !loadError)
                        startPending <= 1'b1;

                    // UARTRX 的 byteValid 在最后一个字节后保持一拍，等它
                    // 被存储器采样后再释放 CPU。
                    if (startPending && !rxBusy && !rxByteValid) begin
                        programLoaded <= 1'b1;
                        startPending <= 1'b0;
                    end
                end
            end
        end
    end

    // CPU、RAM 和 TX 在程序确认前保持复位。RX 和装载计数器只受外部
    // systemReset_n 控制，所以 CPU 停止期间仍能完整接收程序。
    wire cpuReset_n = systemReset_n && programLoaded;

    // ---------------------------------------------------------------------
    // PicoRV32 原生总线
    // ---------------------------------------------------------------------
    wire cpu_mem_valid;
    wire cpu_mem_instr;
    wire cpu_mem_ready;
    wire [31:0] cpu_mem_addr;
    wire [31:0] cpu_mem_wdata;
    wire [3:0] cpu_mem_wstrb;
    wire [31:0] cpu_mem_rdata;

    wire mem_la_read;
    wire mem_la_write;
    wire [31:0] mem_la_addr;
    wire [31:0] mem_la_wdata;
    wire [3:0] mem_la_wstrb;
    wire pcpi_valid;
    wire [31:0] pcpi_insn;
    wire [31:0] pcpi_rs1;
    wire [31:0] pcpi_rs2;
    wire [31:0] eoi;
    wire trace_valid;
    wire [35:0] trace_data;

    picorv32 #(
        .ENABLE_COUNTERS(0),
        .ENABLE_COUNTERS64(0),
        .ENABLE_REGS_16_31(1),
        .ENABLE_REGS_DUALPORT(1),
        .TWO_STAGE_SHIFT(1),
        .BARREL_SHIFTER(0),
        .COMPRESSED_ISA(0),
        .CATCH_MISALIGN(1),
        .CATCH_ILLINSN(1),
        .ENABLE_PCPI(0),
        .ENABLE_MUL(0),
        .ENABLE_FAST_MUL(0),
        .ENABLE_DIV(0),
        .ENABLE_IRQ(1),
        .ENABLE_TRACE(0),
        .PROGADDR_RESET(32'h0000_0100),
        .PROGADDR_IRQ(32'h0000_0000),
        .STACKADDR(32'h0000_8000)
    ) cpu (
        .clk(clock50MHz),
        .resetn(cpuReset_n),
        .trap(trap),
        .mem_valid(cpu_mem_valid),
        .mem_instr(cpu_mem_instr),
        .mem_ready(cpu_mem_ready),
        .mem_addr(cpu_mem_addr),
        .mem_wdata(cpu_mem_wdata),
        .mem_wstrb(cpu_mem_wstrb),
        .mem_rdata(cpu_mem_rdata),
        .mem_la_read(mem_la_read),
        .mem_la_write(mem_la_write),
        .mem_la_addr(mem_la_addr),
        .mem_la_wdata(mem_la_wdata),
        .mem_la_wstrb(mem_la_wstrb),
        .pcpi_valid(pcpi_valid),
        .pcpi_insn(pcpi_insn),
        .pcpi_rs1(pcpi_rs1),
        .pcpi_rs2(pcpi_rs2),
        .pcpi_wr(1'b0),
        .pcpi_rd(32'd0),
        .pcpi_wait(1'b0),
        .pcpi_ready(1'b0),
        .irq(irqLines),
        .eoi(eoi),
        .trace_valid(trace_valid),
        .trace_data(trace_data)
    );

    // ---------------------------------------------------------------------
    // 地址路由
    // ---------------------------------------------------------------------
    wire flash_valid;
    wire flash_instr;
    wire flash_ready;
    wire [31:0] flash_addr;
    wire [31:0] flash_wdata;
    wire [3:0] flash_wstrb;
    wire [31:0] flash_rdata;

    wire sram_valid;
    wire sram_instr;
    wire sram_ready;
    wire [31:0] sram_addr;
    wire [31:0] sram_wdata;
    wire [3:0] sram_wstrb;
    wire [31:0] sram_rdata;

    wire mmio_valid;
    wire mmio_instr;
    wire mmio_ready;
    wire [31:0] mmio_addr;
    wire [31:0] mmio_wdata;
    wire [3:0] mmio_wstrb;
    wire [31:0] mmio_rdata;

    wire reserved_valid;
    wire reserved_instr;
    wire [31:0] reserved_addr;
    wire [31:0] reserved_wdata;
    wire [3:0] reserved_wstrb;
    wire unmapped_valid;

    busManager router (
        .mem_valid(cpu_mem_valid), .mem_instr(cpu_mem_instr),
        .mem_ready(cpu_mem_ready), .mem_addr(cpu_mem_addr),
        .mem_wdata(cpu_mem_wdata), .mem_wstrb(cpu_mem_wstrb),
        .mem_rdata(cpu_mem_rdata),

        .flash_valid(flash_valid), .flash_instr(flash_instr),
        .flash_ready(flash_ready), .flash_addr(flash_addr),
        .flash_wdata(flash_wdata), .flash_wstrb(flash_wstrb),
        .flash_rdata(flash_rdata),

        .sram_valid(sram_valid), .sram_instr(sram_instr),
        .sram_ready(sram_ready), .sram_addr(sram_addr),
        .sram_wdata(sram_wdata), .sram_wstrb(sram_wstrb),
        .sram_rdata(sram_rdata),

        .mmio_valid(mmio_valid), .mmio_instr(mmio_instr),
        .mmio_ready(mmio_ready), .mmio_addr(mmio_addr),
        .mmio_wdata(mmio_wdata), .mmio_wstrb(mmio_wstrb),
        .mmio_rdata(mmio_rdata),

        .reserved_valid(reserved_valid),
        .reserved_instr(reserved_instr),
        .reserved_ready(1'b1),
        .reserved_addr(reserved_addr),
        .reserved_wdata(reserved_wdata),
        .reserved_wstrb(reserved_wstrb),
        .reserved_rdata(32'd0),
        .unmapped_valid(unmapped_valid)
    );

    uartProgramMemory programMemory (
        .clk(clock50MHz), .reset_n(systemReset_n),
        .loader_we(loaderWrite),
        .loader_addr(loadedBytes[13:0]),
        .loader_wdata(rxByteData),
        .mem_valid(flash_valid), .mem_ready(flash_ready),
        .mem_addr(flash_addr), .mem_rdata(flash_rdata)
    );

    rv32RegisterRam dataMemory (
        .clk(clock50MHz), .reset_n(cpuReset_n),
        .mem_valid(sram_valid), .mem_ready(sram_ready),
        .mem_addr(sram_addr), .mem_wdata(sram_wdata),
        .mem_wstrb(sram_wstrb), .mem_rdata(sram_rdata)
    );

    wire uartIdle;
    UARTTX_MMIO uartMmio (
        .clock50MHz(clock50MHz), .reset_n(cpuReset_n),
        .mmio_valid(mmio_valid), .mmio_ready(mmio_ready),
        .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata),
        .mmio_wstrb(mmio_wstrb), .mmio_rdata(mmio_rdata),
        .uartTx(uartTx), .uartIdle(uartIdle)
    );

    // 这些信号第一版暂时不用，保留名字方便仿真观察，也避免把 SPI Flash
    // 或预留窗口误接进当前最小系统。
    wire unused_signals = &{1'b0, mem_la_read, mem_la_write, mem_la_addr,
                            mem_la_wdata, mem_la_wstrb, pcpi_valid, pcpi_insn,
                            pcpi_rs1, pcpi_rs2, eoi, trace_valid, trace_data,
                            flash_instr, flash_wdata, flash_wstrb, sram_instr,
                            mmio_instr, reserved_valid, reserved_instr,
                            reserved_addr, reserved_wdata, reserved_wstrb,
                            unmapped_valid, uartIdle,
                            unused_resetPressPulse,
                            unused_startDebounced_n,
                            unused_irqDebounced_n};
endmodule

`default_nettype wire
