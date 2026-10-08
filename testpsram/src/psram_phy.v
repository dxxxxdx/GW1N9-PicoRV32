//------------------------------------------------------------------------------
// psram_phy.v  --  GW1NR-9C 内嵌 PSRAM (HyperRAM 协议) 1:1 DDR PHY
//
// 这是一份【时序收敛冒烟测试】用的 PHY，不是完整可用的控制器：
//   * 没有上电 CR0 配置
//   * 没有 tRPU(150us) 之外的初始化
//   * 没有真机校准，cycle 对齐需要仿真确认
// 目的只有一个：让 Gowin 综合/布线在 1:1 @80MHz、16 根 DQ DDR 下跑一遍，
// 看它认不认这套 ODDR/IDDR 结构，以及时序报告能不能收敛。
//
// 传输结构（两个 die 并行，16 根 DQ）：
//   CA 阶段    3 拍 ：48bit 命令地址，每个 die 各自收到同样的 48bit（16bit/拍）
//   延迟阶段   LATENCY 拍
//   数据阶段   32 拍 ：128B，每拍 4B（16 根 DQ x DDR）
//   CS 拉高 + 间隔
//
// 每拍 32bit 的映射：
//   tx_word[31:16] = die1 的 16bit（[31:24] 上升沿, [23:16] 下降沿）
//   tx_word[15: 0] = die0 的 16bit（[15: 8] 上升沿, [ 7: 0] 下降沿）
//   接收方向对称，rx_word 拼回 32bit
//------------------------------------------------------------------------------
`timescale 1ns/1ps

module psram_phy #(
    parameter LATENCY     = 6,   // 固定延迟时 = 2 x CR0[7:4]；变量延迟时按 RWDS 判断
    parameter BURST_WORDS = 32   // 128B / 4B
)(
    input  wire        clk,          // 80MHz，fabric 侧
    input  wire        clk_p,        // 相移时钟，只用来推 CK
    input  wire        rst_n,

    // ---- 用户侧（简单命令接口，够验证时序就行）----
    input  wire        start,        // 单周期脉冲
    input  wire        wr,           // 1=写 0=读
    input  wire [23:0] addr,         // 字节地址（128B 对齐）
    output wire        busy,
    output reg         done,         // 单周期脉冲
    input  wire [31:0] d_in,         // 写数据，数据阶段每拍取一个
    output wire [31:0] d_out,        // 读数据，数据阶段每拍有效
    output wire        d_out_wr,     // 读数据有效
    output wire        rwds_in,      // 读回采到的 RWDS（只为把输入路径留住）

    // ---- PSRAM 物理层（顶层 magic 端口，cst 里不要写）----
    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    output wire [1:0]  O_psram_cs_n,
    output wire [1:0]  O_psram_reset_n,
    inout  wire [1:0]  IO_psram_rwds,
    inout  wire [15:0] IO_psram_dq
);

    // ---------------------------------------------------------------- 状态
    localparam S_IDLE = 3'd0,
               S_CA   = 3'd1,
               S_LAT  = 3'd2,
               S_DATA = 3'd3,
               S_END  = 3'd4,
               S_GAP  = 3'd5;

    reg  [2:0]  st;
    reg  [1:0]  ca_ph;         // CA 还要发几拍
    reg  [5:0]  cnt;
    reg  [47:0] ca_sr;
    reg  [31:0] tx_word;

    reg  ck_en;
    reg  cs_n;
    reg  dq_oen;               // 1 = 高阻(读)，0 = 驱动
    reg  rwds_oen;             // 1 = 高阻

    // ------------------------------------------------------------- CA 构造
    // 48bit CA：MSB 先发
    //   [47]    = 1 读 / 0 写
    //   [46]    = 0
    //   [45]    = 1 linear burst（不 wrap，顺序走）
    //   [44:16] = addr[21:4]，16 字节组地址
    //   [15:3]  = 0
    //   [2:0]   = addr[3:1]，组内 2 字节偏移
    wire [47:0] ca_new = {~wr, 13'b010_0000_0000_00, addr[21:4], 13'b0, addr[3:1]};

    // ---------------------------------------------------------- DDR 收发接线
    wire [15:0] dq_out_ris = tx_word[31:16];   // die1 上升 / die0 上升
    wire [15:0] dq_out_fal = tx_word[15: 0];   // die1 下降 / die0 下降
    wire [15:0] dq_in_ris;
    wire [15:0] dq_in_fal;
    wire [31:0] rx_word    = {dq_in_ris, dq_in_fal};

    assign busy     = (st != S_IDLE);
    assign d_out    = rx_word;
    assign d_out_wr = (st == S_DATA) && !wr;

    assign O_psram_reset_n = {2{rst_n}};
    assign O_psram_ck_n    = 2'b00;            // 单端 CK，CK# 常低

    // ------------------------------------------------------------------ FSM
    always @(posedge clk) begin
        done <= 1'b0;

        if (!rst_n) begin
            st       <= S_IDLE;
            ca_ph    <= 2'd0;
            cnt      <= 6'd0;
            ca_sr    <= 48'd0;
            tx_word  <= 32'd0;
            ck_en    <= 1'b0;
            cs_n     <= 1'b1;
            dq_oen   <= 1'b1;
            rwds_oen <= 1'b1;
        end else begin
            case (st)

            // ---------------------------------------------------------- 空闲
            S_IDLE: begin
                ck_en    <= 1'b0;
                cs_n     <= 1'b1;
                dq_oen   <= 1'b1;
                rwds_oen <= 1'b1;
                if (start) begin
                    ca_sr    <= ca_new;
                    ca_ph    <= 2'd3;
                    tx_word  <= {ca_new[47:32], ca_new[47:32]};  // 两个 die 同一个 CA
                    cs_n     <= 1'b0;
                    ck_en    <= 1'b1;
                    dq_oen   <= 1'b0;
                    rwds_oen <= 1'b1;                            // CA 期间 RWDS 由器件驱动
                    st       <= S_CA;
                end
            end

            // ------------------------------------------------- CA：3 拍，每拍 16bit
            S_CA: begin
                ca_sr   <= {ca_sr[31:0], 16'd0};
                tx_word <= {ca_sr[31:16], ca_sr[31:16]};
                ca_ph   <= ca_ph - 1'b1;
                if (ca_ph == 2'd1) begin
                    st  <= S_LAT;
                    cnt <= LATENCY[5:0];
                    dq_oen   <= wr ? 1'b0 : 1'b1;   // 写: 驱动 DQ; 读: 释放
                    rwds_oen <= wr ? 1'b0 : 1'b1;   // 写: 驱动 RWDS(全 0 = 全写)
                end
            end

            // ---------------------------------------------------------- 等延迟
            S_LAT: begin
                tx_word <= 32'd0;                   // 写的话这里开始出数据
                if (cnt == 6'd0) begin
                    st  <= S_DATA;
                    cnt <= BURST_WORDS[5:0] - 1'b1;
                end else begin
                    cnt <= cnt - 1'b1;
                end
            end

            // ------------------------------------------------ 数据：32 拍 x 4B
            S_DATA: begin
                if (wr) tx_word <= d_in;            // 写：每拍从用户侧取一个新 32bit
                if (cnt == 6'd0) st <= S_END;
                else             cnt <= cnt - 1'b1;
            end

            // ------------------------------------------------------------ 收尾
            S_END: begin
                cs_n     <= 1'b1;
                ck_en    <= 1'b0;
                dq_oen   <= 1'b1;
                rwds_oen <= 1'b1;
                tx_word  <= 32'd0;
                done     <= 1'b1;
                cnt      <= 6'd16;                  // 让器件抬 CS 做 refresh
                st       <= S_GAP;
            end

            // ------------------------------------------------------ 两次之间间隔
            S_GAP: begin
                if (cnt == 6'd0) st <= S_IDLE;
                else             cnt <= cnt - 1'b1;
            end

            default: st <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------ PHY
    //
    // ！！！ ODDR / IDDR 在高云里是 IOB 里的硬资源，一个实例对应一个 pad ！！！
    // 一个 ODDR 不能扇出到两根顶层线，否则综合报：
    //   ERROR (CK0021) ... cannot drive instance 'xxx_1_s0'(TBUF) by wire ...
    // 所以 2 个 die 的 CK / CS / RWDS 必须每个 bit 各自一个 ODDR / IDDR。

    genvar i;

    // CK：每根一个 ODDR，拼出 50% 方波，用相移时钟推，D1 固定 0
    generate
        for (i = 0; i < 2; i = i + 1) begin : g_ck
            wire ck_tbuf;
            ODDR oddr_ck (
                .CLK (clk_p),
                .D0  (ck_en),
                .D1  (1'b0),
                .TX  (1'b0),          // TX=1 才是高阻，常输出要显式接 0
                .Q0  (ck_tbuf)
            );
            assign O_psram_ck[i] = ck_tbuf;
        end
    endgenerate

    // CS：两个 die 一起选（= 16bit 并行访问），每根一个 ODDR
    generate
        for (i = 0; i < 2; i = i + 1) begin : g_cs
            wire cs_tbuf;
            ODDR oddr_cs (
                .CLK (clk),
                .D0  (cs_n),
                .D1  (cs_n),
                .TX  (1'b0),
                .Q0  (cs_tbuf)
            );
            assign O_psram_cs_n[i] = cs_tbuf;
        end
    endgenerate

    // RWDS：写数据阶段输出全 0（数据掩码 = 全写），其余时间高阻
    wire [1:0] rwds_in_ris, rwds_in_fal;

    generate
        for (i = 0; i < 2; i = i + 1) begin : g_rwds
            wire rwds_tbuf, rwds_oen_tbuf;

            ODDR oddr_rwds (
                .CLK (clk),
                .D0  (1'b0),
                .D1  (1'b0),
                .TX  (rwds_oen),
                .Q0  (rwds_tbuf),
                .Q1  (rwds_oen_tbuf)
            );
            assign IO_psram_rwds[i] = rwds_oen_tbuf ? 1'bz : rwds_tbuf;

            IDDR iddr_rwds (
                .CLK (clk),
                .D   (IO_psram_rwds[i]),
                .Q0  (rwds_in_ris[i]),
                .Q1  (rwds_in_fal[i])
            );
        end
    endgenerate

    // 只用 die0 的 RWDS 做观察，保证输入路径不被裁掉
    assign rwds_in = rwds_in_ris[0] ^ rwds_in_fal[0];

    // DQ：16 根，每根一个 ODDR 出 + 一个 IDDR 入
    generate
        for (i = 0; i < 16; i = i + 1) begin : g_dq
            wire dq_tbuf, dq_oen_tbuf;

            ODDR oddr_dq (
                .CLK (clk),
                .D0  (dq_out_ris[i]),
                .D1  (dq_out_fal[i]),
                .TX  (dq_oen),
                .Q0  (dq_tbuf),
                .Q1  (dq_oen_tbuf)
            );
            assign IO_psram_dq[i] = dq_oen_tbuf ? 1'bz : dq_tbuf;

            IDDR iddr_dq (
                .CLK (clk),
                .D   (IO_psram_dq[i]),
                .Q0  (dq_in_ris[i]),
                .Q1  (dq_in_fal[i])
            );
        end
    endgenerate

endmodule
