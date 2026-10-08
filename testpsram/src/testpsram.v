//------------------------------------------------------------------------------
// testpsram.v  --  1:1 @80MHz 内嵌 PSRAM DDR PHY 时序收敛冒烟测试
//
// 器件：GW1NR-9C / GW1NR-LV9QN88PC6/I5（自制板，50MHz 晶振）
//
// 这个工程【只干一件事】：把 16 根 DQ 的 DDR 收发路径完整搭出来，让 Gowin
// 综合 + 布局布线跑一遍，看
//   1) 认不认这套 ODDR/IDDR 写法
//   2) O_psram_* / IO_psram_* 这些 magic 端口能不能自动绑到内部 PSRAM
//   3) 80MHz 下 DDR 输入输出路径能不能收敛
//
// 没有功能意义：读写结果只在内部打转，不输出到任何引脚。
//------------------------------------------------------------------------------
`timescale 1ns/1ps

module testpsram (
    input  wire        clock50MHz,      // 50MHz 晶振，pin 63

    // 内嵌 PSRAM 的 magic 端口：名字一个字都不能改，也不要写进 cst
    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    output wire [1:0]  O_psram_cs_n,
    output wire [1:0]  O_psram_reset_n,
    inout  wire [1:0]  IO_psram_rwds,
    inout  wire [15:0] IO_psram_dq
);

    // ---------------------------------------------------------------- 时钟
    wire clk;       // 80MHz  fabric
    wire clk_p;     // 80MHz  相移，推 PSRAM CK
    wire pll_lock;

    Gowin_rPLL u_pll (
        .clkout  (clk),
        .clkoutp (clk_p),
        .lock    (pll_lock),
        .clkin   (clock50MHz)
    );

    // ------------------------------------------------------------ 复位 + 上电等待
    // PSRAM 上电后要等 tRPU（~150us）才能收命令，这里用 2^14/80MHz = 205us
    reg [13:0] pwr_cnt = 14'd0;
    reg        rst_n   = 1'b0;

    always @(posedge clk) begin
        if (!pll_lock) begin
            pwr_cnt <= 14'd0;
            rst_n   <= 1'b0;
        end else begin
            if (!pwr_cnt[13]) pwr_cnt <= pwr_cnt + 1'b1;
            rst_n <= pwr_cnt[13];
        end
    end

    wire pwr_ok = pwr_cnt[13];

    // ------------------------------------------------------------ 测试驱动
    // 读写交替打到地址 0；读回的数据 XOR 进签名，签名再当作下一次的写数据。
    // 这样读路径和写路径都在环里，综合不会被裁掉。
    wire        busy;
    wire        done;
    wire [31:0] d_out;
    wire        d_out_wr;
    wire        rwds_in;

    reg         wr    = 1'b0;
    reg         start = 1'b0;
    reg  [31:0] sig   = 32'hA5A5_1234;
    reg  [31:0] wdata = 32'h0;

    always @(posedge clk) begin
        start <= 1'b0;
        if (rst_n && pwr_ok && !busy) start <= 1'b1;
        if (done) wr <= ~wr;
    end

    always @(posedge clk) begin
        wdata <= sig ^ 32'h1234_5678;
        if (d_out_wr) sig <= sig ^ d_out ^ {31'b0, rwds_in};
    end

    // ------------------------------------------------------------------ PHY
    psram_phy #(
        .LATENCY     (6),      // 固定延迟 = 2 x CR0[7:4]
        .BURST_WORDS (32)      // 128B / 4B
    ) u_phy (
        .clk            (clk),
        .clk_p          (clk_p),
        .rst_n          (rst_n),

        .start          (start),
        .wr             (wr),
        .addr           (24'd0),
        .busy           (busy),
        .done           (done),
        .d_in           (wdata),
        .d_out          (d_out),
        .d_out_wr       (d_out_wr),
        .rwds_in        (rwds_in),

        .O_psram_ck     (O_psram_ck),
        .O_psram_ck_n   (O_psram_ck_n),
        .O_psram_cs_n   (O_psram_cs_n),
        .O_psram_reset_n(O_psram_reset_n),
        .IO_psram_rwds  (IO_psram_rwds),
        .IO_psram_dq    (IO_psram_dq)
    );

endmodule
