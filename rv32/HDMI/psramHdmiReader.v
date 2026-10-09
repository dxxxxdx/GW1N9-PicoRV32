`timescale 1ns / 1ps
`default_nettype none

// 从 FRONT die 读取 RGB565 像素的 DMA，以及一块 BSRAM 实现的异步像素 FIFO。
// 写侧运行在 80 MHz PSRAM 域，读侧运行在 25.33 MHz HDMI 像素域。
module psramHdmiReader #(
    parameter integer H_ACTIVE = 640,
    parameter integer V_ACTIVE = 480,
    parameter integer BURST_WORDS = 64,
    parameter integer FIFO_DEPTH = 512,
    parameter integer FIFO_ABITS = 9
) (
    input  wire        phy_clk,
    input  wire        pixel_clk,
    input  wire        reset_n,

    output reg         cmd_valid,
    input  wire        cmd_ready,
    output reg  [21:0] cmd_addr,
    output reg  [ 6:0] cmd_words,
    input  wire [15:0] r_data,
    input  wire        r_valid,
    input  wire        r_last,
    input  wire        cmd_done,

    input  wire        frame_swap_request,
    output reg         frame_done,

    input  wire        pixel_take,
    output wire [15:0] pixel_data,
    output wire        pixel_valid
);
    localparam integer FRAME_WORDS = H_ACTIVE * V_ACTIVE;
    localparam integer FREE_MARGIN = 8;

    // HDMI enable 来自 CPU 时钟域。分别同步到 FIFO 两侧后再释放本地逻辑，避免
    // 把 MMIO 位直接当成跨全芯片的异步复位信号。
    reg [2:0] phyRunPipe = 3'b000;
    reg [2:0] pixelRunPipe = 3'b000;
    always @(posedge phy_clk)
        phyRunPipe <= {phyRunPipe[1:0], reset_n};
    always @(posedge pixel_clk)
        pixelRunPipe <= {pixelRunPipe[1:0], reset_n};
    wire phyRun_n = phyRunPipe[2];
    wire pixelRun_n = pixelRunPipe[2];

    reg activeBurst;
    reg lastBurst;
    reg waitForSwap;
    reg [21:0] nextAddr;
    // 已“发出命令”的像素数，不是已经进入 FIFO 的像素数。
    reg [18:0] wordsScheduled;
    wire [19:0] wordsRemaining = FRAME_WORDS - wordsScheduled;
    wire [6:0] nextWords = wordsRemaining < BURST_WORDS ?
                           wordsRemaining[6:0] : BURST_WORDS[6:0];

    wire [FIFO_ABITS-1:0] fifoFree;
    wire [FIFO_ABITS-1:0] fifoAvail;
    // PSRAM 读数据不能反压，r_valid 来一个就必须写进 FIFO。
    wire fifoWrite = r_valid;
    // 发命令前预留完整 64 像素突发，再留 8 格跨域计数余量。
    wire canLaunch = fifoFree >= BURST_WORDS + FREE_MARGIN;

    psramHdmiAsyncFifo #(
        .WIDTH(16), .DEPTH(FIFO_DEPTH), .ABITS(FIFO_ABITS)
    ) pixelFifo (
        .write_clk(phy_clk), .write_reset_n(phyRun_n),
        .write_enable(fifoWrite), .write_data(r_data), .write_free(fifoFree),
        .read_clk(pixel_clk), .read_reset_n(pixelRun_n),
        .read_enable(pixel_take), .read_data(pixel_data),
        .read_available(fifoAvail)
    );
    // 像素域只看本地可读计数；非零才允许 HDMI 取走一个像素。
    assign pixel_valid = fifoAvail != {FIFO_ABITS{1'b0}};

    always @(posedge phy_clk) begin
        frame_done <= 1'b0;
        if (!phyRun_n) begin
            cmd_valid <= 1'b0;
            cmd_addr <= 22'd0;
            cmd_words <= BURST_WORDS[6:0];
            activeBurst <= 1'b0;
            lastBurst <= 1'b0;
            waitForSwap <= 1'b0;
            nextAddr <= 22'd0;
            wordsScheduled <= 19'd0;
        end else begin
            if (cmd_valid && cmd_ready) begin
                // switcher 接收突发后，提前推进本帧的调度地址和像素数。
                cmd_valid <= 1'b0;
                activeBurst <= 1'b1;
                lastBurst <= wordsScheduled + cmd_words >= FRAME_WORDS;
                wordsScheduled <= wordsScheduled + cmd_words;
                nextAddr <= nextAddr + {cmd_words, 1'b0};
            end

            if (activeBurst && cmd_done) begin
                activeBurst <= 1'b0;
                if (lastBurst) begin
                    // 最后一笔 FRONT 读突发结束就是本模块的帧边界。
                    frame_done <= 1'b1;
                    wordsScheduled <= 19'd0;
                    nextAddr <= 22'd0;
                    if (frame_swap_request)
                        // 有交换请求时先停发下一帧，等 switcher 完成映射翻转。
                        waitForSwap <= 1'b1;
                end
            end

            if (waitForSwap && !frame_swap_request)
                waitForSwap <= 1'b0;

            if (!cmd_valid && !activeBurst && !waitForSwap && canLaunch) begin
                // 同一时刻只保留一笔在途读突发，FIFO 空间够才启动。
                cmd_valid <= 1'b1;
                cmd_addr <= nextAddr;
                cmd_words <= nextWords;
            end
        end
    end

    wire unusedLast = r_last;
endmodule

module psramHdmiAsyncFifo #(
    parameter integer WIDTH = 16,
    parameter integer DEPTH = 512,
    parameter integer ABITS = 9
) (
    input  wire             write_clk,
    input  wire             write_reset_n,
    input  wire             write_enable,
    input  wire [WIDTH-1:0] write_data,
    output reg  [ABITS-1:0] write_free,
    input  wire             read_clk,
    input  wire             read_reset_n,
    input  wire             read_enable,
    output wire [WIDTH-1:0] read_data,
    output reg  [ABITS-1:0] read_available
);
    // 环形 FIFO 故意空出一个槽位区分满和空，因此 512 深度实际最多存 511 项。
    reg [ABITS-1:0] writePtr;
    reg [ABITS-1:0] writeGray;
    reg [ABITS-1:0] readPtr;
    reg [ABITS-1:0] readGray;
    // 跨时钟域只传 Gray 指针；相邻计数只变化一位，再经过两级同步器。
    reg [ABITS-1:0] readGrayMeta, readGraySync;
    reg [ABITS-1:0] writeGrayMeta, writeGraySync;

    function [ABITS-1:0] binToGray;
        input [ABITS-1:0] value;
        begin binToGray = (value >> 1) ^ value; end
    endfunction

    function [ABITS-1:0] grayToBin;
        input [ABITS-1:0] value;
        integer i;
        begin
            grayToBin[ABITS-1] = value[ABITS-1];
            for (i = ABITS-2; i >= 0; i = i - 1)
                grayToBin[i] = grayToBin[i+1] ^ value[i];
        end
    endfunction

    wire [ABITS-1:0] readPtrWrite = grayToBin(readGraySync);
    wire [ABITS-1:0] writePtrRead = grayToBin(writeGraySync);
    wire [ABITS-1:0] writePtrNext = writePtr +
                                      (write_enable ? 1'b1 : 1'b0);
    wire [ABITS-1:0] readPtrNext = readPtr +
                                     (read_enable ? 1'b1 : 1'b0);
    // SDPB 读口有一拍延迟，地址提前指向“本拍取走后的下一项”以持续预取。
    wire [ABITS-1:0] ramReadPtr = readPtrNext;

    // 高云专用 SDPB 原语：显式占用一块 BSRAM，配置成 512 x 16，避免综合
    // 成 LUT/FF RAM。移植时换成目标器件的双时钟块 RAM 或异步 FIFO 原语，
    // 并保持写/读时钟分离、16 位数据宽度和同步读出一拍延迟；外面的 Gray
    // 指针与跨时钟同步逻辑本身不依赖高云器件，可以继续沿用。
    // 16 位模式下 ADA[1:0] 是两个字节写使能，ADA/ADB[13:4] 是字地址。
    wire [31:0] ramReadData;
    wire [13:0] ramWriteAddress =
        {{(10-ABITS){1'b0}}, writePtr, 2'b00, 2'b11};
    wire [13:0] ramReadAddress =
        {{(10-ABITS){1'b0}}, ramReadPtr, 4'b0000};
    SDPB fifoRam (
        .DO(ramReadData), .DI({16'd0, write_data}),
        .BLKSELA(3'b000), .BLKSELB(3'b000),
        .ADA(ramWriteAddress), .ADB(ramReadAddress),
        .CLKA(write_clk), .CLKB(read_clk),
        .CEA(write_enable && write_reset_n), .CEB(1'b1), .OCE(1'b1),
        .RESETA(1'b0), .RESETB(!read_reset_n)
    );
    defparam fifoRam.READ_MODE = 1'b0;
    defparam fifoRam.BIT_WIDTH_0 = 16;
    defparam fifoRam.BIT_WIDTH_1 = 16;
    defparam fifoRam.BLK_SEL_0 = 3'b000;
    defparam fifoRam.BLK_SEL_1 = 3'b000;
    defparam fifoRam.RESET_MODE = "SYNC";
    assign read_data = ramReadData[15:0];

    always @(posedge write_clk) begin
        if (!write_reset_n) begin
            writePtr <= {ABITS{1'b0}};
            writeGray <= {ABITS{1'b0}};
            readGrayMeta <= {ABITS{1'b0}};
            readGraySync <= {ABITS{1'b0}};
            write_free <= DEPTH - 1;
        end else begin
            readGrayMeta <= readGray;
            readGraySync <= readGrayMeta;
            // 用本拍写入后的 writePtrNext 计算剩余空间，避免队满边界慢一拍。
            write_free <= readPtrWrite - writePtrNext - 1'b1;
            if (write_enable) begin
                writePtr <= writePtrNext;
                writeGray <= binToGray(writePtrNext);
            end
        end
    end

    always @(posedge read_clk) begin
        if (!read_reset_n) begin
            readPtr <= {ABITS{1'b0}};
            readGray <= {ABITS{1'b0}};
            writeGrayMeta <= {ABITS{1'b0}};
            writeGraySync <= {ABITS{1'b0}};
            read_available <= {ABITS{1'b0}};
        end else begin
            writeGrayMeta <= writeGray;
            writeGraySync <= writeGrayMeta;
            // 用本拍读取后的 readPtrNext 计算剩余数据，避免队空时再多读一格旧数据。
            read_available <= writePtrRead - readPtrNext;
            if (read_enable) begin
                readPtr <= readPtrNext;
                readGray <= binToGray(readPtrNext);
            end
        end
    end
endmodule

`default_nettype wire
