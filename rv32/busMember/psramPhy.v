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
// Each transaction transfers one 16-bit word.  CR0 selects fixed 2x initial
// latency so refresh collisions cannot make the write launch decision depend
// on a single RWDS sample.  Reads still wait for the RWDS data strobe instead
// of sampling after a guessed fixed delay.
//------------------------------------------------------------------------------
module psramPhy #(
    parameter integer FREQ_HZ = 80_000_000,
    parameter integer LATENCY = 3,
    parameter integer DIE_INDEX = 0
) (
    input  wire        clk,
    input  wire        clk_p,
    input  wire        reset_n,

    input  wire        start,
    input  wire        wr,
    input  wire [21:0] byteAddr,
    input  wire [ 1:0] wmask,       // bit 1/0 masks high/low byte; 1 = no write
    input  wire [15:0] dIn,
    output reg  [15:0] dOut,
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
    reg [15:0] writeData;
    reg [1:0]  writeMask;
    reg        dqOen;
    reg        rwdsOen;
    reg        rwdsOutRis;
    reg        rwdsOutFal;
    reg        ramCsN;
    reg        ckEnable;
    reg        ckEnableP;
    reg        waitForReadData;
    reg [2:0]  recoveryCnt;

    wire [7:0] dqOutRis = dqSr[63:56];
    wire [7:0] dqOutFal = dqSr[55:48];
    wire [7:0] dqInRis;
    wire [7:0] dqInFal;
    wire       rwdsInRis;
    wire       rwdsInFal;

    assign busy = (state != S_IDLE);

    // Each instance owns one x8 die.  The wrapper instantiates both channels.
    assign O_psram_ck_n    = 1'b0; // PSRAM powers up in single-ended CK mode
    assign O_psram_reset_n = reset_n;

    always @(posedge clk) begin
        done      <= 1'b0;
        cyclesSr  <= {cyclesSr[22:0], 1'b0};
        dqSr      <= {dqSr[47:0], 16'b0};
        ckEnableP <= ckEnable;

        if (!reset_n) begin
            state              <= S_INIT;
            initCnt            <= {INIT_W{1'b0}};
            cyclesSr           <= 24'd0;
            dqSr               <= 64'd0;
            writeData          <= 16'd0;
            writeMask          <= 2'b11;
            dOut               <= 16'd0;
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
                        dqSr     <= {8'h60, 8'h00, 8'h01, 8'h00,
                                     8'h00, 8'h00, 8'h9f,
                                     CR_LATENCY, 4'hf};
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
                    if (start) begin
                        // 48-bit HyperBus CA followed by padding for the shifter.
                        dqSr <= {~wr, 13'b010_0000_0000_00,
                                 byteAddr[21:4], 13'b0, byteAddr[3:1],
                                 16'b0};
                        writeData          <= dIn;
                        writeMask          <= wmask;
                        ramCsN             <= 1'b0;
                        ckEnable           <= 1'b1;
                        dqOen              <= 1'b0;
                        waitForReadData    <= 1'b0;
                        cyclesSr           <= 24'b10;
                        state              <= wr ? S_WRITE : S_READ;
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
                        dOut     <= {dqInRis, dqInFal};
                        ramCsN   <= 1'b1;
                        ckEnable <= 1'b0;
                        state    <= S_RECOVERY;
                        recoveryCnt <= RECOVERY_WAIT;
                    end else if (cyclesSr[23]) begin
                        // A deliberately bad training phase can miss every
                        // RWDS edge.  Complete with a poison value instead of
                        // deadlocking the CPU; legal 2x latency finishes many
                        // clocks before this guard fires.
                        dOut     <= 16'hdead;
                        ramCsN   <= 1'b1;
                        ckEnable <= 1'b0;
                        state    <= S_RECOVERY;
                        recoveryCnt <= RECOVERY_WAIT;
                    end
                end

                S_WRITE: begin
                    // CR0 fixed-latency mode always uses 2x tACC.  This avoids
                    // a metastability-sensitive RWDS decision during CA and
                    // gives deterministic scheduling for the future DMA path.
                    if (cyclesSr[2 + LATENCY*2]) begin
                        rwdsOen     <= 1'b0;
                        rwdsOutRis  <= writeMask[1];
                        rwdsOutFal  <= writeMask[0];
                        dqSr[63:48] <= writeData;
                        state       <= S_RECOVERY;
                        recoveryCnt <= RECOVERY_WAIT;
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

    // IOB DDR primitives. CK is phase shifted by 90 degrees; all other
    // outputs and all inputs use the fabric clock exactly as the reference.
    wire csTbuf;
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
