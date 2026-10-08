`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// PicoRV32 bridge for both embedded PSRAM dies.
//
// CPU side: 40 MHz PicoRV32 native memory bus.
// PHY side: 80 MHz, two independent x8 PSRAM dies.
//
// Address map inside this block:
//   0x000000-0x3fffff -> die 0 (future front/back framebuffer bank)
//   0x400000-0x7fffff -> die 1 (future front/back framebuffer bank)
//
// Each die transfers a 16-bit word per non-burst transaction.  A 32-bit CPU
// access is split into low/high halfwords on the selected die.  The clock-domain
// crossing uses a request/acknowledge toggle with bundled data: request fields
// stay stable until the response has crossed back to the CPU clock domain.
//------------------------------------------------------------------------------
module psramController #(
    parameter integer PHY_FREQ_HZ = 80_000_000,
    parameter integer LATENCY = 3
) (
    input  wire        clk,
    input  wire        phy_clk,
    input  wire        clk_p,
    input  wire        reset_n,

    input  wire        mem_valid,
    output reg         mem_ready,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [ 3:0] mem_wstrb,
    output reg  [31:0] mem_rdata,

    input  wire        cfg_valid,
    output reg         cfg_ready,
    input  wire [11:0] cfg_addr,
    input  wire [31:0] cfg_wdata,
    input  wire [ 3:0] cfg_wstrb,
    output reg  [31:0] cfg_rdata,

    output wire [3:0]  ckPhase,

    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    output wire [1:0]  O_psram_cs_n,
    output wire [1:0]  O_psram_reset_n,
    inout  wire [1:0]  IO_psram_rwds,
    inout  wire [15:0] IO_psram_dq
);
    localparam [1:0] C_IDLE = 2'd0,
                     C_WAIT = 2'd1,
                     C_RESP = 2'd2;

    localparam [2:0] P_WAIT_INIT = 3'd0,
                     P_IDLE      = 3'd1,
                     P_LOW_WAIT  = 3'd2,
                     P_HIGH_WAIT = 3'd3;

    // Power up at the previously proven 90-degree setting, then allow firmware
    // to move CLKOUTP through the 16 rPLL phase taps while the PHY is idle.
    // This is intentionally a CPU-domain register: the Gowin rPLL PSDA input
    // is an asynchronous dynamic-control input, not a clocked bus.
    reg [3:0] ckPhaseR = 4'd4;
    assign ckPhase = ckPhaseR;

    // ---------------------------------------------------------------- CPU side
    // Bundled request data.  These registers remain unchanged from the request
    // toggle until the PHY response has returned.
    reg [1:0]  cpuState;
    reg [22:0] reqAddrCpu;
    reg [31:0] reqWdataCpu;
    reg [3:0]  reqWstrbCpu;
    reg        reqToggleCpu;

    reg ackMetaCpu;
    reg ackSyncCpu;
    reg ackSeenCpu;

    // Response data is written in the PHY domain before ackTogglePhy changes
    // and remains stable until the next request completes.
    reg [31:0] respDataPhy;
    reg        ackTogglePhy;

    wire initDoneCpu;

    always @(posedge clk) begin
        mem_ready  <= 1'b0;
        ackMetaCpu <= ackTogglePhy;
        ackSyncCpu <= ackMetaCpu;

        if (!reset_n) begin
            cpuState     <= C_IDLE;
            reqAddrCpu   <= 23'd0;
            reqWdataCpu  <= 32'd0;
            reqWstrbCpu  <= 4'd0;
            reqToggleCpu <= 1'b0;
            ackMetaCpu   <= 1'b0;
            ackSyncCpu   <= 1'b0;
            ackSeenCpu   <= 1'b0;
            mem_rdata    <= 32'd0;
        end else begin
            case (cpuState)
                C_IDLE: begin
                    if (mem_valid && initDoneCpu) begin
                        reqAddrCpu   <= mem_addr[22:0];
                        reqWdataCpu  <= mem_wdata;
                        reqWstrbCpu  <= mem_wstrb;
                        reqToggleCpu <= ~reqToggleCpu;
                        cpuState     <= C_WAIT;
                    end
                end

                C_WAIT: begin
                    if (ackSyncCpu != ackSeenCpu) begin
                        mem_rdata  <= respDataPhy;
                        ackSeenCpu <= ackSyncCpu;
                        cpuState   <= C_RESP;
                    end
                end

                C_RESP: begin
                    // Hold ready until the PicoRV32 master releases valid; this
                    // prevents the just-finished transfer from being replayed.
                    if (mem_valid)
                        mem_ready <= 1'b1;
                    else
                        cpuState <= C_IDLE;
                end

                default: cpuState <= C_IDLE;
            endcase
        end
    end

    // --------------------------------------------------------------- PHY reset
    // Synchronous assertion/deassertion in the 80 MHz domain.  Initial values
    // keep both embedded dies reset while the PLL and CPU reset logic settle.
    reg [2:0] phyResetPipe = 3'b000;
    always @(posedge phy_clk)
        phyResetPipe <= {phyResetPipe[1:0], reset_n};
    wire phyReset_n = phyResetPipe[2];

    // ----------------------------------------------------------- request CDC/FSM
    reg reqMetaPhy;
    reg reqSyncPhy;
    reg reqSeenPhy;
    reg [2:0] phyState;

    reg        activeBank;
    reg        reqWritePhy;
    reg [21:0] reqAddrPhy;
    reg [31:0] reqWdataPhy;
    reg [3:0]  reqWstrbPhy;

    reg        phyStart0;
    reg        phyStart1;
    reg        phyWr;
    reg [21:0] phyAddr;
    reg [1:0]  phyMask;
    reg [15:0] phyDin;

    wire [15:0] phyDout0;
    wire [15:0] phyDout1;
    wire phyBusy0, phyBusy1;
    wire phyDone0, phyDone1;
    wire phyInitDone0, phyInitDone1;

    wire activeDone = activeBank ? phyDone1 : phyDone0;
    wire [15:0] activeDout = activeBank ? phyDout1 : phyDout0;

    always @(posedge phy_clk) begin
        phyStart0 <= 1'b0;
        phyStart1 <= 1'b0;
        reqMetaPhy <= reqToggleCpu;
        reqSyncPhy <= reqMetaPhy;

        if (!phyReset_n) begin
            reqMetaPhy   <= 1'b0;
            reqSyncPhy   <= 1'b0;
            reqSeenPhy   <= 1'b0;
            phyState     <= P_WAIT_INIT;
            activeBank   <= 1'b0;
            reqWritePhy  <= 1'b0;
            reqAddrPhy   <= 22'd0;
            reqWdataPhy  <= 32'd0;
            reqWstrbPhy  <= 4'd0;
            phyStart0    <= 1'b0;
            phyStart1    <= 1'b0;
            phyWr        <= 1'b0;
            phyAddr      <= 22'd0;
            phyMask      <= 2'b11;
            phyDin       <= 16'd0;
            respDataPhy  <= 32'd0;
            ackTogglePhy <= 1'b0;
        end else begin
            case (phyState)
                P_WAIT_INIT: begin
                    if (phyInitDone0 && phyInitDone1)
                        phyState <= P_IDLE;
                end

                P_IDLE: begin
                    if (reqSyncPhy != reqSeenPhy) begin
                        reqSeenPhy  <= reqSyncPhy;
                        activeBank  <= reqAddrCpu[22];
                        reqWritePhy <= (reqWstrbCpu != 4'b0000);
                        reqAddrPhy  <= {reqAddrCpu[21:2], 2'b00};
                        reqWdataPhy <= reqWdataCpu;
                        reqWstrbPhy <= reqWstrbCpu;

                        if ((reqWstrbCpu != 4'b0000) &&
                            (reqWstrbCpu[1:0] == 2'b00)) begin
                            // Upper-half-only store.
                            phyWr   <= 1'b1;
                            phyAddr <= {reqAddrCpu[21:2], 2'b00} + 22'd2;
                            phyMask <= ~reqWstrbCpu[3:2];
                            phyDin  <= reqWdataCpu[31:16];
                            if (reqAddrCpu[22]) phyStart1 <= 1'b1;
                            else                phyStart0 <= 1'b1;
                            phyState <= P_HIGH_WAIT;
                        end else begin
                            // Read, or store touching the lower halfword.
                            phyWr   <= (reqWstrbCpu != 4'b0000);
                            phyAddr <= {reqAddrCpu[21:2], 2'b00};
                            phyMask <= (reqWstrbCpu == 4'b0000) ?
                                       2'b11 : ~reqWstrbCpu[1:0];
                            phyDin  <= reqWdataCpu[15:0];
                            if (reqAddrCpu[22]) phyStart1 <= 1'b1;
                            else                phyStart0 <= 1'b1;
                            phyState <= P_LOW_WAIT;
                        end
                    end
                end

                P_LOW_WAIT: begin
                    if (activeDone) begin
                        if (!reqWritePhy)
                            respDataPhy[15:0] <= activeDout;

                        if (reqWritePhy && (reqWstrbPhy[3:2] == 2'b00)) begin
                            ackTogglePhy <= ~ackTogglePhy;
                            phyState <= P_IDLE;
                        end else begin
                            phyWr   <= reqWritePhy;
                            phyAddr <= reqAddrPhy + 22'd2;
                            phyMask <= reqWritePhy ? ~reqWstrbPhy[3:2] : 2'b11;
                            phyDin  <= reqWdataPhy[31:16];
                            if (activeBank) phyStart1 <= 1'b1;
                            else            phyStart0 <= 1'b1;
                            phyState <= P_HIGH_WAIT;
                        end
                    end
                end

                P_HIGH_WAIT: begin
                    if (activeDone) begin
                        if (!reqWritePhy)
                            respDataPhy[31:16] <= activeDout;
                        ackTogglePhy <= ~ackTogglePhy;
                        phyState <= P_IDLE;
                    end
                end

                default: phyState <= P_WAIT_INIT;
            endcase
        end
    end

    // ------------------------------------------------------------- two x8 dies
    psramPhy #(
        .FREQ_HZ(PHY_FREQ_HZ), .LATENCY(LATENCY), .DIE_INDEX(0)
    ) phy0 (
        .clk(phy_clk), .clk_p(clk_p), .reset_n(phyReset_n),
        .start(phyStart0), .wr(phyWr), .byteAddr(phyAddr),
        .wmask(phyMask), .dIn(phyDin), .dOut(phyDout0),
        .busy(phyBusy0), .done(phyDone0), .initDone(phyInitDone0),
        .O_psram_ck(O_psram_ck[0]), .O_psram_ck_n(O_psram_ck_n[0]),
        .O_psram_cs_n(O_psram_cs_n[0]),
        .O_psram_reset_n(O_psram_reset_n[0]),
        .IO_psram_rwds(IO_psram_rwds[0]), .IO_psram_dq(IO_psram_dq[7:0])
    );

    psramPhy #(
        .FREQ_HZ(PHY_FREQ_HZ), .LATENCY(LATENCY), .DIE_INDEX(1)
    ) phy1 (
        .clk(phy_clk), .clk_p(clk_p), .reset_n(phyReset_n),
        .start(phyStart1), .wr(phyWr), .byteAddr(phyAddr),
        .wmask(phyMask), .dIn(phyDin), .dOut(phyDout1),
        .busy(phyBusy1), .done(phyDone1), .initDone(phyInitDone1),
        .O_psram_ck(O_psram_ck[1]), .O_psram_ck_n(O_psram_ck_n[1]),
        .O_psram_cs_n(O_psram_cs_n[1]),
        .O_psram_reset_n(O_psram_reset_n[1]),
        .IO_psram_rwds(IO_psram_rwds[1]), .IO_psram_dq(IO_psram_dq[15:8])
    );

    // ------------------------------------------------------------ diagnostics
    reg init0MetaCpu, init0SyncCpu;
    reg init1MetaCpu, init1SyncCpu;
    reg busyMetaCpu, busySyncCpu;
    assign initDoneCpu = init0SyncCpu && init1SyncCpu;
    wire phyBusyAny = phyBusy0 || phyBusy1 || (phyState != P_IDLE);

    always @(posedge clk) begin
        if (!reset_n) begin
            init0MetaCpu <= 1'b0;
            init0SyncCpu <= 1'b0;
            init1MetaCpu <= 1'b0;
            init1SyncCpu <= 1'b0;
            busyMetaCpu  <= 1'b1;
            busySyncCpu  <= 1'b1;
        end else begin
            init0MetaCpu <= phyInitDone0;
            init0SyncCpu <= init0MetaCpu;
            init1MetaCpu <= phyInitDone1;
            init1SyncCpu <= init1MetaCpu;
            busyMetaCpu  <= phyBusyAny;
            busySyncCpu  <= busyMetaCpu;
        end
    end

    // Count phase-clock edges for a board-level clock-alive diagnostic.
    reg [31:0] ckpCnt = 32'd0;
    reg [15:0] ckpCntMeta;
    reg [15:0] ckpCntSync;
    always @(posedge clk_p)
        ckpCnt <= ckpCnt + 32'd1;
    always @(posedge clk) begin
        if (!reset_n) begin
            ckpCntMeta <= 16'd0;
            ckpCntSync <= 16'd0;
        end else begin
            ckpCntMeta <= ckpCnt[31:16];
            ckpCntSync <= ckpCntMeta;
        end
    end

    always @(posedge clk) begin
        if (!reset_n) begin
            cfg_ready <= 1'b0;
            ckPhaseR  <= 4'd4;
        end else begin
            cfg_ready <= cfg_valid;
            if (cfg_valid && !cfg_ready && cfg_addr[5:2] == 4'd2 &&
                cfg_wstrb[0])
                ckPhaseR <= cfg_wdata[3:0];
        end
    end

    always @* begin
        case (cfg_addr[5:2])
            4'd0:    cfg_rdata = PHY_FREQ_HZ;
            4'd1:    cfg_rdata = {28'd0, init1SyncCpu, init0SyncCpu,
                                  busySyncCpu, initDoneCpu};
            4'd2:    cfg_rdata = {28'd0, ckPhaseR};
            4'd3:    cfg_rdata = 32'h5053_5246; // "PSRF": fixed latency rev F
            4'd4:    cfg_rdata = {16'd0, ckpCntSync};
            4'd5:    cfg_rdata = 32'h0080_0000; // total CPU-visible bytes
            default: cfg_rdata = 32'd0;
        endcase
    end

endmodule

`default_nettype wire
