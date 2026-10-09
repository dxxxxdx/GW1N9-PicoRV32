`timescale 1ns / 1ps
`default_nettype none

// 640x480 RGB565 DVI/HDMI 发送器。扫描顺序沿用 Tang Nano SVO 例程：
// 前肩、同步、后肩、有效画面。
module hdmiTx #(
    parameter integer H_ACTIVE = 640,
    parameter integer H_FRONT  = 16,
    parameter integer H_SYNC   = 96,
    parameter integer H_BACK   = 48,
    parameter integer V_ACTIVE = 480,
    parameter integer V_FRONT  = 10,
    parameter integer V_SYNC   = 2,
    parameter integer V_BACK   = 33
) (
    input  wire        pixel_clk,
    input  wire        serial_clk,
    input  wire        reset_n,
    input  wire [15:0] pixel_data,
    input  wire        pixel_valid,
    output wire        pixel_take,
    output reg         underflow,
    output wire        tmds_clk_n,
    output wire        tmds_clk_p,
    output wire [2:0]  tmds_d_n,
    output wire [2:0]  tmds_d_p
);
    localparam integer H_BLANK = H_FRONT + H_SYNC + H_BACK;
    localparam integer V_BLANK = V_FRONT + V_SYNC + V_BACK;
    localparam integer H_TOTAL = H_BLANK + H_ACTIVE;
    localparam integer V_TOTAL = V_BLANK + V_ACTIVE;

    reg [10:0] hCount;
    reg [9:0] vCount;
    reg [3:0] resetPipe = 4'b0000;
    reg [2:0] serializerRunPipe = 3'b000;
    // 为三个 OSER10 各复制一级复位寄存器，让布局器能把复位源放到串化器附近；
    // 否则单个高扇出复位 FF 的布线延迟会接近半个串行时钟周期。
    // syn_preserve/syn_keep 是 GowinSynthesis 属性；移植时换成目标工具的
    // keep/dont_touch 等价属性，并重新检查三条复位路径的布局和恢复时间。
    (* syn_preserve = 1, syn_keep = 1 *) reg serializerRunBlue = 1'b0;
    (* syn_preserve = 1, syn_keep = 1 *) reg serializerRunGreen = 1'b0;
    (* syn_preserve = 1, syn_keep = 1 *) reg serializerRunRed = 1'b0;

    always @(posedge pixel_clk)
        resetPipe <= {resetPipe[2:0], reset_n};
    wire pixelReset_n = resetPipe[3];

    // OSER10 的复位恢复时间按 126.667 MHz 串行时钟检查，所以在该时钟域释放；
    // 同时等待 pixelReset_n，保证编码器先启动，再开始串行输出。
    always @(posedge serial_clk) begin
        serializerRunPipe <= {serializerRunPipe[1:0], pixelReset_n};
        serializerRunBlue <= serializerRunPipe[2];
        serializerRunGreen <= serializerRunPipe[2];
        serializerRunRed <= serializerRunPipe[2];
    end

    // fabric 到 OSER 的复位路径接近半个串行周期。显式经过高云 LUT1 原语，
    // INIT=2'h1 同时完成反相和一级物理延迟，让复位释放落在下降沿之后，从而
    // 给下一个边沿留下接近完整的半周期；SDC 只排除这三条有意设计的路径。
    // 这不是普通组合逻辑的写法：移植时应按新器件重新量时序，再用其 LUT 原语
    // 或寄存器复位流水线实现，不能假设另一家器件的 LUT 延迟仍然合适。
    wire serializerResetBlue;
    wire serializerResetGreen;
    wire serializerResetRed;
    LUT1 resetDelayBlue  (.F(serializerResetBlue),  .I0(serializerRunBlue));
    LUT1 resetDelayGreen (.F(serializerResetGreen), .I0(serializerRunGreen));
    LUT1 resetDelayRed   (.F(serializerResetRed),   .I0(serializerRunRed));
    defparam resetDelayBlue.INIT = 2'h1;
    defparam resetDelayGreen.INIT = 2'h1;
    defparam resetDelayRed.INIT = 2'h1;

    wire active = (hCount >= H_BLANK) && (vCount >= V_BLANK);
    wire hsync = (hCount >= H_FRONT) && (hCount < H_FRONT + H_SYNC);
    wire vsync = (vCount >= V_FRONT) && (vCount < V_FRONT + V_SYNC);
    // 只在有效画面且 FIFO 非空时取走一个像素；消隐区不会消耗 FIFO。
    assign pixel_take = pixelReset_n && active && pixel_valid;

    always @(posedge pixel_clk) begin
        if (!pixelReset_n) begin
            hCount <= 11'd0;
            vCount <= 10'd0;
            underflow <= 1'b0;
        end else begin
            // FIFO 断流时锁存 underflow，当前像素由 shownPixel 自动显示为黑色。
            if (active && !pixel_valid)
                underflow <= 1'b1;
            if (hCount == H_TOTAL - 1) begin
                hCount <= 11'd0;
                if (vCount == V_TOTAL - 1)
                    vCount <= 10'd0;
                else
                    vCount <= vCount + 10'd1;
            end else begin
                hCount <= hCount + 11'd1;
            end
        end
    end

    wire [15:0] shownPixel = (active && pixel_valid) ? pixel_data : 16'd0;
    wire [7:0] red   = {shownPixel[15:11], shownPixel[15:13]};
    wire [7:0] green = {shownPixel[10:5],  shownPixel[10:9]};
    wire [7:0] blue  = {shownPixel[4:0],   shownPixel[4:2]};

    wire [9:0] tmdsBlue;
    wire [9:0] tmdsGreen;
    wire [9:0] tmdsRed;
    hdmiTmdsEncoder encBlue (
        .clk(pixel_clk), .reset_n(pixelReset_n), .de(active),
        .ctrl({vsync, hsync}), .data(blue), .encoded(tmdsBlue)
    );
    hdmiTmdsEncoder encGreen (
        .clk(pixel_clk), .reset_n(pixelReset_n), .de(active),
        .ctrl(2'b00), .data(green), .encoded(tmdsGreen)
    );
    hdmiTmdsEncoder encRed (
        .clk(pixel_clk), .reset_n(pixelReset_n), .de(active),
        .ctrl(2'b00), .data(red), .encoded(tmdsRed)
    );

    wire [2:0] serialData;
    // 高云专用 OSER10：每个像素时钟装入一个 10 位 TMDS 字，随后在 5 倍
    // 串行时钟的双边沿上按 D0..D9 顺序发出。移植时换成目标厂商的 10:1
    // OSERDES（必要时级联），保持 5:1 时钟关系、位序和高有效 RESET 不变。
    OSER10 serBlue (
        .Q(serialData[0]), .D0(tmdsBlue[0]), .D1(tmdsBlue[1]),
        .D2(tmdsBlue[2]), .D3(tmdsBlue[3]), .D4(tmdsBlue[4]),
        .D5(tmdsBlue[5]), .D6(tmdsBlue[6]), .D7(tmdsBlue[7]),
        .D8(tmdsBlue[8]), .D9(tmdsBlue[9]), .PCLK(pixel_clk),
        .FCLK(serial_clk), .RESET(serializerResetBlue)
    );
    OSER10 serGreen (
        .Q(serialData[1]), .D0(tmdsGreen[0]), .D1(tmdsGreen[1]),
        .D2(tmdsGreen[2]), .D3(tmdsGreen[3]), .D4(tmdsGreen[4]),
        .D5(tmdsGreen[5]), .D6(tmdsGreen[6]), .D7(tmdsGreen[7]),
        .D8(tmdsGreen[8]), .D9(tmdsGreen[9]), .PCLK(pixel_clk),
        .FCLK(serial_clk), .RESET(serializerResetGreen)
    );
    OSER10 serRed (
        .Q(serialData[2]), .D0(tmdsRed[0]), .D1(tmdsRed[1]),
        .D2(tmdsRed[2]), .D3(tmdsRed[3]), .D4(tmdsRed[4]),
        .D5(tmdsRed[5]), .D6(tmdsRed[6]), .D7(tmdsRed[7]),
        .D8(tmdsRed[8]), .D9(tmdsRed[9]), .PCLK(pixel_clk),
        .FCLK(serial_clk), .RESET(serializerResetRed)
    );

    // 高云 ELVDS_OBUF 在这里用作“仿真差分”输出：它把 I 和反相信号分别放到
    // 同一差分引脚对的 O/OB。CST 实际选择 LVCMOS33D、3.3V、8mA，布局布线
    // 报告中的 Open Drain 为 OFF，因此这是互补 CMOS 推挽，不是真正的 TMDS
    // 电流模驱动，也不是开漏输出。
    //
    // 本板每根 P/N 线在 FPGA 后串 100nF，HDMI 插座侧再各用 50ohm 上拉到
    // 3.3V；电容隔直、外部偏置和接收端终端共同把 CMOS 波形变成兼容的
    // 伪 TMDS 波形。移植时必须把原语、I/O 标准和这套板级网络作为整体处理；
    // 若改用原生 TMDS/LVDS 驱动，不能原样保留这些电容和上拉电阻。
    ELVDS_OBUF outClock (
        .I(pixel_clk), .O(tmds_clk_p), .OB(tmds_clk_n)
    );
    ELVDS_OBUF outBlue (
        .I(serialData[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0])
    );
    ELVDS_OBUF outGreen (
        .I(serialData[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1])
    );
    ELVDS_OBUF outRed (
        .I(serialData[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2])
    );
endmodule

`default_nettype wire
