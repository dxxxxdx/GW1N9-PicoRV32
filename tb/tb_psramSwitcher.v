`timescale 1ns / 1ps

module tb_psramSwitcher;
    reg clk = 1'b0;
    reg reset_n = 1'b0;
    always #5 clk = ~clk;

    reg cpu_valid = 1'b0;
    wire cpu_ready;
    reg cpu_sequence_active = 1'b0;
    reg cpu_wr = 1'b0;
    reg [21:0] cpu_addr = 22'd0;
    reg [1:0] cpu_mask = 2'b11;
    reg [15:0] cpu_wdata = 16'd0;
    wire [15:0] cpu_rdata;
    wire cpu_done;

    reg gpu_valid = 1'b0;
    wire gpu_ready;
    reg gpu_wr = 1'b0;
    reg [21:0] gpu_addr = 22'd0;
    reg [1:0] gpu_mask = 2'b11;
    reg [15:0] gpu_wdata = 16'd0;
    wire [15:0] gpu_rdata;
    wire gpu_done;

    reg hdmi_valid = 1'b0;
    wire hdmi_ready;
    reg [21:0] hdmi_addr = 22'd0;
    wire [15:0] hdmi_rdata;
    wire hdmi_done;

    reg swap_request_pulse = 1'b0;
    reg frame_done_pulse = 1'b0;
    wire swap_request_hdmi;
    wire swap_pending;
    wire swap_done_toggle;
    wire [15:0] swap_count;
    wire front_die;
    wire back_die;
    wire any_busy;
    wire gpu_active;
    wire hdmi_active;

    wire phy0_start, phy0_wr;
    wire [21:0] phy0_addr;
    wire [1:0] phy0_mask;
    wire [15:0] phy0_wdata;
    reg [15:0] phy0_rdata = 16'h0010;
    reg phy0_busy = 1'b0;
    reg phy0_done = 1'b0;

    wire phy1_start, phy1_wr;
    wire [21:0] phy1_addr;
    wire [1:0] phy1_mask;
    wire [15:0] phy1_wdata;
    reg [15:0] phy1_rdata = 16'h1010;
    reg phy1_busy = 1'b0;
    reg phy1_done = 1'b0;

    psramSwitcher dut (
        .clk(clk), .reset_n(reset_n),
        .cpu_valid(cpu_valid), .cpu_ready(cpu_ready),
        .cpu_sequence_active(cpu_sequence_active), .cpu_wr(cpu_wr),
        .cpu_addr(cpu_addr), .cpu_mask(cpu_mask), .cpu_wdata(cpu_wdata),
        .cpu_rdata(cpu_rdata), .cpu_done(cpu_done),
        .gpu_valid(gpu_valid), .gpu_ready(gpu_ready), .gpu_wr(gpu_wr),
        .gpu_addr(gpu_addr), .gpu_mask(gpu_mask), .gpu_wdata(gpu_wdata),
        .gpu_rdata(gpu_rdata), .gpu_done(gpu_done),
        .hdmi_valid(hdmi_valid), .hdmi_ready(hdmi_ready),
        .hdmi_addr(hdmi_addr), .hdmi_rdata(hdmi_rdata),
        .hdmi_done(hdmi_done),
        .swap_request_pulse(swap_request_pulse),
        .frame_done_pulse(frame_done_pulse),
        .swap_request_hdmi(swap_request_hdmi),
        .swap_pending(swap_pending), .swap_done_toggle(swap_done_toggle),
        .swap_count(swap_count), .front_die(front_die), .back_die(back_die),
        .any_busy(any_busy), .gpu_active(gpu_active),
        .hdmi_active(hdmi_active),
        .phy0_start(phy0_start), .phy0_wr(phy0_wr),
        .phy0_addr(phy0_addr), .phy0_mask(phy0_mask),
        .phy0_wdata(phy0_wdata), .phy0_rdata(phy0_rdata),
        .phy0_busy(phy0_busy), .phy0_done(phy0_done),
        .phy0_init_done(1'b1),
        .phy1_start(phy1_start), .phy1_wr(phy1_wr),
        .phy1_addr(phy1_addr), .phy1_mask(phy1_mask),
        .phy1_wdata(phy1_wdata), .phy1_rdata(phy1_rdata),
        .phy1_busy(phy1_busy), .phy1_done(phy1_done),
        .phy1_init_done(1'b1)
    );

    task pulse_done0;
        input [15:0] data;
        begin
            @(negedge clk);
            phy0_rdata = data;
            phy0_done = 1'b1;
            @(negedge clk);
            phy0_done = 1'b0;
        end
    endtask

    task pulse_done1;
        input [15:0] data;
        begin
            @(negedge clk);
            phy1_rdata = data;
            phy1_done = 1'b1;
            @(negedge clk);
            phy1_done = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        reset_n = 1'b1;
        repeat (2) @(negedge clk);

        if (front_die !== 1'b1 || back_die !== 1'b0)
            $fatal(1, "reset ownership is not front=die1/back=die0");

        // GPU wins if CPU and GPU request the back die together.
        cpu_valid = 1'b1;
        cpu_wr = 1'b1;
        cpu_addr = 22'h000100;
        cpu_wdata = 16'hc0c0;
        gpu_valid = 1'b1;
        gpu_wr = 1'b1;
        gpu_addr = 22'h000200;
        gpu_wdata = 16'h6a6a;
        #1;
        if (!gpu_ready || cpu_ready)
            $fatal(1, "GPU priority over CPU was not enforced");
        @(negedge clk);
        cpu_valid = 1'b0;
        gpu_valid = 1'b0;
        if (!phy0_start || phy0_addr !== 22'h000200 ||
            phy0_wdata !== 16'h6a6a || !gpu_active)
            $fatal(1, "GPU command did not route to back die0");
        pulse_done0(16'h600d);
        if (!gpu_done || gpu_rdata !== 16'h600d || cpu_done)
            $fatal(1, "GPU completion routed to wrong owner");

        // CPU back and HDMI front can launch concurrently on opposite dies.
        @(negedge clk);
        cpu_valid = 1'b1;
        cpu_wr = 1'b0;
        cpu_addr = 22'h000300;
        hdmi_valid = 1'b1;
        hdmi_addr = 22'h000400;
        #1;
        if (!cpu_ready || !hdmi_ready)
            $fatal(1, "opposite logical sides did not accept concurrently");
        @(negedge clk);
        cpu_valid = 1'b0;
        hdmi_valid = 1'b0;
        if (!phy0_start || phy0_addr !== 22'h000300 ||
            !phy1_start || phy1_addr !== 22'h000400)
            $fatal(1, "front/back commands reached the wrong physical dies");

        // Complete both physical transactions together.
        phy0_rdata = 16'hcafe;
        phy1_rdata = 16'hbeef;
        phy0_done = 1'b1;
        phy1_done = 1'b1;
        @(negedge clk);
        phy0_done = 1'b0;
        phy1_done = 1'b0;
        if (!cpu_done || cpu_rdata !== 16'hcafe ||
            !hdmi_done || hdmi_rdata !== 16'hbeef)
            $fatal(1, "concurrent completion routing failed");

        // A request remains pending until a frame boundary arrives.
        swap_request_pulse = 1'b1;
        @(negedge clk);
        swap_request_pulse = 1'b0;
        repeat (2) @(negedge clk);
        if (!swap_pending || !swap_request_hdmi || front_die !== 1'b1)
            $fatal(1, "swap did not remain pending");
        frame_done_pulse = 1'b1;
        @(negedge clk);
        frame_done_pulse = 1'b0;
        repeat (2) @(negedge clk);
        if (front_die !== 1'b0 || back_die !== 1'b1 ||
            swap_pending || swap_count !== 16'd1)
            $fatal(1, "frame-boundary swap did not flip ownership");

        // After the swap, the same logical clients route to opposite PHYs.
        cpu_valid = 1'b1;
        cpu_addr = 22'h000500;
        hdmi_valid = 1'b1;
        hdmi_addr = 22'h000600;
        @(negedge clk);
        cpu_valid = 1'b0;
        hdmi_valid = 1'b0;
        if (!phy1_start || phy1_addr !== 22'h000500 ||
            !phy0_start || phy0_addr !== 22'h000600)
            $fatal(1, "post-swap routing failed");

        pulse_done0(16'h0f00);
        pulse_done1(16'h1b00);

        // A frame boundary between the two halfwords of one CPU access must
        // drain that logical sequence before ownership changes.
        @(negedge clk);
        cpu_sequence_active = 1'b1;
        cpu_valid = 1'b1;
        cpu_addr = 22'h000700;
        @(negedge clk);
        cpu_valid = 1'b0;
        if (!phy1_start)
            $fatal(1, "first halfword of locked CPU sequence was not accepted");

        swap_request_pulse = 1'b1;
        frame_done_pulse = 1'b1;
        @(negedge clk);
        swap_request_pulse = 1'b0;
        frame_done_pulse = 1'b0;
        repeat (2) @(negedge clk);
        if (front_die !== 1'b0 || swap_count !== 16'd1 || !swap_pending)
            $fatal(1, "swap split an active CPU logical transaction");

        pulse_done1(16'h1700);
        @(negedge clk);
        cpu_valid = 1'b1;
        cpu_addr = 22'h000702;
        #1;
        if (!cpu_ready || gpu_ready || hdmi_ready)
            $fatal(1, "barrier did not admit only the CPU continuation");
        @(negedge clk);
        cpu_valid = 1'b0;
        if (!phy1_start || phy1_addr !== 22'h000702)
            $fatal(1, "CPU continuation changed physical die");
        pulse_done1(16'h1702);
        cpu_sequence_active = 1'b0;
        repeat (3) @(negedge clk);
        if (front_die !== 1'b1 || back_die !== 1'b0 ||
            swap_count !== 16'd2 || swap_pending)
            $fatal(1, "swap did not commit after CPU sequence drained");

        $display("PASS: GPU priority, concurrent access and atomic die swap");
        $finish;
    end
endmodule
