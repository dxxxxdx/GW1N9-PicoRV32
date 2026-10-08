`timescale 1ns / 1ps
`default_nettype none

// 最小 RV32 系统 + GW1NR-9C 内嵌 PSRAM：
//   - UART RX 裸字节流装载 16 KiB 程序 reg 数组；
//   - start 按键确认装载完成并释放 PicoRV32；
//   - 16 KiB 数据 RAM 使用普通 reg 数组；
//   - UART TX 位于 MMIO 0x0100_0000 的前三个字节；
//   - irq_n 按键经消抖后产生一个时钟周期的脉冲，接到 PicoRV32 的 irq bit 3
//     （hostutil 里的 IRQ_CH0），固件侧由 IRQ_Ch0_Handler() 处理；
//   - 50MHz 晶振经 rPLL 产生 CPU 40MHz、PSRAM PHY 80MHz；
//   - PSRAM 4 MiB 逻辑后台窗口 0x0200_0000~0x023f_ffff；
//   - 两个物理 die 由 front/back switcher 管理，MMIO 在帧边界请求交换；
//   - PSRAM 诊断窗口 0x0300_0000，提供初始化、相位和交换控制；
//   - 不实例化 SPI Flash。
//
// reset_n、start、irq_n 都是低有效物理按键：默认上拉为 1，按下接地为 0。
// 三者都经过消抖，
// start 应在最后一个 UART 字节发送完成后再按下。
module rv32top #(
    // 系统时钟频率。PicoRV32 走 PLL 时钟时 Fmax 只有 ~46MHz（见 gowin_rpll.v
    // 里的实测对比），所以系统保持 40MHz；PSRAM PHY 独立跑 80MHz。
    // 改这个值时 BUTTON_FILTER_CYCLES 要一起改。
    parameter integer SYS_CLK_HZ = 40_000_000,
    parameter integer PSRAM_CLK_HZ = 80_000_000,
    // 50 ms 消抖窗口 = SYS_CLK_HZ / 20；仿真可覆盖成较小值。
    parameter [21:0] BUTTON_FILTER_CYCLES = 22'd2_000_000
) (
    input  wire        clock50MHz,      // 50 MHz 晶振

    // 内嵌 PSRAM 的 magic 端口：名字一个字都不能改，也不要写进 cst
    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    output wire [1:0]  O_psram_cs_n,
    output wire [1:0]  O_psram_reset_n,
    inout  wire [1:0]  IO_psram_rwds,
    inout  wire [15:0] IO_psram_dq,

    output wire        tmds_clk_n,
    output wire        tmds_clk_p,
    output wire [2:0]  tmds_d_n,
    output wire [2:0]  tmds_d_p,

    input  wire        reset_n,
    input  wire        start,
    input  wire        irq_n,
    input  wire        uartRx,
    output wire        uartTx,
    output wire        trap
);
    // ---------------------------------------------------------------- 时钟
    // 50MHz -> 80MHz PHY + 80MHz动态相移 PSRAM CK + 40MHz CPU
    wire       sysClk;
    wire       psramClk;
    wire       psramClkP;
    wire       pllLock;
    wire [3:0] psramCkPhase;   // 上电为5，固件可训练后驱动rPLL动态相位

    Gowin_rPLL sysPll (
        .clkout  (psramClk),
        .clkoutp (psramClkP),
        .clkoutd (sysClk),
        .lock    (pllLock),
        .clkin   (clock50MHz),
        .psda    (psramCkPhase)
    );

    // Tang Nano reference HDMI mode: 126.6667 MHz serializer clock and
    // 25.3333 MHz pixel clock for 640x480 at approximately 60.3 Hz.
    wire hdmiPixelClk;
    wire hdmiSerialClk;
    wire hdmiClockLock;
    hdmiClock hdmiClocks (
        .clk40(sysClk), .reset_n(systemReset_n),
        .pixel_clk(hdmiPixelClk), .serial_clk(hdmiSerialClk),
        .locked(hdmiClockLock)
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
        .clk(sysClk),
        .reset_n(pllLock),          // PLL 未锁定就保持复位
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
        .clk(sysClk),
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
        .clk(sysClk),
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

    UARTRX #(
        .CLK_HZ(SYS_CLK_HZ)
    ) receiver (
        .clk(sysClk),
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

    always @(posedge sysClk) begin
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
        .TWO_CYCLE_COMPARE(1),
        .TWO_CYCLE_ALU(1),
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
        .clk(sysClk),
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

    wire psram_valid;
    wire psram_instr;
    wire psram_ready;
    wire [31:0] psram_addr;
    wire [31:0] psram_wdata;
    wire [3:0] psram_wstrb;
    wire [31:0] psram_rdata;

    wire psramcfg_valid;
    wire psramcfg_instr;
    wire psramcfg_ready;
    wire [31:0] psramcfg_addr;
    wire [31:0] psramcfg_wdata;
    wire [3:0] psramcfg_wstrb;
    wire [31:0] psramcfg_rdata;

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

        .psram_valid(psram_valid), .psram_instr(psram_instr),
        .psram_ready(psram_ready), .psram_addr(psram_addr),
        .psram_wdata(psram_wdata), .psram_wstrb(psram_wstrb),
        .psram_rdata(psram_rdata),

        .psramcfg_valid(psramcfg_valid), .psramcfg_instr(psramcfg_instr),
        .psramcfg_ready(psramcfg_ready), .psramcfg_addr(psramcfg_addr),
        .psramcfg_wdata(psramcfg_wdata), .psramcfg_wstrb(psramcfg_wstrb),
        .psramcfg_rdata(psramcfg_rdata),

        .unmapped_valid(unmapped_valid)
    );

    uartProgramMemory programMemory (
        .clk(sysClk), .reset_n(systemReset_n),
        .loader_we(loaderWrite),
        .loader_addr(loadedBytes[13:0]),
        .loader_wdata(rxByteData),
        .mem_valid(flash_valid), .mem_ready(flash_ready),
        .mem_addr(flash_addr), .mem_rdata(flash_rdata)
    );

    rv32RegisterRam dataMemory (
        .clk(sysClk), .reset_n(cpuReset_n),
        .mem_valid(sram_valid), .mem_ready(sram_ready),
        .mem_addr(sram_addr), .mem_wdata(sram_wdata),
        .mem_wstrb(sram_wstrb), .mem_rdata(sram_rdata)
    );

    wire uartIdle;
    UARTTX_MMIO #(
        .CLK_HZ(SYS_CLK_HZ)
    ) uartMmio (
        .clk(sysClk), .reset_n(cpuReset_n),
        .mmio_valid(mmio_valid), .mmio_ready(mmio_ready),
        .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata),
        .mmio_wstrb(mmio_wstrb), .mmio_rdata(mmio_rdata),
        .uartTx(uartTx), .uartIdle(uartIdle)
    );

    // ---------------------------------------------------------------------
    // 内嵌 PSRAM
    // ---------------------------------------------------------------------
    // GPU 端口暂时保留；HDMI DMA 独占逻辑 front die。
    wire gpuPsramReady;
    wire gpuPsramWtake;
    wire [15:0] gpuPsramRdata;
    wire gpuPsramRvalid;
    wire gpuPsramRlast;
    wire gpuPsramDone;
    wire hdmiPsramReady;
    wire [15:0] hdmiPsramRdata;
    wire hdmiPsramRvalid;
    wire hdmiPsramRlast;
    wire hdmiPsramDone;
    wire frameSwapRequest;
    wire hdmiEnable;
    wire hdmiFrameDone;
    wire hdmiCmdValid;
    wire [21:0] hdmiCmdAddr;
    wire [6:0] hdmiCmdWords;
    wire [15:0] hdmiPixelData;
    wire hdmiPixelValid;
    wire hdmiPixelTake;
    wire hdmiUnderflow;

    // Each HDMI block synchronizes this request into its own clock domain.
    wire hdmiRunRequest = cpuReset_n && hdmiClockLock && hdmiEnable;

    psramHdmiReader hdmiReader (
        .phy_clk(psramClk), .pixel_clk(hdmiPixelClk),
        .reset_n(hdmiRunRequest),
        .cmd_valid(hdmiCmdValid), .cmd_ready(hdmiPsramReady),
        .cmd_addr(hdmiCmdAddr), .cmd_words(hdmiCmdWords),
        .r_data(hdmiPsramRdata), .r_valid(hdmiPsramRvalid),
        .r_last(hdmiPsramRlast), .cmd_done(hdmiPsramDone),
        .frame_swap_request(frameSwapRequest), .frame_done(hdmiFrameDone),
        .pixel_take(hdmiPixelTake), .pixel_data(hdmiPixelData),
        .pixel_valid(hdmiPixelValid)
    );

    hdmiTx hdmiOutput (
        .pixel_clk(hdmiPixelClk), .serial_clk(hdmiSerialClk),
        .reset_n(hdmiRunRequest),
        .pixel_data(hdmiPixelData), .pixel_valid(hdmiPixelValid),
        .pixel_take(hdmiPixelTake), .underflow(hdmiUnderflow),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p),
        .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    psramController #(
        .PHY_FREQ_HZ(PSRAM_CLK_HZ),
        .LATENCY(3)
    ) psram (
        .clk(sysClk), .phy_clk(psramClk), .clk_p(psramClkP),
        .reset_n(cpuReset_n),

        .mem_valid(psram_valid), .mem_ready(psram_ready),
        .mem_addr(psram_addr), .mem_wdata(psram_wdata),
        .mem_wstrb(psram_wstrb), .mem_rdata(psram_rdata),

        .cfg_valid(psramcfg_valid), .cfg_ready(psramcfg_ready),
        .cfg_addr(psramcfg_addr[11:0]), .cfg_wdata(psramcfg_wdata),
        .cfg_wstrb(psramcfg_wstrb), .cfg_rdata(psramcfg_rdata),

        .gpu_cmd_valid(1'b0), .gpu_cmd_ready(gpuPsramReady),
        .gpu_cmd_wr(1'b0), .gpu_cmd_addr(22'd0), .gpu_cmd_words(7'd1),
        .gpu_w_data(16'd0), .gpu_w_mask(2'b11),
        .gpu_w_take(gpuPsramWtake), .gpu_r_data(gpuPsramRdata),
        .gpu_r_valid(gpuPsramRvalid), .gpu_r_last(gpuPsramRlast),
        .gpu_done(gpuPsramDone),

        .hdmi_cmd_valid(hdmiCmdValid), .hdmi_cmd_ready(hdmiPsramReady),
        .hdmi_cmd_addr(hdmiCmdAddr), .hdmi_cmd_words(hdmiCmdWords),
        .hdmi_r_data(hdmiPsramRdata), .hdmi_r_valid(hdmiPsramRvalid),
        .hdmi_r_last(hdmiPsramRlast), .hdmi_done(hdmiPsramDone),
        .hdmi_frame_done(hdmiFrameDone),
        .frame_swap_request(frameSwapRequest),
        .hdmi_enable(hdmiEnable),

        .ckPhase(psramCkPhase),

        .O_psram_ck(O_psram_ck), .O_psram_ck_n(O_psram_ck_n),
        .O_psram_cs_n(O_psram_cs_n), .O_psram_reset_n(O_psram_reset_n),
        .IO_psram_rwds(IO_psram_rwds), .IO_psram_dq(IO_psram_dq)
    );

    // 这些信号第一版暂时不用，保留名字方便仿真观察。
    wire unused_signals = &{1'b0, mem_la_read, mem_la_write, mem_la_addr,
                            mem_la_wdata, mem_la_wstrb, pcpi_valid, pcpi_insn,
                            pcpi_rs1, pcpi_rs2, eoi, trace_valid, trace_data,
                            flash_instr, flash_wdata, flash_wstrb, sram_instr,
                            mmio_instr, psram_instr, psramcfg_instr,
                            unmapped_valid, uartIdle,
                            unused_resetPressPulse,
                            unused_startDebounced_n,
                            unused_irqDebounced_n, gpuPsramReady,
                            gpuPsramWtake, gpuPsramRdata, gpuPsramRvalid,
                            gpuPsramRlast, gpuPsramDone, hdmiPsramReady,
                            hdmiPsramRdata, hdmiPsramRvalid, hdmiPsramRlast,
                            hdmiPsramDone, hdmiUnderflow};
endmodule

`default_nettype wire
