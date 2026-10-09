`timescale 1ns / 1ps
`default_nettype none

// MMIO 控制的纯色矩形 GPU，目标是逻辑 PSRAM BACK 帧缓冲。
// CPU 时钟域锁存一条命令，80 MHz PHY 时钟域完成裁剪、地址生成和突发拆分。
// GPU 没有像素 FIFO：颜色在整个作业中保持不变，直接重复送给每个写 beat。
module rectangleGpu #(
    parameter integer FRAME_WIDTH = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter integer MAX_BURST_WORDS = 64
) (
    input  wire        clk,
    input  wire        phy_clk,
    input  wire        reset_n,

    input  wire        mmio_valid,
    output reg         mmio_ready,
    input  wire [11:0] mmio_addr,
    input  wire [31:0] mmio_wdata,
    input  wire [ 3:0] mmio_wstrb,
    output reg  [31:0] mmio_rdata,

    output reg         gpu_job_busy,
    output reg         gpu_cmd_valid,
    input  wire        gpu_cmd_ready,
    output wire        gpu_cmd_wr,
    output reg  [21:0] gpu_cmd_addr,
    output reg  [ 6:0] gpu_cmd_words,
    output wire [15:0] gpu_w_data,
    output wire [ 1:0] gpu_w_mask,
    input  wire        gpu_w_take,
    input  wire        gpu_done
);
    localparam [2:0] G_IDLE     = 3'd0,
                     G_CAPTURE  = 3'd1,
                     G_COMPARE  = 3'd2,
                     G_CLIP     = 3'd3,
                     G_VALIDATE = 3'd4,
                     G_PREP     = 3'd5,
                     G_ISSUE    = 3'd6,
                     G_WAIT     = 3'd7;
    localparam integer STRIDE_BYTES = FRAME_WIDTH * 2;
    localparam [15:0] FRAME_WIDTH_U16 = FRAME_WIDTH;
    localparam [15:0] FRAME_HEIGHT_U16 = FRAME_HEIGHT;
    localparam [9:0] MAX_BURST_WORDS_U10 = MAX_BURST_WORDS;
    localparam [21:0] STRIDE_BYTES_U22 = STRIDE_BYTES;

    reg [15:0] xReg, yReg, widthReg, heightReg, colorReg;
    reg [15:0] jobX, jobY, jobWidth, jobHeight, jobColor;
    reg        requestToggle;
    reg        cpuBusy;
    reg [15:0] completionCount;
    reg        doneMeta, doneSync, doneSeen;

    // START 时把参数复制到 job*，作业结束前保持不变。requestToggle 经过两级
    // 同步进入 PHY 域，因此 job* 可以作为随请求一起跨域的稳定数据包。
    always @(posedge clk) begin
        mmio_ready <= mmio_valid;
        doneMeta <= doneTogglePhy;
        doneSync <= doneMeta;

        if (!reset_n) begin
            mmio_ready     <= 1'b0;
            xReg           <= 16'd0;
            yReg           <= 16'd0;
            widthReg       <= 16'd0;
            heightReg      <= 16'd0;
            colorReg       <= 16'd0;
            jobX           <= 16'd0;
            jobY           <= 16'd0;
            jobWidth       <= 16'd0;
            jobHeight      <= 16'd0;
            jobColor       <= 16'd0;
            requestToggle  <= 1'b0;
            cpuBusy        <= 1'b0;
            completionCount <= 16'd0;
            doneMeta       <= 1'b0;
            doneSync       <= 1'b0;
            doneSeen       <= 1'b0;
        end else begin
            if (doneSync != doneSeen) begin
                doneSeen <= doneSync;
                cpuBusy <= 1'b0;
                completionCount <= completionCount + 16'd1;
            end

            // GPU 没有命令队列。busy 时总线仍正常应答，但参数和 START 写入被丢弃；
            // 软件必须等 idle 后再完整写下一组参数。
            if (mmio_valid && !mmio_ready && |mmio_wstrb && !cpuBusy) begin
                case (mmio_addr[5:2])
                    4'd2: if (mmio_wstrb[0] || mmio_wstrb[1])
                              xReg <= mmio_wdata[15:0];
                    4'd3: if (mmio_wstrb[0] || mmio_wstrb[1])
                              yReg <= mmio_wdata[15:0];
                    4'd4: if (mmio_wstrb[0] || mmio_wstrb[1])
                              widthReg <= mmio_wdata[15:0];
                    4'd5: if (mmio_wstrb[0] || mmio_wstrb[1])
                              heightReg <= mmio_wdata[15:0];
                    4'd6: if (mmio_wstrb[0] || mmio_wstrb[1])
                              colorReg <= mmio_wdata[15:0];
                    4'd7: if (mmio_wstrb[0] && mmio_wdata[0]) begin
                        jobX <= xReg;
                        jobY <= yReg;
                        jobWidth <= widthReg;
                        jobHeight <= heightReg;
                        jobColor <= colorReg;
                        requestToggle <= ~requestToggle;
                        cpuBusy <= 1'b1;
                    end
                    default: begin end
                endcase
            end
        end
    end

    always @* begin
        case (mmio_addr[5:2])
            4'd0: mmio_rdata = 32'h4750_5531; // "GPU1"
            4'd1: mmio_rdata = {completionCount, 15'd0, cpuBusy};
            4'd2: mmio_rdata = {16'd0, xReg};
            4'd3: mmio_rdata = {16'd0, yReg};
            4'd4: mmio_rdata = {16'd0, widthReg};
            4'd5: mmio_rdata = {16'd0, heightReg};
            4'd6: mmio_rdata = {16'd0, colorReg};
            4'd8: mmio_rdata = {FRAME_HEIGHT[15:0], FRAME_WIDTH[15:0]};
            default: mmio_rdata = 32'd0;
        endcase
    end

    reg [2:0] gpuState;
    reg [2:0] phyResetPipe = 3'b000;
    reg reqMetaPhy, reqSyncPhy, reqSeenPhy;
    reg [15:0] jobXMetaPhy, jobXSyncPhy;
    reg [15:0] jobYMetaPhy, jobYSyncPhy;
    reg [15:0] jobWidthMetaPhy, jobWidthSyncPhy;
    reg [15:0] jobHeightMetaPhy, jobHeightSyncPhy;
    reg [15:0] jobColorMetaPhy, jobColorSyncPhy;
    reg doneTogglePhy;
    reg [21:0] rowStart;
    reg [21:0] currentAddr;
    reg [9:0] rowWords;
    reg [9:0] wordsLeft;
    reg [8:0] rowsLeft;
    reg [15:0] colorPhy;
    reg [15:0] xPhy, yPhy, widthPhy, heightPhy;
    reg [9:0] xAvailable;
    reg [8:0] yAvailable;
    reg widthNeedsClip, heightNeedsClip;
    reg [9:0] remainingWords;
    reg [21:0] nextAddr;
    wire [21:0] jobXExt = {6'd0, xPhy};
    wire [21:0] jobYExt = {6'd0, yPhy};
    // 一行 640 个 RGB565 像素 = 1280 字节 = 1024 + 256，用移位加法算行地址。
    wire [21:0] jobStartAddr = (jobYExt << 10) + (jobYExt << 8) +
                                (jobXExt << 1);
    // PSRAM 已配置为 128 字节回绕。矩形可以从任意 X 开始，因此第一笔突发可能
    // 不满 64 像素；先截到下一个 128 字节边界，后续再发完整 64 像素突发。
    wire [6:0] wordsTo128Boundary =
        7'd64 - {1'b0, currentAddr[6:1]};
    wire [6:0] wordsLimitedByLength =
        wordsLeft > MAX_BURST_WORDS_U10 ?
        MAX_BURST_WORDS_U10[6:0] : wordsLeft[6:0];
    wire [6:0] nextBurstWords =
        wordsLimitedByLength > wordsTo128Boundary ?
        wordsTo128Boundary : wordsLimitedByLength;

    assign gpu_cmd_wr = 1'b1;
    // 纯色填充不需要 FIFO：每个写 beat 都直接重复输出同一个 colorPhy。
    assign gpu_w_data = colorPhy;
    assign gpu_w_mask = 2'b00;

    always @(posedge phy_clk) begin
        phyResetPipe <= {phyResetPipe[1:0], reset_n};
        reqMetaPhy <= requestToggle;
        reqSyncPhy <= reqMetaPhy;
        jobXMetaPhy <= jobX;
        jobXSyncPhy <= jobXMetaPhy;
        jobYMetaPhy <= jobY;
        jobYSyncPhy <= jobYMetaPhy;
        jobWidthMetaPhy <= jobWidth;
        jobWidthSyncPhy <= jobWidthMetaPhy;
        jobHeightMetaPhy <= jobHeight;
        jobHeightSyncPhy <= jobHeightMetaPhy;
        jobColorMetaPhy <= jobColor;
        jobColorSyncPhy <= jobColorMetaPhy;

        if (!phyResetPipe[2]) begin
            reqMetaPhy     <= 1'b0;
            reqSyncPhy     <= 1'b0;
            reqSeenPhy     <= 1'b0;
            jobXMetaPhy    <= 16'd0;
            jobXSyncPhy    <= 16'd0;
            jobYMetaPhy    <= 16'd0;
            jobYSyncPhy    <= 16'd0;
            jobWidthMetaPhy <= 16'd0;
            jobWidthSyncPhy <= 16'd0;
            jobHeightMetaPhy <= 16'd0;
            jobHeightSyncPhy <= 16'd0;
            jobColorMetaPhy <= 16'd0;
            jobColorSyncPhy <= 16'd0;
            doneTogglePhy  <= 1'b0;
            gpuState       <= G_IDLE;
            gpu_job_busy   <= 1'b0;
            gpu_cmd_valid  <= 1'b0;
            gpu_cmd_addr   <= 22'd0;
            gpu_cmd_words  <= 7'd1;
            rowStart       <= 22'd0;
            currentAddr    <= 22'd0;
            rowWords       <= 10'd0;
            wordsLeft      <= 10'd0;
            rowsLeft       <= 9'd0;
            colorPhy       <= 16'd0;
            xPhy           <= 16'd0;
            yPhy           <= 16'd0;
            widthPhy       <= 16'd0;
            heightPhy      <= 16'd0;
            xAvailable     <= 10'd0;
            yAvailable     <= 9'd0;
            widthNeedsClip <= 1'b0;
            heightNeedsClip <= 1'b0;
            remainingWords <= 10'd0;
            nextAddr       <= 22'd0;
        end else begin
            case (gpuState)
                G_IDLE: begin
                    gpu_cmd_valid <= 1'b0;
                    // requestToggle 翻转表示 CPU 提交了一条新命令。
                    if (reqSyncPhy != reqSeenPhy) begin
                        reqSeenPhy <= reqSyncPhy;
                        xPhy <= jobXSyncPhy;
                        yPhy <= jobYSyncPhy;
                        widthPhy <= jobWidthSyncPhy;
                        heightPhy <= jobHeightSyncPhy;
                        colorPhy <= jobColorSyncPhy;
                        gpu_job_busy <= 1'b1;
                        gpuState <= G_CAPTURE;
                    end
                end

                G_CAPTURE: begin
                    // 计算首像素字节地址，以及 X/Y 方向还能容纳多少像素。
                    rowStart    <= jobStartAddr;
                    currentAddr <= jobStartAddr;
                    xAvailable <= xPhy >= FRAME_WIDTH_U16 ? 10'd0 :
                                  FRAME_WIDTH_U16[9:0] - xPhy[9:0];
                    yAvailable <= yPhy >= FRAME_HEIGHT_U16 ? 9'd0 :
                                  FRAME_HEIGHT_U16[8:0] - yPhy[8:0];
                    gpuState <= G_COMPARE;
                end

                G_COMPARE: begin
                    // 比较结果先寄存一拍，缩短 80 MHz 组合路径。
                    widthNeedsClip <= widthPhy > {6'd0, xAvailable};
                    heightNeedsClip <= heightPhy > {7'd0, yAvailable};
                    gpuState <= G_CLIP;
                end

                G_CLIP: begin
                    // 得到实际绘制的每行像素数和总行数。
                    rowWords <= widthNeedsClip ? xAvailable : widthPhy[9:0];
                    rowsLeft <= heightNeedsClip ? yAvailable : heightPhy[8:0];
                    gpuState    <= G_VALIDATE;
                end

                G_VALIDATE: begin
                    // 空矩形也算正常完成，但不会发任何 PSRAM 事务。
                    if (rowWords == 10'd0 || rowsLeft == 9'd0) begin
                        doneTogglePhy <= ~doneTogglePhy;
                        gpu_job_busy <= 1'b0;
                        gpuState <= G_IDLE;
                    end else begin
                        wordsLeft <= rowWords;
                        gpuState <= G_PREP;
                    end
                end

                G_PREP: begin
                    // 生成下一笔 1..64 像素、且不跨 128 字节边界的写突发。
                    gpu_cmd_addr  <= currentAddr;
                    gpu_cmd_words <= nextBurstWords;
                    gpu_cmd_valid <= 1'b1;
                    gpuState      <= G_ISSUE;
                end

                G_ISSUE: begin
                    // switcher 接收命令后才推进剩余长度和下一地址。
                    if (gpu_cmd_valid && gpu_cmd_ready) begin
                        remainingWords <= wordsLeft -
                                          {3'd0, gpu_cmd_words};
                        nextAddr <= currentAddr +
                                    {14'd0, gpu_cmd_words, 1'b0};
                        gpu_cmd_valid <= 1'b0;
                        gpuState <= G_WAIT;
                    end
                end

                G_WAIT: begin
                    // 一笔物理突发真正结束后，继续本行、下一行或结束作业。
                    if (gpu_done) begin
                        if (remainingWords != 10'd0) begin
                            currentAddr <= nextAddr;
                            wordsLeft <= remainingWords;
                            gpuState <= G_PREP;
                        end else if (rowsLeft > 9'd1) begin
                            rowStart <= rowStart + STRIDE_BYTES_U22;
                            currentAddr <= rowStart + STRIDE_BYTES_U22;
                            wordsLeft <= rowWords;
                            rowsLeft <= rowsLeft - 9'd1;
                            gpuState <= G_PREP;
                        end else begin
                            doneTogglePhy <= ~doneTogglePhy;
                            gpu_job_busy <= 1'b0;
                            gpuState <= G_IDLE;
                        end
                    end
                end

                default: begin
                    gpu_job_busy <= 1'b0;
                    gpuState <= G_IDLE;
                end
            endcase
        end
    end

    // 写数据是常量，不需要用 w_take 推进 FIFO/数据指针。
    wire unusedWtake = gpu_w_take;
endmodule

`default_nettype wire
