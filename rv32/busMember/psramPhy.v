`timescale 1ns / 1ps
`default_nettype none

// SPDX-License-Identifier: Apache-2.0
// Derived from zf3/psram-tang-nano-9k, Copyright 2022 Feng Zhou.

//------------------------------------------------------------------------------
// psramPhy.v -- one GW1NR-9C embedded PSRAM die, 1:1 DDR controller
//
// Based on the proven open-source Tang Nano 9K controller by Feng Zhou
// (zf3/psram-tang-nano-9k).  The QN88 device exposes two independent x8 PSRAM
// dies; the wrapper creates one instance of this PHY for each 4 MiB die.
//
// One command transfers 1..64 consecutive 16-bit words (2..128 bytes).  The
// client presents the current write beat continuously and advances it whenever
// w_take pulses.  Read beats are reported by r_valid; the physical stream
// cannot be back-pressured after a command has started, so the client must
// reserve enough FIFO space before issuing a read.
//
// CR0 selects fixed 2x initial latency so refresh collisions cannot make the
// write launch decision depend on a single RWDS sample.  Reads still wait for
// the RWDS data strobe instead of sampling after a guessed fixed delay.
//------------------------------------------------------------------------------
module psramPhy #(
    parameter integer FREQ_HZ = 80_000_000,
    parameter integer LATENCY = 3,
    parameter integer DIE_INDEX = 0
) (
    input  wire        clk,
    input  wire        clk_p,
    input  wire        reset_n,

    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire        cmd_write,
    input  wire [21:0] cmd_addr,
    input  wire [ 6:0] cmd_words,   // number of 16-bit beats, 1..64

    input  wire [15:0] w_data,
    input  wire [ 1:0] w_mask,      // bit 1/0 masks high/low byte; 1 = no write
    output wire        w_take,      // advance w_data/w_mask for the next beat

    output reg  [15:0] r_data,
    output reg         r_valid,
    output reg         r_last,
    output wire        busy,
    output reg         done,
    output reg         initDone,

    output wire        O_psram_ck,
    output wire        O_psram_ck_n,
    output wire        O_psram_cs_n,
    output wire        O_psram_reset_n,
    inout  wire        IO_psram_rwds,
    inout  wire [7:0]  IO_psram_dq
);
    localparam [2:0] S_INIT   = 3'd0,
                     S_CONFIG = 3'd1,
                     S_IDLE   = 3'd2,
                     S_READ   = 3'd3,
                     S_WRITE  = 3'd4,
                     S_RECOVERY = 3'd5;

    // W955D8MBYA tRWR is 36 ns minimum.  At 80 MHz one cycle is 12.5 ns;
    // holding busy through this many extra recovery states, plus the normal
    // done/start handshake, gives at least 50 ns of physical CS-high time.
    localparam [2:0] RECOVERY_WAIT = 3'd2;

    localparam [3:0] CR_LATENCY = LATENCY == 3 ? 4'b1110 :
                                  LATENCY == 4 ? 4'b1111 :
                                  LATENCY == 5 ? 4'b0000 :
                                  LATENCY == 6 ? 4'b0001 : 4'b1110;

    // Wait at least 160 us after reset release (datasheet tRPU is 150 us).
    localparam integer INIT_CYCLES = (FREQ_HZ / 1000) * 160 / 1000;
    localparam integer INIT_W = $clog2(INIT_CYCLES + 1);

    reg [2:0] state;
    reg [INIT_W-1:0] initCnt;
    reg [23:0] cyclesSr;
    reg [63:0] dqSr;
    reg [6:0]  beatsLeft;
    reg        writeDataPhase;
    reg        dqOen;
    reg        rwdsOen;
    reg        rwdsOutRis;
    reg        rwdsOutFal;
    reg        ramCsN;
    reg        ckEnable;
    reg        ckEnableP;
    reg        waitForReadData;
    reg        readDataStarted;
    reg [2:0]  recoveryCnt;

    wire [7:0] dqOutRis = dqSr[63:56];
    wire [7:0] dqOutFal = dqSr[55:48];
    wire [7:0] dqInRis;
    wire [7:0] dqInFal;
    wire       rwdsInRis;
    wire       rwdsInFal;

    assign busy = (state != S_IDLE);
    assign cmd_ready = initDone && (state == S_IDLE);
    wire writeBeatNow = state == S_WRITE &&
                        (cyclesSr[2 + LATENCY*2] || writeDataPhase);
    assign w_take = writeBeatNow;

    // Each instance owns one x8 die.  The wrapper instantiates both channels.
    assign O_psram_ck_n    = 1'b0; // PSRAM powers up in single-ended CK mode
    assign O_psram_reset_n = reset_n;

    always @(posedge clk) begin
        done      <= 1'b0;
        r_valid   <= 1'b0;
        r_last    <= 1'b0;
        cyclesSr  <= {cyclesSr[22:0], 1'b0};
        dqSr      <= {dqSr[47:0], 16'b0};
        ckEnableP <= ckEnable;

        if (!reset_n) begin
            state              <= S_INIT;
            initCnt            <= {INIT_W{1'b0}};
            cyclesSr           <= 24'd0;
            dqSr               <= 64'd0;
            beatsLeft          <= 7'd0;
            writeDataPhase     <= 1'b0;
            r_data             <= 16'd0;
            r_valid            <= 1'b0;
            r_last             <= 1'b0;
            initDone           <= 1'b0;
            done               <= 1'b0;
            dqOen              <= 1'b1;
            rwdsOen            <= 1'b1;
            rwdsOutRis         <= 1'b1;
            rwdsOutFal         <= 1'b1;
            ramCsN             <= 1'b1;
            ckEnable           <= 1'b0;
            ckEnableP          <= 1'b0;
            waitForReadData    <= 1'b0;
            readDataStarted    <= 1'b0;
            recoveryCnt        <= 3'd0;
        end else begin
            case (state)
                S_INIT: begin
                    ramCsN   <= 1'b1;
                    ckEnable <= 1'b0;
                    dqOen    <= 1'b1;
                    rwdsOen  <= 1'b1;
                    if (initCnt == INIT_CYCLES - 1) begin
                        // CR0 write: 35-ohm drive, fixed 2x latency, latency 3.
                        // The stronger drive is the upstream 81 MHz stability
                        // fix (zf3/psram-tang-nano-9k pull request #10).
                        cyclesSr <= 24'b1;
                        ramCsN   <= 1'b0;
                        state    <= S_CONFIG;
                    end else begin
                        initCnt <= initCnt + {{(INIT_W-1){1'b0}}, 1'b1};
                    end
                end

                S_CONFIG: begin
                    if (cyclesSr[0]) begin
                        // CR0[1:0]=00 selects a 128-byte wrapped group.  The
                        // normal CA requests linear bursts as well, so a
                        // 64-beat HDMI command is safe under either decoding.
                        dqSr     <= {8'h60, 8'h00, 8'h01, 8'h00,
                                     8'h00, 8'h00, 8'h9f,
                                     CR_LATENCY, 4'hc};
                        dqOen    <= 1'b0;
                        ckEnable <= 1'b1;
                    end
                    if (cyclesSr[4]) begin
                        state     <= S_IDLE;
                        initDone  <= 1'b1;
                        ckEnable  <= 1'b0;
                        dqOen     <= 1'b1;
                        rwdsOen   <= 1'b1;
                        ramCsN    <= 1'b1;
                        cyclesSr  <= 24'b1;
                    end
                end

                S_IDLE: begin
                    ramCsN   <= 1'b1;
                    ckEnable <= 1'b0;
                    dqOen    <= 1'b1;
                    rwdsOen  <= 1'b1;
                    if (cmd_valid && cmd_ready) begin
                        // 48-bit HyperBus CA followed by padding for the shifter.
                        dqSr <= {~cmd_write, 13'b010_0000_0000_00,
                                 cmd_addr[21:4], 13'b0, cmd_addr[3:1],
                                 16'b0};
                        beatsLeft          <= cmd_words == 7'd0 ? 7'd1 :
                                              cmd_words > 7'd64 ? 7'd64 :
                                              cmd_words;
                        writeDataPhase     <= 1'b0;
                        ramCsN             <= 1'b0;
                        ckEnable           <= 1'b1;
                        dqOen              <= 1'b0;
                        waitForReadData    <= 1'b0;
                        readDataStarted    <= 1'b0;
                        cyclesSr           <= 24'b10;
                        state              <= cmd_write ? S_WRITE : S_READ;
                    end
                end

                S_READ: begin
                    if (cyclesSr[3])
                        dqOen <= 1'b1; // CA complete; release DQ for the memory

                    // Ignore RWDS transitions belonging to CA/latency.  Once the
                    // earliest legal data time is reached, a RWDS edge marks a
                    // valid 16-bit word in the IDDR outputs.
                    if (cyclesSr[9])
                        waitForReadData <= 1'b1;

                    if (waitForReadData && (rwdsInRis ^ rwdsInFal)) begin
                        r_data  <= {dqInRis, dqInFal};
                        r_valid <= 1'b1;
                        r_last  <= beatsLeft == 7'd1;
                        readDataStarted <= 1'b1;
                        if (beatsLeft == 7'd1) begin
                            ramCsN      <= 1'b1;
                            ckEnable    <= 1'b0;
                            state       <= S_RECOVERY;
                            recoveryCnt <= RECOVERY_WAIT;
                        end else begin
                            beatsLeft <= beatsLeft - 7'd1;
                        end
                    end else if (!readDataStarted && cyclesSr[23]) begin
                        // A deliberately bad training phase can miss every
                        // RWDS edge.  Complete with a poison value instead of
                        // deadlocking the CPU; legal 2x latency finishes many
                        // clocks before this guard fires.
                        r_data      <= 16'hdead;
                        r_valid     <= 1'b1;
                        r_last      <= 1'b1;
                        ramCsN      <= 1'b1;
                        ckEnable    <= 1'b0;
                        state       <= S_RECOVERY;
                        recoveryCnt <= RECOVERY_WAIT;
                    end
                end

                S_WRITE: begin
                    // CR0 fixed-latency mode always uses 2x tACC.  This avoids
                    // a metastability-sensitive RWDS decision during CA and
                    // gives deterministic scheduling for the future DMA path.
                    if (writeBeatNow) begin
                        rwdsOen     <= 1'b0;
                        rwdsOutRis  <= w_mask[1];
                        rwdsOutFal  <= w_mask[0];
                        dqSr[63:48] <= w_data;
                        writeDataPhase <= 1'b1;
                        if (beatsLeft == 7'd1) begin
                            state          <= S_RECOVERY;
                            recoveryCnt    <= RECOVERY_WAIT;
                            writeDataPhase <= 1'b0;
                        end else begin
                            beatsLeft <= beatsLeft - 7'd1;
                        end
                    end
                end

                S_RECOVERY: begin
                    // Keep all outputs inactive long enough to satisfy tRWR
                    // before advertising completion to the bridge.  For a
                    // write, entering this state one cycle before these
                    // assignments also lets the ODDR emit the data word.
                    ramCsN   <= 1'b1;
                    ckEnable <= 1'b0;
                    dqOen    <= 1'b1;
                    rwdsOen  <= 1'b1;
                    if (recoveryCnt != 3'd0) begin
                        recoveryCnt <= recoveryCnt - 3'd1;
                    end else begin
                        state <= S_IDLE;
                        done  <= 1'b1;
                    end
                end

                default: state <= S_INIT;
            endcase
        end
    end

    // 以下 ODDR/IDDR 是高云 I/O DDR 原语，应被布局到引脚附近的 IOB 中：
    // D0/Q0 对应上升沿，D1/Q1 对应下降沿，一拍传两个 8 位数据并拼成 16 位字。
    // 移植时换成目标厂商的 ODDR/IDDR 或 OSERDES/ISERDES，并保持两条边的
    // 位序不变。PSRAM CK 独用相移 clk_p，其余收发均使用 PHY 时钟 clk。
    //
    // Gowin ODDR 的 TX/Q1 在这里还承担 DDR 化的三态控制；其他厂商通常要
    // 接专用 OBUFT/IOBUF 的 T 引脚，必须让输出使能也走等价的 IOB 时序路径。
    wire csTbuf;
    // CS# 不需要 DDR 数据变化，但借 ODDR 把它固定收进 IOB，缩短输出路径。
    ODDR oddrCs (
        .CLK(clk), .D0(ramCsN), .D1(ramCsN), .TX(1'b0), .Q0(csTbuf)
    );
    assign O_psram_cs_n = csTbuf;

    wire rwdsTbuf, rwdsOenTbuf;
    ODDR oddrRwds (
        .CLK(clk), .D0(rwdsOutRis), .D1(rwdsOutFal),
        .TX(rwdsOen), .Q0(rwdsTbuf), .Q1(rwdsOenTbuf)
    );
    assign IO_psram_rwds = rwdsOenTbuf ? 1'bz : rwdsTbuf;

    wire ckTbuf;
    // D0=1、D1=0 时由 ODDR 直接生成 PSRAM 所需的连续翻转时钟波形。
    ODDR oddrCk (
        .CLK(clk_p), .D0(ckEnableP), .D1(1'b0), .TX(1'b0), .Q0(ckTbuf)
    );
    assign O_psram_ck = ckTbuf;

    IDDR iddrRwds (
        .CLK(clk), .D(IO_psram_rwds), .Q0(rwdsInRis), .Q1(rwdsInFal)
    );

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_dq
            wire dqTbuf, dqOenTbuf;
            // 每个 DQ 位各占一组输出/输入 DDR 单元；Q1 同时带出三态控制。
            ODDR oddrDq (
                .CLK(clk), .D0(dqOutRis[i]), .D1(dqOutFal[i]),
                .TX(dqOen), .Q0(dqTbuf), .Q1(dqOenTbuf)
            );
            assign IO_psram_dq[i] = dqOenTbuf ? 1'bz : dqTbuf;

            IDDR iddrDq (
                .CLK(clk), .D(IO_psram_dq[i]),
                .Q0(dqInRis[i]), .Q1(dqInFal[i])
            );
        end
    endgenerate

    wire unusedDieIndex = DIE_INDEX[0];
endmodule

`default_nettype wire
