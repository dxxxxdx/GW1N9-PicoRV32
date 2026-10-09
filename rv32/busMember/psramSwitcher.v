`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// Logical front/back-bank switch in front of two independent x8 burst PHYs.
//
// Commands contain 1..64 consecutive 16-bit beats.  Ownership is locked for
// the complete physical burst; arbitration and front/back remapping only happen
// at command boundaries.  Write clients advance their current low-16-bit beat
// on *_w_take.  Read beats cannot be back-pressured after command acceptance.
//
// HDMI exclusively owns the front die.  CPU and GPU share the back die, with
// GPU priority.  A frame swap drains both accepted bursts before atomically
// flipping the logical-to-physical mapping.
//------------------------------------------------------------------------------
module psramSwitcher (
    input  wire        clk,
    input  wire        reset_n,

    // CPU burst port (back die).
    input  wire        cpu_cmd_valid,
    output wire        cpu_cmd_ready,
    input  wire        cpu_cmd_wr,
    input  wire [21:0] cpu_cmd_addr,
    input  wire [ 6:0] cpu_cmd_words,
    input  wire [15:0] cpu_w_data,
    input  wire [ 1:0] cpu_w_mask,
    output wire        cpu_w_take,
    output wire [15:0] cpu_r_data,
    output wire        cpu_r_valid,
    output wire        cpu_r_last,
    output wire        cpu_done,

    // Future GPU burst port (back die), priority over CPU at command boundary.
    input  wire        gpu_cmd_valid,
    output wire        gpu_cmd_ready,
    input  wire        gpu_cmd_wr,
    input  wire [21:0] gpu_cmd_addr,
    input  wire [ 6:0] gpu_cmd_words,
    input  wire [15:0] gpu_w_data,
    input  wire [ 1:0] gpu_w_mask,
    input  wire        gpu_job_busy,
    output wire        gpu_w_take,
    output wire [15:0] gpu_r_data,
    output wire        gpu_r_valid,
    output wire        gpu_r_last,
    output wire        gpu_done,

    // Future HDMI read-burst port (front die).
    input  wire        hdmi_cmd_valid,
    output wire        hdmi_cmd_ready,
    input  wire [21:0] hdmi_cmd_addr,
    input  wire [ 6:0] hdmi_cmd_words,
    output wire [15:0] hdmi_r_data,
    output wire        hdmi_r_valid,
    output wire        hdmi_r_last,
    output wire        hdmi_done,

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

    // Physical die 0 burst port.
    output wire        phy0_cmd_valid,
    input  wire        phy0_cmd_ready,
    output wire        phy0_cmd_wr,
    output wire [21:0] phy0_cmd_addr,
    output wire [ 6:0] phy0_cmd_words,
    output reg  [15:0] phy0_w_data,
    output reg  [ 1:0] phy0_w_mask,
    input  wire        phy0_w_take,
    input  wire [15:0] phy0_r_data,
    input  wire        phy0_r_valid,
    input  wire        phy0_r_last,
    input  wire        phy0_busy,
    input  wire        phy0_done,
    input  wire        phy0_init_done,

    // Physical die 1 burst port.
    output wire        phy1_cmd_valid,
    input  wire        phy1_cmd_ready,
    output wire        phy1_cmd_wr,
    output wire [21:0] phy1_cmd_addr,
    output wire [ 6:0] phy1_cmd_words,
    output reg  [15:0] phy1_w_data,
    output reg  [ 1:0] phy1_w_mask,
    input  wire        phy1_w_take,
    input  wire [15:0] phy1_r_data,
    input  wire        phy1_r_valid,
    input  wire        phy1_r_last,
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
    // Logical-client busy flags duplicate the ownership lifetime without the
    // physical-die mux.  They keep client ready paths short enough for 80 MHz;
    // active0/1 remain the authority for response routing and swap drain.
    reg       frontBusy;
    reg       backBusy;
    reg [1:0] owner0;
    reg [1:0] owner1;
    reg       swapBarrier;

    assign back_die = ~front_die;
    assign swap_request_hdmi = swap_pending;

    wire bothInitialized = phy0_init_done && phy1_init_done;
    wire die0PipeFree = !phy0_busy && phy0_cmd_ready;
    wire die1PipeFree = !phy1_busy && phy1_cmd_ready;
    wire die0Drained = !active0 && die0PipeFree;
    wire die1Drained = !active1 && die1PipeFree;
    wire frontFree = !frontBusy &&
                     (front_die ? die1PipeFree : die0PipeFree);
    wire backFree  = !backBusy &&
                     (front_die ? die0PipeFree : die1PipeFree);

    wire frameStartsBarrier = frame_done_pulse &&
                              (swap_pending || swap_request_pulse);
    // A frame-done edge starts draining for a swap. CPU and HDMI stop issuing
    // new work, while an already-running GPU job may launch all of its later
    // bursts to the old back die. The mapping changes only after that whole
    // job and both physical transactions are finished.
    wire normalAcceptEnabled = bothInitialized && !swapBarrier;
    wire gpuAcceptEnabled = bothInitialized &&
                            (!swapBarrier || gpu_job_busy);

    assign hdmi_cmd_ready = normalAcceptEnabled && frontFree;
    assign gpu_cmd_ready  = gpuAcceptEnabled && backFree;
    assign cpu_cmd_ready  = normalAcceptEnabled && backFree && !gpu_cmd_valid;

    // Valid must not depend on ready.  Keeping the two sides independent cuts
    // the otherwise long PHY-state -> arbiter -> PHY-state combinational path
    // and follows the normal valid/ready contract: the chosen request remains
    // asserted until the target PHY accepts it.
    wire gpuBackCmdValid = gpuAcceptEnabled && gpu_cmd_valid;
    wire cpuBackCmdValid = normalAcceptEnabled && cpu_cmd_valid &&
                           !gpu_cmd_valid;
    wire backSelectGpu = gpuBackCmdValid;
    wire backCmdValid = gpuBackCmdValid || cpuBackCmdValid;
    wire backCmdWr = backSelectGpu ? gpu_cmd_wr : cpu_cmd_wr;
    wire [21:0] backCmdAddr = backSelectGpu ? gpu_cmd_addr : cpu_cmd_addr;
    wire [ 6:0] backCmdWords = backSelectGpu ? gpu_cmd_words : cpu_cmd_words;
    wire frontCmdValid = normalAcceptEnabled && hdmi_cmd_valid;

    // A physical command is a one-cycle valid/ready transfer.  Front and back
    // target opposite dies, so they may both launch in the same cycle.
    assign phy0_cmd_valid = front_die ? backCmdValid : frontCmdValid;
    assign phy0_cmd_wr    = front_die ? backCmdWr : 1'b0;
    assign phy0_cmd_addr  = front_die ? backCmdAddr : hdmi_cmd_addr;
    assign phy0_cmd_words = front_die ? backCmdWords : hdmi_cmd_words;

    assign phy1_cmd_valid = front_die ? frontCmdValid : backCmdValid;
    assign phy1_cmd_wr    = front_die ? 1'b0 : backCmdWr;
    assign phy1_cmd_addr  = front_die ? hdmi_cmd_addr : backCmdAddr;
    assign phy1_cmd_words = front_die ? hdmi_cmd_words : backCmdWords;

    assign any_busy = active0 || active1 || phy0_busy || phy1_busy ||
                      gpu_job_busy || swapBarrier;
    assign gpu_active = gpu_job_busy ||
                        (active0 && owner0 == OWNER_GPU) ||
                        (active1 && owner1 == OWNER_GPU);
    assign hdmi_active = (active0 && owner0 == OWNER_HDMI) ||
                         (active1 && owner1 == OWNER_HDMI);

    wire cpuOwns0 = active0 && owner0 == OWNER_CPU;
    wire cpuOwns1 = active1 && owner1 == OWNER_CPU;
    wire gpuOwns0 = active0 && owner0 == OWNER_GPU;
    wire gpuOwns1 = active1 && owner1 == OWNER_GPU;
    wire hdmiOwns0 = active0 && owner0 == OWNER_HDMI;
    wire hdmiOwns1 = active1 && owner1 == OWNER_HDMI;

    // Beat strobes are routed combinationally.  In particular, write clients
    // must see w_take on the exact edge at which the PHY consumes the current
    // word so they can present the next word without inserting a bubble.
    assign cpu_w_take = (cpuOwns0 && phy0_w_take) ||
                        (cpuOwns1 && phy1_w_take);
    assign cpu_r_data = cpuOwns0 ? phy0_r_data : phy1_r_data;
    assign cpu_r_valid = (cpuOwns0 && phy0_r_valid) ||
                         (cpuOwns1 && phy1_r_valid);
    assign cpu_r_last = (cpuOwns0 && phy0_r_last) ||
                        (cpuOwns1 && phy1_r_last);
    assign cpu_done = (cpuOwns0 && phy0_done) ||
                      (cpuOwns1 && phy1_done);

    assign gpu_w_take = (gpuOwns0 && phy0_w_take) ||
                        (gpuOwns1 && phy1_w_take);
    assign gpu_r_data = gpuOwns0 ? phy0_r_data : phy1_r_data;
    assign gpu_r_valid = (gpuOwns0 && phy0_r_valid) ||
                         (gpuOwns1 && phy1_r_valid);
    assign gpu_r_last = (gpuOwns0 && phy0_r_last) ||
                        (gpuOwns1 && phy1_r_last);
    assign gpu_done = (gpuOwns0 && phy0_done) ||
                      (gpuOwns1 && phy1_done);

    assign hdmi_r_data = hdmiOwns0 ? phy0_r_data : phy1_r_data;
    assign hdmi_r_valid = (hdmiOwns0 && phy0_r_valid) ||
                          (hdmiOwns1 && phy1_r_valid);
    assign hdmi_r_last = (hdmiOwns0 && phy0_r_last) ||
                         (hdmiOwns1 && phy1_r_last);
    assign hdmi_done = (hdmiOwns0 && phy0_done) ||
                       (hdmiOwns1 && phy1_done);

    // Stream write data from whichever client owns each physical die.
    always @* begin
        phy0_w_data = 16'd0;
        phy0_w_mask = 2'b11;
        case (owner0)
            OWNER_CPU: begin phy0_w_data = cpu_w_data; phy0_w_mask = cpu_w_mask; end
            OWNER_GPU: begin phy0_w_data = gpu_w_data; phy0_w_mask = gpu_w_mask; end
            default: begin end
        endcase

        phy1_w_data = 16'd0;
        phy1_w_mask = 2'b11;
        case (owner1)
            OWNER_CPU: begin phy1_w_data = cpu_w_data; phy1_w_mask = cpu_w_mask; end
            OWNER_GPU: begin phy1_w_data = gpu_w_data; phy1_w_mask = gpu_w_mask; end
            default: begin end
        endcase
    end

    always @(posedge clk) begin
        if (!reset_n) begin
            // CPU/GPU start on physical die 0; HDMI starts on physical die 1.
            front_die         <= 1'b1;
            swap_pending      <= 1'b0;
            swapBarrier       <= 1'b0;
            swap_done_toggle  <= 1'b0;
            swap_count        <= 16'd0;
            active0           <= 1'b0;
            active1           <= 1'b0;
            frontBusy         <= 1'b0;
            backBusy          <= 1'b0;
            owner0            <= OWNER_NONE;
            owner1            <= OWNER_NONE;
        end else begin
            if (swap_request_pulse)
                swap_pending <= 1'b1;
            if (frameStartsBarrier)
                swapBarrier <= 1'b1;

            if (phy0_cmd_valid && phy0_cmd_ready) begin
                active0 <= 1'b1;
                owner0 <= front_die ? (backSelectGpu ? OWNER_GPU : OWNER_CPU) :
                                      OWNER_HDMI;
            end
            if (phy1_cmd_valid && phy1_cmd_ready) begin
                active1 <= 1'b1;
                owner1 <= front_die ? OWNER_HDMI :
                                      (backSelectGpu ? OWNER_GPU : OWNER_CPU);
            end

            if (hdmi_cmd_valid && hdmi_cmd_ready)
                frontBusy <= 1'b1;
            if ((gpu_cmd_valid && gpu_cmd_ready) ||
                (cpu_cmd_valid && cpu_cmd_ready))
                backBusy <= 1'b1;

            if (active0 && phy0_done) begin
                active0 <= 1'b0;
                owner0 <= OWNER_NONE;
            end

            if (active1 && phy1_done) begin
                active1 <= 1'b0;
                owner1 <= OWNER_NONE;
            end


            if (hdmi_done)
                frontBusy <= 1'b0;
            if (gpu_done || cpu_done)
                backBusy <= 1'b0;

            if (swapBarrier && !gpu_job_busy && !frontBusy && !backBusy &&
                die0Drained && die1Drained) begin
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
