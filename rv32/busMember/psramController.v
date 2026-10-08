`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// psramController.v  --  PSRAM 低速口（随机 32bit 访问）
//
// 挂在 busManager 的 psram_* 端口上，把 PicoRV32 的一次 native 访问翻译成
// 一次 PSRAM 事务：
//
//   CPU 的 4 字节窗口    -> PSRAM 一个 32bit 字（1 拍数据）
//   mem_wstrb            -> RWDS 字节掩码（sb/sh/sw 全支持，读写双向）
//   mem_addr[1:0]        -> 字节通道，由 PicoRV32 自己在读回时抽取
//
// 地址：访问永远对齐到 32bit，所以 sb 到奇数地址也只搬一个 4 字节窗口，
// 靠掩码只改一个字节。
//
// 上电序列：等 ~410us（>tRPU 150us）-> 写一次 CR0 -> 才允许 CPU 访问。
//
// 配置窗口（busManager 的 psramcfg_*，局部地址 12bit）：
//   0x000  CFG     [5:0] rdLat   [13:8] wrLat     （默认 6 / 4，范围 0~63）
//   0x004  STATUS  [0] initDone  [1] phyBusy
//   0x008  CKPHASE [3:0] PSRAM CK 相移（直连 rPLL.PSDA，默认 4）
//
// !!! rdLat / wrLat / CKPHASE 三个都要上板扫 !!!
// rdLat/wrLat 是"CA 结束之后 FSM 额外等几拍"，CKPHASE 决定采样点落在数据眼
// 的什么位置。前两个只挪整拍，相位不对时怎么挪都对不上，所以必须先扫相位。
//------------------------------------------------------------------------------
module psramController #(
    // 上电等待拍数，80MHz 下 20000 拍 = 250us（tRPU 要求 150us）
    parameter integer PWRUP_CYCLES = 20000
)(
    input  wire        clk,          // 80MHz
    input  wire        clk_p,        // 相移时钟
    input  wire        reset_n,

    // 数据窗口：busManager 已把 0x0200_0000 减掉，这里是 4MiB 内偏移
    input  wire        mem_valid,
    output reg         mem_ready,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [ 3:0] mem_wstrb,
    output reg  [31:0] mem_rdata,

    // 配置窗口
    input  wire        cfg_valid,
    output reg         cfg_ready,
    input  wire [11:0] cfg_addr,
    input  wire [31:0] cfg_wdata,
    input  wire [ 3:0] cfg_wstrb,
    output reg  [31:0] cfg_rdata,

    // PSRAM CK 相移，直接接到 rPLL 的 PSDA 输入
    output wire [3:0]  ckPhase,

    // PSRAM 物理层
    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    output wire [1:0]  O_psram_cs_n,
    output wire [1:0]  O_psram_reset_n,
    inout  wire [1:0]  IO_psram_rwds,
    inout  wire [15:0] IO_psram_dq
);
    // ------------------------------------------------------------ 配置寄存器
    reg [5:0] rdLat    = 6'd6;
    reg [5:0] wrLat    = 6'd4;
    reg [3:0] ckPhaseR = 4'd4;      // CK 相移，DYN_DA_EN=true 时喂给 rPLL.PSDA
    reg       initDone = 1'b0;

    assign ckPhase = ckPhaseR;

    // ---- 诊断 1：clk_p（PSRAM CK 的源时钟）到底有没有在跑 ----
    // 固件读两次比较，变了就说明 PLL 的 CLKOUTP 是活的。
    reg [31:0] ckpCnt = 32'd0;
    always @(posedge clk_p) ckpCnt <= ckpCnt + 32'd1;

    reg [15:0] ckpCntMeta = 16'd0, ckpCntSync = 16'd0;
    always @(posedge clk) begin
        ckpCntMeta <= ckpCnt[31:16];
        ckpCntSync <= ckpCntMeta;
    end

    // ---- 诊断 2：读 CR0，验证器件到底答不答应 ----
    // 写 0x014 触发一次寄存器读，结果在 0x018。
    // 如果 CR0 从来没被写进去，读回来会是器件默认值；如果器件完全不响应，
    // 读回来会全 0/全 F。
    reg        doRegRd   = 1'b0;    // 只由配置块驱动
    reg        regRdStart;          // 只由主 FSM 驱动，通知配置块可以清了
    reg        txRegRd   = 1'b0;
    reg [31:0] regRdData = 32'd0;

    // ---- 诊断 3：可配置的 CR0 写值，用来验证"写进去再读回来" ----
    reg [15:0] cr0Value  = 16'h8FEF;
    reg        doRegWr   = 1'b0;
    reg        regWrStart;

    // ------------------------------------------------------------ 上电等待
    reg [15:0] pwrCnt = 16'd0;

    always @(posedge clk) begin
        if (!reset_n) pwrCnt <= 16'd0;
        else if (pwrCnt != PWRUP_CYCLES[15:0]) pwrCnt <= pwrCnt + 16'd1;
    end

    wire pwrOk = (pwrCnt == PWRUP_CYCLES[15:0]);

    // ------------------------------------------------------------ 主状态机
    localparam [2:0] S_PWR  = 3'd0,
                     S_CFG  = 3'd1,
                     S_IDLE = 3'd2,
                     S_RUN  = 3'd3,
                     S_RESP = 3'd4;

    reg [2:0]  st;
    reg        cfgStarted;
    reg        phyStart;

    // 事务参数在启动那一刻锁存，整笔事务期间保持不变
    reg        txWr;
    reg        txRegWr;
    reg [20:0] txAddr;
    reg [3:0]  txMask;
    reg [31:0] txDin;

    reg [31:0] rdCapture;

    wire phyBusy;
    wire phyDone;
    wire [31:0] phyDout;
    wire        phyDoutWr;

    always @(posedge clk) begin
        mem_ready  <= 1'b0;
        phyStart   <= 1'b0;
        regRdStart <= 1'b0;
        regWrStart <= 1'b0;

        if (!reset_n) begin
            st         <= S_PWR;
            cfgStarted <= 1'b0;
            initDone   <= 1'b0;
            txWr       <= 1'b0;
            txRegWr    <= 1'b0;
            txRegRd    <= 1'b0;
            regRdStart <= 1'b0;
            regWrStart <= 1'b0;
            txAddr     <= 21'd0;
            txMask     <= 4'hF;
            txDin      <= 32'd0;
            mem_rdata  <= 32'd0;
            rdCapture  <= 32'd0;
        end else begin
            case (st)

            // ------------------------------------------------------ 等 tRPU
            S_PWR: begin
                if (pwrOk) begin
                    st         <= S_CFG;
                    cfgStarted <= 1'b0;
                end
            end

            // -------------------------------------------------- 写一次 CR0
            S_CFG: begin
                if (!cfgStarted) begin
                    cfgStarted <= 1'b1;
                    phyStart   <= 1'b1;
                    txWr       <= 1'b1;
                    txRegWr    <= 1'b1;
                    txAddr     <= 21'd0;
                    txMask     <= 4'b0000;
                    txDin      <= 32'd0;
                end else if (phyDone) begin
                    initDone <= 1'b1;
                    st       <= S_IDLE;
                end
            end

            // ---------------------------------------------------------- 空闲
            S_IDLE: begin
                txRegWr <= 1'b0;
                txRegRd <= 1'b0;

                if (doRegRd) begin
                    regRdStart <= 1'b1;
                    txWr     <= 1'b0;
                    txRegRd  <= 1'b1;
                    txAddr   <= 21'd0;
                    txMask   <= 4'hF;
                    txDin    <= 32'd0;
                    phyStart <= 1'b1;
                    st       <= S_RUN;
                end else if (doRegWr) begin
                    regWrStart <= 1'b1;
                    txWr     <= 1'b1;
                    txRegWr  <= 1'b1;
                    txAddr   <= 21'd0;
                    txMask   <= 4'b0000;
                    txDin    <= 32'd0;
                    phyStart <= 1'b1;
                    st       <= S_RUN;
                end else if (mem_valid) begin
                    txWr   <= (mem_wstrb != 4'b0000);
                    txAddr <= {mem_addr[21:2], 1'b0};   // 对齐到 32bit
                    txMask <= ~mem_wstrb;               // RWDS: 1 = 不写
                    txDin  <= mem_wdata;
                    phyStart <= 1'b1;
                    st     <= S_RUN;
                end
            end

            // ------------------------------------------------------ 事务进行
            S_RUN: begin
                if (phyDoutWr) rdCapture <= phyDout;
                if (phyDone) begin
                    if (txRegRd)      regRdData <= rdCapture;
                    else if (!txWr)   mem_rdata <= rdCapture;
                    st <= S_RESP;
                end
            end

            // ------------------------------------------------------ 回 ready
            S_RESP: begin
                mem_ready <= 1'b1;
                st        <= S_IDLE;
            end

            default: st <= S_PWR;
            endcase
        end
    end

    // ------------------------------------------------------------ 配置窗口
    always @(posedge clk) begin
        cfg_ready <= 1'b0;

        if (!reset_n) begin
            rdLat    <= 6'd6;
            wrLat    <= 6'd4;
            ckPhaseR <= 4'd4;
            doRegRd  <= 1'b0;
            doRegWr  <= 1'b0;
        end else begin
            // doRegRd 只在这里驱动：配置写置位，主 FSM 发 regRdStart 后清除。
            if (regRdStart) begin
                doRegRd <= 1'b0;
            end else if (cfg_valid && (cfg_addr[5:2] == 4'd5) && cfg_wstrb[0]) begin
                doRegRd <= 1'b1;                        // 0x014: 触发一次 CR0 读
            end
            if (regWrStart) begin
                doRegWr <= 1'b0;
            end else if (cfg_valid && (cfg_addr[5:2] == 4'd8) && cfg_wstrb[0]) begin
                doRegWr <= 1'b1;                        // 0x020: 用当前 cr0Value 写一次 CR0
            end

            if (cfg_valid) begin
                cfg_ready <= 1'b1;
                if (cfg_addr[3:2] == 2'd0) begin
                    if (cfg_wstrb[0]) rdLat <= cfg_wdata[5:0];      // 0~63
                    if (cfg_wstrb[1]) wrLat <= cfg_wdata[13:8];     // 0~63
                end
                if (cfg_addr[3:2] == 2'd2) begin
                    if (cfg_wstrb[0]) ckPhaseR <= cfg_wdata[3:0];
                end
                if (cfg_addr[5:2] == 4'd7) begin
                    if (cfg_wstrb[0]) cr0Value <= cfg_wdata[15:0];   // 0x01C: 设置 CR0 写值
                end
            end
        end
    end

    always @* begin
        case (cfg_addr[5:2])
            4'd0:    cfg_rdata = {20'd0, wrLat, rdLat};
            4'd1:    cfg_rdata = {30'd0, phyBusy, initDone};
            4'd2:    cfg_rdata = {28'd0, ckPhaseR};
            // 位流版本戳 "PSR8"：固件读这个判断跑的是哪版位流。
            4'd3:    cfg_rdata = 32'h5053_5238;
            4'd4:    cfg_rdata = {16'd0, ckpCntSync};
            4'd6:    cfg_rdata = regRdData;
            4'd7:    cfg_rdata = {16'd0, cr0Value};
            default: cfg_rdata = 32'd0;
        endcase
    end

    // ------------------------------------------------------------------ PHY
    psramPhy phy (
        .clk        (clk),
        .clk_p      (clk_p),
        .reset_n    (reset_n),

        .start      (phyStart),
        .wr         (txWr),
        .regWr      (txRegWr),
        .regRd      (txRegRd),
        .regWrData  (cr0Value),
        .wordAddr   (txAddr),
        .wmask      (txMask),
        .len        (7'd1),
        .rdLat      (rdLat),
        .wrLat      (wrLat),
        .busy       (phyBusy),
        .done       (phyDone),
        .dIn        (txDin),
        .dOut       (phyDout),
        .dOutWr     (phyDoutWr),

        .O_psram_ck     (O_psram_ck),
        .O_psram_ck_n   (O_psram_ck_n),
        .O_psram_cs_n   (O_psram_cs_n),
        .O_psram_reset_n(O_psram_reset_n),
        .IO_psram_rwds  (IO_psram_rwds),
        .IO_psram_dq    (IO_psram_dq)
    );

endmodule

`default_nettype wire
