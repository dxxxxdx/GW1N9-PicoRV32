`timescale 1ns / 1ps

module tb_rectangleGpu;
    reg clk = 1'b0;
    reg phy_clk = 1'b0;
    reg reset_n = 1'b0;
    always #10 clk = ~clk;
    always #5 phy_clk = ~phy_clk;

    reg mmio_valid = 1'b0;
    wire mmio_ready;
    reg [11:0] mmio_addr = 12'd0;
    reg [31:0] mmio_wdata = 32'd0;
    reg [3:0] mmio_wstrb = 4'd0;
    wire [31:0] mmio_rdata;

    wire cmd_valid;
    wire job_busy;
    reg cmd_ready = 1'b1;
    wire cmd_wr;
    wire [21:0] cmd_addr;
    wire [6:0] cmd_words;
    wire [15:0] w_data;
    wire [1:0] w_mask;
    reg w_take = 1'b0;
    reg done = 1'b0;

    integer commandCount = 0;
    reg [21:0] loggedAddr [0:15];
    reg [6:0] loggedWords [0:15];
    reg [6:0] beatsLeft = 0;
    reg active = 1'b0;

    rectangleGpu dut (
        .clk(clk), .phy_clk(phy_clk), .reset_n(reset_n),
        .mmio_valid(mmio_valid), .mmio_ready(mmio_ready),
        .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata),
        .mmio_wstrb(mmio_wstrb), .mmio_rdata(mmio_rdata),
        .gpu_job_busy(job_busy),
        .gpu_cmd_valid(cmd_valid), .gpu_cmd_ready(cmd_ready),
        .gpu_cmd_wr(cmd_wr), .gpu_cmd_addr(cmd_addr),
        .gpu_cmd_words(cmd_words), .gpu_w_data(w_data),
        .gpu_w_mask(w_mask), .gpu_w_take(w_take), .gpu_done(done)
    );

    always @(posedge phy_clk) begin
        done <= 1'b0;
        w_take <= 1'b0;
        if (cmd_valid && cmd_ready) begin
            loggedAddr[commandCount] <= cmd_addr;
            loggedWords[commandCount] <= cmd_words;
            commandCount <= commandCount + 1;
            beatsLeft <= cmd_words;
            active <= 1'b1;
            if (!cmd_wr || w_mask !== 2'b00)
                $fatal(1, "GPU command is not an unmasked write");
        end else if (active) begin
            w_take <= 1'b1;
            if (w_data !== 16'hf81f && commandCount <= 6)
                $fatal(1, "rectangle color changed inside burst: %04x", w_data);
            if (beatsLeft == 7'd1) begin
                active <= 1'b0;
                beatsLeft <= 7'd0;
                done <= 1'b1;
            end else begin
                beatsLeft <= beatsLeft - 7'd1;
            end
        end
    end

    task write_reg;
        input [11:0] addr;
        input [31:0] value;
        begin
            @(negedge clk);
            mmio_addr = addr;
            mmio_wdata = value;
            mmio_wstrb = 4'hf;
            mmio_valid = 1'b1;
            while (!mmio_ready) @(negedge clk);
            mmio_valid = 1'b0;
            mmio_wstrb = 4'd0;
            @(negedge clk);
        end
    endtask

    task start_rect;
        input [15:0] x, y, width, height, color;
        begin
            write_reg(12'h008, x);
            write_reg(12'h00c, y);
            write_reg(12'h010, width);
            write_reg(12'h014, height);
            write_reg(12'h018, color);
            write_reg(12'h01c, 32'd1);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        reset_n = 1'b1;
        repeat (4) @(negedge clk);

        if (mmio_rdata !== 32'h4750_5531)
            $fatal(1, "GPU magic mismatch");

        start_rect(16'd10, 16'd3, 16'd130, 16'd2, 16'hf81f);
        if (!dut.cpuBusy)
            $fatal(1, "busy was not visible immediately after START");

        // Busy writes are acknowledged but must not mutate the staged command
        // or queue a second START.
        write_reg(12'h008, 16'd222);
        write_reg(12'h00c, 16'd111);
        write_reg(12'h018, 16'h07e0);
        write_reg(12'h01c, 32'd1);
        if (dut.xReg !== 16'd10 || dut.yReg !== 16'd3 ||
            dut.colorReg !== 16'hf81f)
            $fatal(1, "busy MMIO write changed GPU parameters");
        wait (dut.completionCount == 16'd1);
        repeat (2) @(negedge clk);
        if (dut.completionCount !== 16'd1 || job_busy)
            $fatal(1, "busy START was queued or job busy did not clear");
        if (commandCount != 6)
            $fatal(1, "130x2 rectangle used %0d commands, expected 6", commandCount);
        if (loggedAddr[0] !== 22'd3860 || loggedWords[0] !== 7'd54 ||
            loggedAddr[1] !== 22'd3968 || loggedWords[1] !== 7'd64 ||
            loggedAddr[2] !== 22'd4096 || loggedWords[2] !== 7'd12 ||
            loggedAddr[3] !== 22'd5140 || loggedWords[3] !== 7'd54 ||
            loggedAddr[4] !== 22'd5248 || loggedWords[4] !== 7'd64 ||
            loggedAddr[5] !== 22'd5376 || loggedWords[5] !== 7'd12)
            $fatal(1, "128-byte boundary splitting/address generation failed");

        // Clip at the lower-right framebuffer edge: only two pixels survive.
        start_rect(16'd638, 16'd479, 16'd10, 16'd3, 16'hf81f);
        wait (dut.completionCount == 16'd2);
        if (commandCount != 7 || loggedAddr[6] !== 22'd614396 ||
            loggedWords[6] !== 7'd2)
            $fatal(1, "rectangle clipping failed");

        // Empty work still completes, without touching PSRAM.
        start_rect(16'd0, 16'd0, 16'd0, 16'd10, 16'hf81f);
        wait (dut.completionCount == 16'd3);
        if (commandCount != 7)
            $fatal(1, "zero-width rectangle emitted a command");

        $display("PASS: GPU busy-write rejection, clipping and 64-pixel bursts");
        $finish;
    end
endmodule
