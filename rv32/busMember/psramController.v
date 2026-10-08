`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// PicoRV32 bridge, front/back switcher and two embedded-PSRAM PHYs.
//
// CPU side: 40 MHz PicoRV32 native-memory bus, one logical 4 MiB window.
// PHY side: 80 MHz, two independent x8 dies.  The CPU always reaches the
// logical back die; HDMI exclusively reaches the front die.  A frame-boundary
// swap flips only the mapping, never copies memory contents.
//
// A 32-bit CPU access is split into one or two 16-bit switcher commands.  The
// CPU-to-PHY crossing uses a request/acknowledge toggle with bundled data.
// Future GPU and HDMI ports are already present in the PHY clock domain.
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

    // Future GPU port, synchronous to phy_clk.  GPU has priority over CPU for
    // the back die when both are waiting at a command boundary.
    input  wire        gpu_valid,
    output wire        gpu_ready,
    input  wire        gpu_wr,
    input  wire [21:0] gpu_addr,
    input  wire [ 1:0] gpu_mask,
    input  wire [15:0] gpu_wdata,
    output wire [15:0] gpu_rdata,
    output wire        gpu_done,

    // Future HDMI read port, synchronous to phy_clk and exclusive to front.
    input  wire        hdmi_valid,
    output wire        hdmi_ready,
    input  wire [21:0] hdmi_addr,
    output wire [15:0] hdmi_rdata,
    output wire        hdmi_done,
    input  wire        hdmi_frame_done,
    output wire        frame_swap_request,

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

    localparam [2:0] P_WAIT_INIT  = 3'd0,
                     P_IDLE       = 3'd1,
                     P_LOW_ISSUE  = 3'd2,
                     P_LOW_WAIT   = 3'd3,
                     P_HIGH_ISSUE = 3'd4,
                     P_HIGH_WAIT  = 3'd5;

    // Phase 5 is the center selected from the measured common pass window 2..7.
    reg [3:0] ckPhaseR = 4'd5;
    assign ckPhase = ckPhaseR;

    // ---------------------------------------------------------------- CPU side
    reg [1:0]  cpuState;
    reg [21:0] reqAddrCpu;
    reg [31:0] reqWdataCpu;
    reg [ 3:0] reqWstrbCpu;
    reg        reqToggleCpu;

    reg ackMetaCpu;
    reg ackSyncCpu;
    reg ackSeenCpu;

    reg [31:0] respDataPhy;
    reg        ackTogglePhy;
    wire       initDoneCpu;

    always @(posedge clk) begin
        mem_ready  <= 1'b0;
        ackMetaCpu <= ackTogglePhy;
        ackSyncCpu <= ackMetaCpu;

        if (!reset_n) begin
            cpuState     <= C_IDLE;
            reqAddrCpu   <= 22'd0;
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
                        reqAddrCpu   <= mem_addr[21:0];
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
    reg [2:0] phyResetPipe = 3'b000;
    always @(posedge phy_clk)
        phyResetPipe <= {phyResetPipe[1:0], reset_n};
    wire phyReset_n = phyResetPipe[2];

    // ------------------------------------------------------- CPU request bridge
    reg reqMetaPhy;
    reg reqSyncPhy;
    reg reqSeenPhy;
    reg [2:0] phyState;

    reg        reqWritePhy;
    reg [21:0] reqAddrPhy;
    reg [31:0] reqWdataPhy;
    reg [ 3:0] reqWstrbPhy;

    reg         cpuCmdValid;
    reg         cpuCmdWr;
    reg  [21:0] cpuCmdAddr;
    reg  [ 1:0] cpuCmdMask;
    reg  [15:0] cpuCmdWdata;
    wire        cpuCmdReady;
    wire [15:0] cpuCmdRdata;
    wire        cpuCmdDone;

    wire phyInitDone0;
    wire phyInitDone1;

    always @(posedge phy_clk) begin
        reqMetaPhy <= reqToggleCpu;
        reqSyncPhy <= reqMetaPhy;

        if (!phyReset_n) begin
            reqMetaPhy   <= 1'b0;
            reqSyncPhy   <= 1'b0;
            reqSeenPhy   <= 1'b0;
            phyState     <= P_WAIT_INIT;
            reqWritePhy  <= 1'b0;
            reqAddrPhy   <= 22'd0;
            reqWdataPhy  <= 32'd0;
            reqWstrbPhy  <= 4'd0;
            cpuCmdValid  <= 1'b0;
            cpuCmdWr     <= 1'b0;
            cpuCmdAddr   <= 22'd0;
            cpuCmdMask   <= 2'b11;
            cpuCmdWdata  <= 16'd0;
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
                        reqWritePhy <= (reqWstrbCpu != 4'b0000);
                        reqAddrPhy  <= {reqAddrCpu[21:2], 2'b00};
                        reqWdataPhy <= reqWdataCpu;
                        reqWstrbPhy <= reqWstrbCpu;

                        if ((reqWstrbCpu != 4'b0000) &&
                            (reqWstrbCpu[1:0] == 2'b00)) begin
                            cpuCmdWr    <= 1'b1;
                            cpuCmdAddr  <= {reqAddrCpu[21:2], 2'b00} + 22'd2;
                            cpuCmdMask  <= ~reqWstrbCpu[3:2];
                            cpuCmdWdata <= reqWdataCpu[31:16];
                            cpuCmdValid <= 1'b1;
                            phyState    <= P_HIGH_ISSUE;
                        end else begin
                            cpuCmdWr    <= (reqWstrbCpu != 4'b0000);
                            cpuCmdAddr  <= {reqAddrCpu[21:2], 2'b00};
                            cpuCmdMask  <= (reqWstrbCpu == 4'b0000) ?
                                           2'b11 : ~reqWstrbCpu[1:0];
                            cpuCmdWdata <= reqWdataCpu[15:0];
                            cpuCmdValid <= 1'b1;
                            phyState    <= P_LOW_ISSUE;
                        end
                    end
                end

                P_LOW_ISSUE: begin
                    if (cpuCmdReady) begin
                        cpuCmdValid <= 1'b0;
                        phyState <= P_LOW_WAIT;
                    end
                end

                P_LOW_WAIT: begin
                    if (cpuCmdDone) begin
                        if (!reqWritePhy)
                            respDataPhy[15:0] <= cpuCmdRdata;

                        if (reqWritePhy && reqWstrbPhy[3:2] == 2'b00) begin
                            ackTogglePhy <= ~ackTogglePhy;
                            phyState <= P_IDLE;
                        end else begin
                            cpuCmdWr    <= reqWritePhy;
                            cpuCmdAddr  <= reqAddrPhy + 22'd2;
                            cpuCmdMask  <= reqWritePhy ? ~reqWstrbPhy[3:2] : 2'b11;
                            cpuCmdWdata <= reqWdataPhy[31:16];
                            cpuCmdValid <= 1'b1;
                            phyState    <= P_HIGH_ISSUE;
                        end
                    end
                end

                P_HIGH_ISSUE: begin
                    if (cpuCmdReady) begin
                        cpuCmdValid <= 1'b0;
                        phyState <= P_HIGH_WAIT;
                    end
                end

                P_HIGH_WAIT: begin
                    if (cpuCmdDone) begin
                        if (!reqWritePhy)
                            respDataPhy[31:16] <= cpuCmdRdata;
                        ackTogglePhy <= ~ackTogglePhy;
                        phyState <= P_IDLE;
                    end
                end

                default: phyState <= P_WAIT_INIT;
            endcase
        end
    end

    // ---------------------------------------------------------- swap-control CDC
    reg swapReqToggleCpu;
    reg softFrameToggleCpu;
    reg swapReqMetaPhy, swapReqSyncPhy, swapReqSeenPhy;
    reg softFrameMetaPhy, softFrameSyncPhy, softFrameSeenPhy;

    always @(posedge phy_clk) begin
        if (!phyReset_n) begin
            swapReqMetaPhy    <= 1'b0;
            swapReqSyncPhy    <= 1'b0;
            swapReqSeenPhy    <= 1'b0;
            softFrameMetaPhy  <= 1'b0;
            softFrameSyncPhy  <= 1'b0;
            softFrameSeenPhy  <= 1'b0;
        end else begin
            swapReqMetaPhy   <= swapReqToggleCpu;
            swapReqSyncPhy   <= swapReqMetaPhy;
            swapReqSeenPhy   <= swapReqSyncPhy;
            softFrameMetaPhy <= softFrameToggleCpu;
            softFrameSyncPhy <= softFrameMetaPhy;
            softFrameSeenPhy <= softFrameSyncPhy;
        end
    end

    wire swapReqPulsePhy = swapReqSyncPhy != swapReqSeenPhy;
    wire softFramePulsePhy = softFrameSyncPhy != softFrameSeenPhy;
    wire frameDonePulsePhy = hdmi_frame_done || softFramePulsePhy;

    // ------------------------------------------------------------- switcher/PHY
    wire phyStart0, phyWr0;
    wire [21:0] phyAddr0;
    wire [1:0] phyMask0;
    wire [15:0] phyDin0;
    wire [15:0] phyDout0;
    wire phyBusy0, phyDone0;

    wire phyStart1, phyWr1;
    wire [21:0] phyAddr1;
    wire [1:0] phyMask1;
    wire [15:0] phyDin1;
    wire [15:0] phyDout1;
    wire phyBusy1, phyDone1;

    wire switchBusy;
    wire switchGpuActive;
    wire switchHdmiActive;
    wire switchSwapPending;
    wire switchSwapDoneToggle;
    wire [15:0] switchSwapCount;
    wire switchFrontDie;
    wire switchBackDie;
    wire cpuSequenceActive = (phyState != P_IDLE) &&
                             (phyState != P_WAIT_INIT);

    psramSwitcher switcher (
        .clk(phy_clk), .reset_n(phyReset_n),
        .cpu_valid(cpuCmdValid), .cpu_ready(cpuCmdReady),
        .cpu_sequence_active(cpuSequenceActive),
        .cpu_wr(cpuCmdWr), .cpu_addr(cpuCmdAddr),
        .cpu_mask(cpuCmdMask), .cpu_wdata(cpuCmdWdata),
        .cpu_rdata(cpuCmdRdata), .cpu_done(cpuCmdDone),
        .gpu_valid(gpu_valid), .gpu_ready(gpu_ready), .gpu_wr(gpu_wr),
        .gpu_addr(gpu_addr), .gpu_mask(gpu_mask), .gpu_wdata(gpu_wdata),
        .gpu_rdata(gpu_rdata), .gpu_done(gpu_done),
        .hdmi_valid(hdmi_valid), .hdmi_ready(hdmi_ready),
        .hdmi_addr(hdmi_addr), .hdmi_rdata(hdmi_rdata),
        .hdmi_done(hdmi_done),
        .swap_request_pulse(swapReqPulsePhy),
        .frame_done_pulse(frameDonePulsePhy),
        .swap_request_hdmi(frame_swap_request),
        .swap_pending(switchSwapPending),
        .swap_done_toggle(switchSwapDoneToggle),
        .swap_count(switchSwapCount),
        .front_die(switchFrontDie), .back_die(switchBackDie),
        .any_busy(switchBusy), .gpu_active(switchGpuActive),
        .hdmi_active(switchHdmiActive),
        .phy0_start(phyStart0), .phy0_wr(phyWr0), .phy0_addr(phyAddr0),
        .phy0_mask(phyMask0), .phy0_wdata(phyDin0),
        .phy0_rdata(phyDout0), .phy0_busy(phyBusy0),
        .phy0_done(phyDone0), .phy0_init_done(phyInitDone0),
        .phy1_start(phyStart1), .phy1_wr(phyWr1), .phy1_addr(phyAddr1),
        .phy1_mask(phyMask1), .phy1_wdata(phyDin1),
        .phy1_rdata(phyDout1), .phy1_busy(phyBusy1),
        .phy1_done(phyDone1), .phy1_init_done(phyInitDone1)
    );

    psramPhy #(
        .FREQ_HZ(PHY_FREQ_HZ), .LATENCY(LATENCY), .DIE_INDEX(0)
    ) phy0 (
        .clk(phy_clk), .clk_p(clk_p), .reset_n(phyReset_n),
        .start(phyStart0), .wr(phyWr0), .byteAddr(phyAddr0),
        .wmask(phyMask0), .dIn(phyDin0), .dOut(phyDout0),
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
        .start(phyStart1), .wr(phyWr1), .byteAddr(phyAddr1),
        .wmask(phyMask1), .dIn(phyDin1), .dOut(phyDout1),
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
    reg pendingMetaCpu, pendingSyncCpu;
    reg frontMetaCpu, frontSyncCpu;
    reg backMetaCpu, backSyncCpu;
    reg gpuMetaCpu, gpuSyncCpu;
    reg hdmiMetaCpu, hdmiSyncCpu;
    reg swapDoneMetaCpu, swapDoneSyncCpu, swapDoneSeenCpu;
    reg [15:0] swapCountCpu;

    assign initDoneCpu = init0SyncCpu && init1SyncCpu;
    wire phyBusyAny = switchBusy || (phyState != P_IDLE);

    always @(posedge clk) begin
        if (!reset_n) begin
            init0MetaCpu    <= 1'b0;
            init0SyncCpu    <= 1'b0;
            init1MetaCpu    <= 1'b0;
            init1SyncCpu    <= 1'b0;
            busyMetaCpu     <= 1'b1;
            busySyncCpu     <= 1'b1;
            pendingMetaCpu  <= 1'b0;
            pendingSyncCpu  <= 1'b0;
            frontMetaCpu    <= 1'b1;
            frontSyncCpu    <= 1'b1;
            backMetaCpu     <= 1'b0;
            backSyncCpu     <= 1'b0;
            gpuMetaCpu      <= 1'b0;
            gpuSyncCpu      <= 1'b0;
            hdmiMetaCpu     <= 1'b0;
            hdmiSyncCpu     <= 1'b0;
            swapDoneMetaCpu <= 1'b0;
            swapDoneSyncCpu <= 1'b0;
            swapDoneSeenCpu <= 1'b0;
            swapCountCpu    <= 16'd0;
        end else begin
            init0MetaCpu    <= phyInitDone0;
            init0SyncCpu    <= init0MetaCpu;
            init1MetaCpu    <= phyInitDone1;
            init1SyncCpu    <= init1MetaCpu;
            busyMetaCpu     <= phyBusyAny;
            busySyncCpu     <= busyMetaCpu;
            pendingMetaCpu  <= switchSwapPending;
            pendingSyncCpu  <= pendingMetaCpu;
            frontMetaCpu    <= switchFrontDie;
            frontSyncCpu    <= frontMetaCpu;
            backMetaCpu     <= switchBackDie;
            backSyncCpu     <= backMetaCpu;
            gpuMetaCpu      <= switchGpuActive;
            gpuSyncCpu      <= gpuMetaCpu;
            hdmiMetaCpu     <= switchHdmiActive;
            hdmiSyncCpu     <= hdmiMetaCpu;
            swapDoneMetaCpu <= switchSwapDoneToggle;
            swapDoneSyncCpu <= swapDoneMetaCpu;
            if (swapDoneSyncCpu != swapDoneSeenCpu) begin
                swapDoneSeenCpu <= swapDoneSyncCpu;
                swapCountCpu <= swapCountCpu + 16'd1;
            end
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

    // ---------------------------------------------------------- config/MMIO
    // 0x18 write bit0: request swap at next HDMI frame boundary.
    // 0x18 write bit1: inject a frame-done pulse for pre-HDMI board testing.
    always @(posedge clk) begin
        if (!reset_n) begin
            cfg_ready          <= 1'b0;
            ckPhaseR           <= 4'd5;
            swapReqToggleCpu   <= 1'b0;
            softFrameToggleCpu <= 1'b0;
        end else begin
            cfg_ready <= cfg_valid;
            if (cfg_valid && !cfg_ready && cfg_wstrb[0]) begin
                if (cfg_addr[5:2] == 4'd2)
                    ckPhaseR <= cfg_wdata[3:0];
                if (cfg_addr[5:2] == 4'd6) begin
                    if (cfg_wdata[0])
                        swapReqToggleCpu <= ~swapReqToggleCpu;
                    if (cfg_wdata[1])
                        softFrameToggleCpu <= ~softFrameToggleCpu;
                end
            end
        end
    end

    always @* begin
        case (cfg_addr[5:2])
            4'd0: cfg_rdata = PHY_FREQ_HZ;
            4'd1: cfg_rdata = {23'd0, hdmiSyncCpu, gpuSyncCpu,
                               backSyncCpu, frontSyncCpu, pendingSyncCpu,
                               init1SyncCpu, init0SyncCpu,
                               busySyncCpu, initDoneCpu};
            4'd2: cfg_rdata = {28'd0, ckPhaseR};
            4'd3: cfg_rdata = 32'h5053_5253; // "PSRS": PSRAM switcher
            4'd4: cfg_rdata = {16'd0, ckpCntSync};
            4'd5: cfg_rdata = 32'h0040_0000; // CPU-visible logical back bytes
            4'd6: cfg_rdata = {swapCountCpu, 12'd0, pendingSyncCpu,
                               backSyncCpu, frontSyncCpu, pendingSyncCpu};
            4'd7: cfg_rdata = 32'h0080_0000; // total physical PSRAM bytes
            default: cfg_rdata = 32'd0;
        endcase
    end

    wire unusedPhysicalSwapCount = ^switchSwapCount;
endmodule

`default_nettype wire
