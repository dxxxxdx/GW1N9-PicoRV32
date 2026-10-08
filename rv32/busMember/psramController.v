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
// A 32-bit CPU access becomes one two-beat physical burst.  Each streaming beat
// carries only a low 16-bit value; the bridge serializes/deserializes the two
// halves while the PHY keeps CS asserted and sends CA only once.  The
// CPU-to-PHY crossing uses a request/acknowledge toggle with bundled data.
// The HDMI port is active; the future GPU port is already present in the PHY
// clock domain and is currently tied off at the top level.
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

    // Future GPU burst port, synchronous to phy_clk.  Length is expressed in
    // 16-bit beats (1..64).  The current low 16-bit write beat advances on
    // gpu_w_take; returned read beats cannot be back-pressured.
    input  wire        gpu_cmd_valid,
    output wire        gpu_cmd_ready,
    input  wire        gpu_cmd_wr,
    input  wire [21:0] gpu_cmd_addr,
    input  wire [ 6:0] gpu_cmd_words,
    input  wire [15:0] gpu_w_data,
    input  wire [ 1:0] gpu_w_mask,
    output wire        gpu_w_take,
    output wire [15:0] gpu_r_data,
    output wire        gpu_r_valid,
    output wire        gpu_r_last,
    output wire        gpu_done,

    // HDMI read-burst port, synchronous to phy_clk and exclusive to
    // the front die.  The reader must reserve cmd_words FIFO entries first.
    input  wire        hdmi_cmd_valid,
    output wire        hdmi_cmd_ready,
    input  wire [21:0] hdmi_cmd_addr,
    input  wire [ 6:0] hdmi_cmd_words,
    output wire [15:0] hdmi_r_data,
    output wire        hdmi_r_valid,
    output wire        hdmi_r_last,
    output wire        hdmi_done,
    input  wire        hdmi_frame_done,
    output wire        frame_swap_request,
    output reg         hdmi_enable,

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
                     P_CMD       = 3'd2,
                     P_WAIT      = 3'd3;

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
    reg [31:0] reqWdataPhy;
    reg [ 3:0] reqWstrbPhy;

    reg         cpuCmdValid;
    reg         cpuCmdWr;
    reg  [21:0] cpuCmdAddr;
    wire        cpuCmdReady;
    reg         cpuWriteBeat;
    reg         cpuReadBeat;
    wire [15:0] cpuCmdWdata = cpuWriteBeat ? reqWdataPhy[31:16] :
                                                    reqWdataPhy[15:0];
    wire [ 1:0] cpuCmdMask = !reqWritePhy ? 2'b11 :
                                  cpuWriteBeat ? ~reqWstrbPhy[3:2] :
                                                 ~reqWstrbPhy[1:0];
    wire        cpuCmdWTake;
    wire [15:0] cpuCmdRdata;
    wire        cpuCmdRvalid;
    wire        cpuCmdRlast;
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
            reqWdataPhy  <= 32'd0;
            reqWstrbPhy  <= 4'd0;
            cpuCmdValid  <= 1'b0;
            cpuCmdWr     <= 1'b0;
            cpuCmdAddr   <= 22'd0;
            cpuWriteBeat <= 1'b0;
            cpuReadBeat  <= 1'b0;
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
                        reqWdataPhy <= reqWdataCpu;
                        reqWstrbPhy <= reqWstrbCpu;
                        cpuCmdWr     <= (reqWstrbCpu != 4'b0000);
                        cpuCmdAddr   <= {reqAddrCpu[21:2], 2'b00};
                        cpuCmdValid  <= 1'b1;
                        cpuWriteBeat <= 1'b0;
                        cpuReadBeat  <= 1'b0;
                        respDataPhy  <= 32'd0;
                        phyState     <= P_CMD;
                    end
                end

                P_CMD: begin
                    if (cpuCmdReady) begin
                        cpuCmdValid <= 1'b0;
                        phyState <= P_WAIT;
                    end
                end

                P_WAIT: begin
                    if (cpuCmdWTake)
                        cpuWriteBeat <= 1'b1;

                    if (cpuCmdRvalid) begin
                        if (!cpuReadBeat)
                            respDataPhy[15:0] <= cpuCmdRdata;
                        else
                            respDataPhy[31:16] <= cpuCmdRdata;
                        cpuReadBeat <= 1'b1;
                    end

                    if (cpuCmdDone) begin
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
    wire phyCmdValid0, phyCmdReady0, phyWr0;
    wire [21:0] phyAddr0;
    wire [6:0] phyWords0;
    wire [1:0] phyMask0;
    wire [15:0] phyDin0;
    wire [15:0] phyDout0;
    wire phyWTake0, phyRvalid0, phyRlast0;
    wire phyBusy0, phyDone0;

    wire phyCmdValid1, phyCmdReady1, phyWr1;
    wire [21:0] phyAddr1;
    wire [6:0] phyWords1;
    wire [1:0] phyMask1;
    wire [15:0] phyDin1;
    wire [15:0] phyDout1;
    wire phyWTake1, phyRvalid1, phyRlast1;
    wire phyBusy1, phyDone1;

    wire switchBusy;
    wire switchGpuActive;
    wire switchHdmiActive;
    wire switchSwapPending;
    wire switchSwapDoneToggle;
    wire [15:0] switchSwapCount;
    wire switchFrontDie;
    wire switchBackDie;

    psramSwitcher switcher (
        .clk(phy_clk), .reset_n(phyReset_n),
        .cpu_cmd_valid(cpuCmdValid), .cpu_cmd_ready(cpuCmdReady),
        .cpu_cmd_wr(cpuCmdWr), .cpu_cmd_addr(cpuCmdAddr),
        .cpu_cmd_words(7'd2), .cpu_w_data(cpuCmdWdata),
        .cpu_w_mask(cpuCmdMask), .cpu_w_take(cpuCmdWTake),
        .cpu_r_data(cpuCmdRdata), .cpu_r_valid(cpuCmdRvalid),
        .cpu_r_last(cpuCmdRlast), .cpu_done(cpuCmdDone),
        .gpu_cmd_valid(gpu_cmd_valid), .gpu_cmd_ready(gpu_cmd_ready),
        .gpu_cmd_wr(gpu_cmd_wr), .gpu_cmd_addr(gpu_cmd_addr),
        .gpu_cmd_words(gpu_cmd_words), .gpu_w_data(gpu_w_data),
        .gpu_w_mask(gpu_w_mask), .gpu_w_take(gpu_w_take),
        .gpu_r_data(gpu_r_data), .gpu_r_valid(gpu_r_valid),
        .gpu_r_last(gpu_r_last), .gpu_done(gpu_done),
        .hdmi_cmd_valid(hdmi_cmd_valid), .hdmi_cmd_ready(hdmi_cmd_ready),
        .hdmi_cmd_addr(hdmi_cmd_addr), .hdmi_cmd_words(hdmi_cmd_words),
        .hdmi_r_data(hdmi_r_data), .hdmi_r_valid(hdmi_r_valid),
        .hdmi_r_last(hdmi_r_last), .hdmi_done(hdmi_done),
        .swap_request_pulse(swapReqPulsePhy),
        .frame_done_pulse(frameDonePulsePhy),
        .swap_request_hdmi(frame_swap_request),
        .swap_pending(switchSwapPending),
        .swap_done_toggle(switchSwapDoneToggle),
        .swap_count(switchSwapCount),
        .front_die(switchFrontDie), .back_die(switchBackDie),
        .any_busy(switchBusy), .gpu_active(switchGpuActive),
        .hdmi_active(switchHdmiActive),
        .phy0_cmd_valid(phyCmdValid0), .phy0_cmd_ready(phyCmdReady0),
        .phy0_cmd_wr(phyWr0), .phy0_cmd_addr(phyAddr0),
        .phy0_cmd_words(phyWords0), .phy0_w_data(phyDin0),
        .phy0_w_mask(phyMask0), .phy0_w_take(phyWTake0),
        .phy0_r_data(phyDout0), .phy0_r_valid(phyRvalid0),
        .phy0_r_last(phyRlast0), .phy0_busy(phyBusy0),
        .phy0_done(phyDone0), .phy0_init_done(phyInitDone0),
        .phy1_cmd_valid(phyCmdValid1), .phy1_cmd_ready(phyCmdReady1),
        .phy1_cmd_wr(phyWr1), .phy1_cmd_addr(phyAddr1),
        .phy1_cmd_words(phyWords1), .phy1_w_data(phyDin1),
        .phy1_w_mask(phyMask1), .phy1_w_take(phyWTake1),
        .phy1_r_data(phyDout1), .phy1_r_valid(phyRvalid1),
        .phy1_r_last(phyRlast1), .phy1_busy(phyBusy1),
        .phy1_done(phyDone1), .phy1_init_done(phyInitDone1)
    );

    psramPhy #(
        .FREQ_HZ(PHY_FREQ_HZ), .LATENCY(LATENCY), .DIE_INDEX(0)
    ) phy0 (
        .clk(phy_clk), .clk_p(clk_p), .reset_n(phyReset_n),
        .cmd_valid(phyCmdValid0), .cmd_ready(phyCmdReady0),
        .cmd_write(phyWr0), .cmd_addr(phyAddr0), .cmd_words(phyWords0),
        .w_data(phyDin0), .w_mask(phyMask0), .w_take(phyWTake0),
        .r_data(phyDout0), .r_valid(phyRvalid0), .r_last(phyRlast0),
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
        .cmd_valid(phyCmdValid1), .cmd_ready(phyCmdReady1),
        .cmd_write(phyWr1), .cmd_addr(phyAddr1), .cmd_words(phyWords1),
        .w_data(phyDin1), .w_mask(phyMask1), .w_take(phyWTake1),
        .r_data(phyDout1), .r_valid(phyRvalid1), .r_last(phyRlast1),
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
            hdmi_enable        <= 1'b0;
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
                if (cfg_addr[5:2] == 4'd8)
                    hdmi_enable <= cfg_wdata[0];
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
            4'd3: cfg_rdata = 32'h5053_4232; // "PSB2": CR0 128-byte bursts
            4'd4: cfg_rdata = {16'd0, ckpCntSync};
            4'd5: cfg_rdata = 32'h0040_0000; // CPU-visible logical back bytes
            4'd6: cfg_rdata = {swapCountCpu, 12'd0, pendingSyncCpu,
                               backSyncCpu, frontSyncCpu, pendingSyncCpu};
            4'd7: cfg_rdata = 32'h0080_0000; // total physical PSRAM bytes
            4'd8: cfg_rdata = {31'd0, hdmi_enable};
            default: cfg_rdata = 32'd0;
        endcase
    end

    wire unusedPhysicalSwapCount = ^switchSwapCount;
endmodule

`default_nettype wire
