`timescale 1ns / 1ps

module tb_psramSwitcher;
    reg clk = 1'b0;
    reg reset_n = 1'b0;
    always #5 clk = ~clk;

    reg cpu_cmd_valid = 1'b0;
    wire cpu_cmd_ready;
    reg cpu_cmd_wr = 1'b0;
    reg [21:0] cpu_cmd_addr = 22'd0;
    reg [6:0] cpu_cmd_words = 7'd2;
    reg [15:0] cpu_w_data = 16'd0;
    reg [1:0] cpu_w_mask = 2'b11;
    wire cpu_w_take;
    wire [15:0] cpu_r_data;
    wire cpu_r_valid, cpu_r_last, cpu_done;

    reg gpu_cmd_valid = 1'b0;
    wire gpu_cmd_ready;
    reg gpu_cmd_wr = 1'b0;
    reg [21:0] gpu_cmd_addr = 22'd0;
    reg [6:0] gpu_cmd_words = 7'd1;
    reg [15:0] gpu_w_data = 16'd0;
    reg [1:0] gpu_w_mask = 2'b11;
    wire gpu_w_take;
    wire [15:0] gpu_r_data;
    wire gpu_r_valid, gpu_r_last, gpu_done;

    reg hdmi_cmd_valid = 1'b0;
    wire hdmi_cmd_ready;
    reg [21:0] hdmi_cmd_addr = 22'd0;
    reg [6:0] hdmi_cmd_words = 7'd1;
    wire [15:0] hdmi_r_data;
    wire hdmi_r_valid, hdmi_r_last, hdmi_done;

    reg swap_request_pulse = 1'b0;
    reg frame_done_pulse = 1'b0;
    wire swap_request_hdmi, swap_pending, swap_done_toggle;
    wire [15:0] swap_count;
    wire front_die, back_die, any_busy, gpu_active, hdmi_active;

    wire phy0_cmd_valid, phy0_cmd_ready, phy0_cmd_wr;
    wire [21:0] phy0_cmd_addr;
    wire [6:0] phy0_cmd_words;
    wire [15:0] phy0_w_data;
    wire [1:0] phy0_w_mask;
    reg phy0_w_take = 1'b0;
    reg [15:0] phy0_r_data = 16'h0010;
    reg phy0_r_valid = 1'b0;
    reg phy0_r_last = 1'b0;
    reg phy0_busy = 1'b0;
    reg phy0_done = 1'b0;

    wire phy1_cmd_valid, phy1_cmd_ready, phy1_cmd_wr;
    wire [21:0] phy1_cmd_addr;
    wire [6:0] phy1_cmd_words;
    wire [15:0] phy1_w_data;
    wire [1:0] phy1_w_mask;
    reg phy1_w_take = 1'b0;
    reg [15:0] phy1_r_data = 16'h1010;
    reg phy1_r_valid = 1'b0;
    reg phy1_r_last = 1'b0;
    reg phy1_busy = 1'b0;
    reg phy1_done = 1'b0;

    assign phy0_cmd_ready = !phy0_busy;
    assign phy1_cmd_ready = !phy1_busy;

    always @(posedge clk) begin
        if (!reset_n) begin
            phy0_busy <= 1'b0;
            phy1_busy <= 1'b0;
        end else begin
            if (phy0_cmd_valid && phy0_cmd_ready) phy0_busy <= 1'b1;
            if (phy1_cmd_valid && phy1_cmd_ready) phy1_busy <= 1'b1;
            if (phy0_done) phy0_busy <= 1'b0;
            if (phy1_done) phy1_busy <= 1'b0;
        end
    end

    psramSwitcher dut (
        .clk(clk), .reset_n(reset_n),
        .cpu_cmd_valid(cpu_cmd_valid), .cpu_cmd_ready(cpu_cmd_ready),
        .cpu_cmd_wr(cpu_cmd_wr), .cpu_cmd_addr(cpu_cmd_addr),
        .cpu_cmd_words(cpu_cmd_words), .cpu_w_data(cpu_w_data),
        .cpu_w_mask(cpu_w_mask), .cpu_w_take(cpu_w_take),
        .cpu_r_data(cpu_r_data), .cpu_r_valid(cpu_r_valid),
        .cpu_r_last(cpu_r_last), .cpu_done(cpu_done),
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
        .swap_request_pulse(swap_request_pulse),
        .frame_done_pulse(frame_done_pulse),
        .swap_request_hdmi(swap_request_hdmi),
        .swap_pending(swap_pending), .swap_done_toggle(swap_done_toggle),
        .swap_count(swap_count), .front_die(front_die), .back_die(back_die),
        .any_busy(any_busy), .gpu_active(gpu_active), .hdmi_active(hdmi_active),
        .phy0_cmd_valid(phy0_cmd_valid), .phy0_cmd_ready(phy0_cmd_ready),
        .phy0_cmd_wr(phy0_cmd_wr), .phy0_cmd_addr(phy0_cmd_addr),
        .phy0_cmd_words(phy0_cmd_words), .phy0_w_data(phy0_w_data),
        .phy0_w_mask(phy0_w_mask), .phy0_w_take(phy0_w_take),
        .phy0_r_data(phy0_r_data), .phy0_r_valid(phy0_r_valid),
        .phy0_r_last(phy0_r_last), .phy0_busy(phy0_busy),
        .phy0_done(phy0_done), .phy0_init_done(1'b1),
        .phy1_cmd_valid(phy1_cmd_valid), .phy1_cmd_ready(phy1_cmd_ready),
        .phy1_cmd_wr(phy1_cmd_wr), .phy1_cmd_addr(phy1_cmd_addr),
        .phy1_cmd_words(phy1_cmd_words), .phy1_w_data(phy1_w_data),
        .phy1_w_mask(phy1_w_mask), .phy1_w_take(phy1_w_take),
        .phy1_r_data(phy1_r_data), .phy1_r_valid(phy1_r_valid),
        .phy1_r_last(phy1_r_last), .phy1_busy(phy1_busy),
        .phy1_done(phy1_done), .phy1_init_done(1'b1)
    );

    task finish0;
        begin
            @(negedge clk);
            phy0_done = 1'b1;
            @(negedge clk);
            phy0_done = 1'b0;
        end
    endtask

    task finish1;
        begin
            @(negedge clk);
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

        // GPU wins at the back-die command boundary and may request 64 beats.
        cpu_cmd_valid = 1'b1;
        cpu_cmd_wr = 1'b1;
        cpu_cmd_addr = 22'h000100;
        gpu_cmd_valid = 1'b1;
        gpu_cmd_wr = 1'b1;
        gpu_cmd_addr = 22'h000200;
        gpu_cmd_words = 7'd64;
        gpu_w_data = 16'h6a6a;
        gpu_w_mask = 2'b00;
        #1;
        if (!gpu_cmd_ready || cpu_cmd_ready || !phy0_cmd_valid ||
            phy0_cmd_addr !== 22'h000200 || phy0_cmd_words !== 7'd64)
            $fatal(1, "GPU priority/burst command routing failed");
        @(negedge clk);
        cpu_cmd_valid = 1'b0;
        gpu_cmd_valid = 1'b0;
        if (!gpu_active)
            $fatal(1, "GPU did not retain ownership for its burst");
        phy0_w_take = 1'b1;
        #1;
        if (!gpu_w_take || cpu_w_take || phy0_w_data !== 16'h6a6a ||
            phy0_w_mask !== 2'b00)
            $fatal(1, "GPU write beat did not stream to die0");
        phy0_w_take = 1'b0;
        finish0();

        // CPU back and HDMI front launch concurrently on opposite physical dies.
        @(negedge clk);
        cpu_cmd_valid = 1'b1;
        cpu_cmd_wr = 1'b0;
        cpu_cmd_addr = 22'h000300;
        cpu_cmd_words = 7'd2;
        hdmi_cmd_valid = 1'b1;
        hdmi_cmd_addr = 22'h000400;
        hdmi_cmd_words = 7'd64;
        #1;
        if (!cpu_cmd_ready || !hdmi_cmd_ready || !phy0_cmd_valid ||
            !phy1_cmd_valid || phy0_cmd_words !== 7'd2 ||
            phy1_cmd_words !== 7'd64)
            $fatal(1, "concurrent front/back burst launch failed");
        @(negedge clk);
        cpu_cmd_valid = 1'b0;
        hdmi_cmd_valid = 1'b0;

        phy0_r_data = 16'hcafe;
        phy0_r_valid = 1'b1;
        phy1_r_data = 16'hbeef;
        phy1_r_valid = 1'b1;
        #1;
        if (!cpu_r_valid || cpu_r_data !== 16'hcafe ||
            !hdmi_r_valid || hdmi_r_data !== 16'hbeef)
            $fatal(1, "concurrent read-beat routing failed");
        phy0_r_valid = 1'b0;
        phy1_r_valid = 1'b0;
        fork
            finish0();
            finish1();
        join

        // A frame boundary arms a barrier but cannot cut an active GPU burst.
        @(negedge clk);
        gpu_cmd_valid = 1'b1;
        gpu_cmd_wr = 1'b1;
        gpu_cmd_addr = 22'h000700;
        gpu_cmd_words = 7'd64;
        #1;
        if (!gpu_cmd_ready || !phy0_cmd_valid)
            $fatal(1, "long GPU burst was not accepted");
        @(negedge clk);
        gpu_cmd_valid = 1'b0;
        swap_request_pulse = 1'b1;
        frame_done_pulse = 1'b1;
        @(negedge clk);
        swap_request_pulse = 1'b0;
        frame_done_pulse = 1'b0;
        repeat (2) @(negedge clk);
        if (front_die !== 1'b1 || swap_count !== 16'd0 || !swap_pending ||
            cpu_cmd_ready || gpu_cmd_ready || hdmi_cmd_ready)
            $fatal(1, "swap barrier cut an active burst or admitted new work");

        finish0();
        repeat (3) @(negedge clk);
        if (front_die !== 1'b0 || back_die !== 1'b1 ||
            swap_count !== 16'd1 || swap_pending)
            $fatal(1, "swap did not commit after burst drained");

        $display("PASS: burst routing, GPU priority, concurrency and atomic swap");
        $finish;
    end
endmodule
