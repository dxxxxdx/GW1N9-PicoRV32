`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// Logical front/back-bank switch in front of the two independent x8 PHYs.
//
// The HDMI client exclusively owns the front die.  CPU and GPU share the back
// die, with GPU priority whenever both present a command.  A swap request is
// sticky; it is committed only after a frame-done event and after both physical
// PHY transactions have completed.  No memory data is copied during a swap --
// only the logical-to-physical die mapping changes.
//
// All command ports in this module are synchronous to clk.  valid must remain
// asserted until ready is observed.  done is a one-cycle response pulse.
//------------------------------------------------------------------------------
module psramSwitcher (
    input  wire        clk,
    input  wire        reset_n,

    // CPU single-word command port (back die).
    input  wire        cpu_valid,
    output wire        cpu_ready,
    // High from the first halfword of one CPU load/store until its final
    // halfword completes.  A frame boundary may not split that sequence.
    input  wire        cpu_sequence_active,
    input  wire        cpu_wr,
    input  wire [21:0] cpu_addr,
    input  wire [ 1:0] cpu_mask,
    input  wire [15:0] cpu_wdata,
    output reg  [15:0] cpu_rdata,
    output reg         cpu_done,

    // Future GPU single-word command port (back die).  It has priority over
    // the CPU at command boundaries; an accepted CPU transaction is never
    // pre-empted halfway through.
    input  wire        gpu_valid,
    output wire        gpu_ready,
    input  wire        gpu_wr,
    input  wire [21:0] gpu_addr,
    input  wire [ 1:0] gpu_mask,
    input  wire [15:0] gpu_wdata,
    output reg  [15:0] gpu_rdata,
    output reg         gpu_done,

    // Future HDMI read port (front die).  A burst reader can be placed above
    // this port later; for now it is a 16-bit transaction placeholder.
    input  wire        hdmi_valid,
    output wire        hdmi_ready,
    input  wire [21:0] hdmi_addr,
    output reg  [15:0] hdmi_rdata,
    output reg         hdmi_done,

    // Bank swap handshake.  frame_done_pulse must already be synchronized to
    // clk.  swap_request_hdmi remains high until the requested swap commits.
    input  wire        swap_request_pulse,
    input  wire        frame_done_pulse,
    output wire        swap_request_hdmi,
    output reg         swap_pending,
    output reg         swap_done_toggle,
    output reg  [15:0] swap_count,
    output reg         front_die,
    output wire        back_die,

    output wire        any_busy,
    output wire        gpu_active,
    output wire        hdmi_active,

    // Physical die 0 command port.
    output reg         phy0_start,
    output reg         phy0_wr,
    output reg  [21:0] phy0_addr,
    output reg  [ 1:0] phy0_mask,
    output reg  [15:0] phy0_wdata,
    input  wire [15:0] phy0_rdata,
    input  wire        phy0_busy,
    input  wire        phy0_done,
    input  wire        phy0_init_done,

    // Physical die 1 command port.
    output reg         phy1_start,
    output reg         phy1_wr,
    output reg  [21:0] phy1_addr,
    output reg  [ 1:0] phy1_mask,
    output reg  [15:0] phy1_wdata,
    input  wire [15:0] phy1_rdata,
    input  wire        phy1_busy,
    input  wire        phy1_done,
    input  wire        phy1_init_done
);
    localparam [1:0] OWNER_NONE = 2'd0,
                     OWNER_CPU  = 2'd1,
                     OWNER_GPU  = 2'd2,
                     OWNER_HDMI = 2'd3;

    reg       active0;
    reg       active1;
    reg [1:0] owner0;
    reg [1:0] owner1;
    reg       swapBarrier;

    assign back_die = ~front_die;
    assign swap_request_hdmi = swap_pending;

    wire bothInitialized = phy0_init_done && phy1_init_done;
    wire die0Free = !active0 && !phy0_busy;
    wire die1Free = !active1 && !phy1_busy;
    wire frontFree = front_die ? die1Free : die0Free;
    wire backFree  = front_die ? die0Free : die1Free;

    // Stop accepting commands as soon as a requested frame boundary arrives.
    // Existing transactions drain, then the mapping flips atomically.
    wire frameStartsBarrier = frame_done_pulse &&
                              (swap_pending || swap_request_pulse);
    wire barrierActive = swapBarrier || frameStartsBarrier;
    wire acceptEnabled = bothInitialized && !barrierActive;

    assign hdmi_ready = acceptEnabled && frontFree;
    assign gpu_ready  = acceptEnabled && backFree;
    // Once a CPU 32-bit sequence has started, allow its second halfword
    // through an armed barrier.  GPU cannot steal that continuation.
    assign cpu_ready  = bothInitialized && backFree &&
                        ((acceptEnabled && !gpu_valid) ||
                         (barrierActive && cpu_sequence_active));

    assign any_busy = active0 || active1 || phy0_busy || phy1_busy ||
                      swapBarrier;
    assign gpu_active = (active0 && owner0 == OWNER_GPU) ||
                        (active1 && owner1 == OWNER_GPU);
    assign hdmi_active = (active0 && owner0 == OWNER_HDMI) ||
                         (active1 && owner1 == OWNER_HDMI);

    always @(posedge clk) begin
        phy0_start <= 1'b0;
        phy1_start <= 1'b0;
        cpu_done   <= 1'b0;
        gpu_done   <= 1'b0;
        hdmi_done  <= 1'b0;

        if (!reset_n) begin
            // Start with the CPU/GPU back side on die 0 and HDMI front on die 1.
            front_die         <= 1'b1;
            swap_pending      <= 1'b0;
            swapBarrier       <= 1'b0;
            swap_done_toggle  <= 1'b0;
            swap_count        <= 16'd0;
            active0           <= 1'b0;
            active1           <= 1'b0;
            owner0            <= OWNER_NONE;
            owner1            <= OWNER_NONE;
            phy0_start        <= 1'b0;
            phy0_wr           <= 1'b0;
            phy0_addr         <= 22'd0;
            phy0_mask         <= 2'b11;
            phy0_wdata        <= 16'd0;
            phy1_start        <= 1'b0;
            phy1_wr           <= 1'b0;
            phy1_addr         <= 22'd0;
            phy1_mask         <= 2'b11;
            phy1_wdata        <= 16'd0;
            cpu_rdata         <= 16'd0;
            gpu_rdata         <= 16'd0;
            hdmi_rdata        <= 16'd0;
            cpu_done          <= 1'b0;
            gpu_done          <= 1'b0;
            hdmi_done         <= 1'b0;
        end else begin
            if (swap_request_pulse)
                swap_pending <= 1'b1;

            if (frameStartsBarrier)
                swapBarrier <= 1'b1;

            // Route completed physical transactions back to the client that
            // owned that die when the command was accepted.
            if (active0 && phy0_done) begin
                case (owner0)
                    OWNER_CPU: begin cpu_rdata <= phy0_rdata; cpu_done <= 1'b1; end
                    OWNER_GPU: begin gpu_rdata <= phy0_rdata; gpu_done <= 1'b1; end
                    OWNER_HDMI: begin hdmi_rdata <= phy0_rdata; hdmi_done <= 1'b1; end
                    default: begin end
                endcase
                active0 <= 1'b0;
                owner0  <= OWNER_NONE;
            end

            if (active1 && phy1_done) begin
                case (owner1)
                    OWNER_CPU: begin cpu_rdata <= phy1_rdata; cpu_done <= 1'b1; end
                    OWNER_GPU: begin gpu_rdata <= phy1_rdata; gpu_done <= 1'b1; end
                    OWNER_HDMI: begin hdmi_rdata <= phy1_rdata; hdmi_done <= 1'b1; end
                    default: begin end
                endcase
                active1 <= 1'b0;
                owner1  <= OWNER_NONE;
            end

            // HDMI and the CPU/GPU side always target opposite dies, so one
            // command from each side may be accepted in the same clock cycle.
            if (hdmi_valid && hdmi_ready) begin
                if (front_die) begin
                    phy1_start <= 1'b1;
                    phy1_wr    <= 1'b0;
                    phy1_addr  <= hdmi_addr;
                    phy1_mask  <= 2'b11;
                    phy1_wdata <= 16'd0;
                    active1    <= 1'b1;
                    owner1     <= OWNER_HDMI;
                end else begin
                    phy0_start <= 1'b1;
                    phy0_wr    <= 1'b0;
                    phy0_addr  <= hdmi_addr;
                    phy0_mask  <= 2'b11;
                    phy0_wdata <= 16'd0;
                    active0    <= 1'b1;
                    owner0     <= OWNER_HDMI;
                end
            end

            if (gpu_valid && gpu_ready) begin
                if (back_die) begin
                    phy1_start <= 1'b1;
                    phy1_wr    <= gpu_wr;
                    phy1_addr  <= gpu_addr;
                    phy1_mask  <= gpu_mask;
                    phy1_wdata <= gpu_wdata;
                    active1    <= 1'b1;
                    owner1     <= OWNER_GPU;
                end else begin
                    phy0_start <= 1'b1;
                    phy0_wr    <= gpu_wr;
                    phy0_addr  <= gpu_addr;
                    phy0_mask  <= gpu_mask;
                    phy0_wdata <= gpu_wdata;
                    active0    <= 1'b1;
                    owner0     <= OWNER_GPU;
                end
            end else if (cpu_valid && cpu_ready) begin
                if (back_die) begin
                    phy1_start <= 1'b1;
                    phy1_wr    <= cpu_wr;
                    phy1_addr  <= cpu_addr;
                    phy1_mask  <= cpu_mask;
                    phy1_wdata <= cpu_wdata;
                    active1    <= 1'b1;
                    owner1     <= OWNER_CPU;
                end else begin
                    phy0_start <= 1'b1;
                    phy0_wr    <= cpu_wr;
                    phy0_addr  <= cpu_addr;
                    phy0_mask  <= cpu_mask;
                    phy0_wdata <= cpu_wdata;
                    active0    <= 1'b1;
                    owner0     <= OWNER_CPU;
                end
            end

            // The barrier prevents new work.  Wait for both accepted commands
            // and both PHYs to become idle before changing ownership.
            if (swapBarrier && !cpu_sequence_active && die0Free && die1Free) begin
                front_die        <= ~front_die;
                swap_pending     <= 1'b0;
                swapBarrier      <= 1'b0;
                swap_done_toggle <= ~swap_done_toggle;
                swap_count       <= swap_count + 16'd1;
            end
        end
    end
endmodule

`default_nettype wire
