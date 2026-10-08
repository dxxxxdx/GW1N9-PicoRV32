`timescale 1ns / 1ps

// Minimal behavioral model for the Gowin semi-dual-port BSRAM primitive.
// ADA[1:0] are byte enables in 16-bit mode; addresses live in [13:4].
module SDPB #(
    parameter READ_MODE = 1'b0,
    parameter BIT_WIDTH_0 = 32,
    parameter BIT_WIDTH_1 = 32,
    parameter [2:0] BLK_SEL_0 = 3'b000,
    parameter [2:0] BLK_SEL_1 = 3'b000,
    parameter RESET_MODE = "SYNC"
) (
    output reg [31:0] DO,
    input wire [31:0] DI,
    input wire [2:0] BLKSELA, BLKSELB,
    input wire [13:0] ADA, ADB,
    input wire CLKA, CLKB, CEA, CEB, OCE, RESETA, RESETB
);
    reg [15:0] memory [0:1023];
    always @(posedge CLKA) begin
        if (CEA && BLKSELA == BLK_SEL_0) begin
            if (ADA[0]) memory[ADA[13:4]][7:0] <= DI[7:0];
            if (ADA[1]) memory[ADA[13:4]][15:8] <= DI[15:8];
        end
    end
    always @(posedge CLKB) begin
        if (RESETB)
            DO <= 32'd0;
        else if (CEB && OCE && BLKSELB == BLK_SEL_1)
            DO <= {16'd0, memory[ADB[13:4]]};
    end
    wire unused = READ_MODE ^ RESETA ^ (BIT_WIDTH_0 == BIT_WIDTH_1) ^
                  (RESET_MODE == "SYNC");
endmodule

module tb_psramHdmiReader;
    reg phy_clk = 1'b0;
    reg pixel_clk = 1'b0;
    reg reset_n = 1'b0;
    always #5 phy_clk = ~phy_clk;
    always #13 pixel_clk = ~pixel_clk;

    wire cmd_valid;
    reg cmd_ready = 1'b1;
    wire [21:0] cmd_addr;
    wire [6:0] cmd_words;
    reg [15:0] r_data = 16'd0;
    reg r_valid = 1'b0;
    reg r_last = 1'b0;
    reg cmd_done = 1'b0;
    reg frame_swap_request = 1'b0;
    wire frame_done;
    wire [15:0] pixel_data;
    wire pixel_valid;
    wire pixel_take = pixel_valid;

    psramHdmiReader #(
        .H_ACTIVE(16), .V_ACTIVE(4), .BURST_WORDS(8),
        .FIFO_DEPTH(32), .FIFO_ABITS(5)
    ) dut (
        .phy_clk(phy_clk), .pixel_clk(pixel_clk), .reset_n(reset_n),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_addr(cmd_addr), .cmd_words(cmd_words),
        .r_data(r_data), .r_valid(r_valid), .r_last(r_last),
        .cmd_done(cmd_done), .frame_swap_request(frame_swap_request),
        .frame_done(frame_done), .pixel_take(pixel_take),
        .pixel_data(pixel_data), .pixel_valid(pixel_valid)
    );

    integer commandCount = 0;
    integer beat = 0;
    integer wordsPopped = 0;
    integer wordsPushed = 0;
    reg [15:0] expectedPixels [0:2047];
    reg busy = 1'b0;
    reg [21:0] activeAddr;
    integer interBurstGap = 0;

    always @(posedge phy_clk) begin
        r_valid <= 1'b0;
        r_last <= 1'b0;
        cmd_done <= 1'b0;
        if (!reset_n) begin
            commandCount <= 0;
            beat <= 0;
            busy <= 1'b0;
            wordsPushed <= 0;
            interBurstGap <= 0;
        end else if (interBurstGap != 0) begin
            interBurstGap <= interBurstGap - 1;
            if (interBurstGap == 1)
                cmd_ready <= 1'b1;
        end else if (cmd_valid && cmd_ready) begin
            if (cmd_words !== 7'd8)
                $fatal(1, "DMA did not request an eight-word test burst");
            if (cmd_addr !== (commandCount % 8) * 16)
                $fatal(1, "burst address %x expected %x", cmd_addr,
                       (commandCount % 8) * 16);
            activeAddr <= cmd_addr;
            commandCount <= commandCount + 1;
            beat <= 0;
            busy <= 1'b1;
            cmd_ready <= 1'b0;
        end else if (busy) begin
            r_valid <= 1'b1;
            r_last <= beat == 7;
            r_data <= activeAddr[15:0] + beat;
            expectedPixels[wordsPushed] <= activeAddr[15:0] + beat;
            wordsPushed <= wordsPushed + 1;
            if (beat == 7) begin
                busy <= 1'b0;
                cmd_done <= 1'b1;
                // Force the FIFO to become empty between bursts.  This catches
                // a stale occupancy count that emits one old word at empty.
                interBurstGap <= 20;
            end else begin
                beat <= beat + 1;
            end
        end
    end

    always @(posedge pixel_clk) begin
        if (pixel_take) begin
            if (wordsPopped >= wordsPushed)
                $fatal(1, "FIFO emitted an unproduced pixel at %0d", wordsPopped);
            if (pixel_data !== expectedPixels[wordsPopped])
                $fatal(1, "pixel %0d got %04x expected %04x",
                       wordsPopped, pixel_data, expectedPixels[wordsPopped]);
            wordsPopped <= wordsPopped + 1;
        end
    end

    integer timeout;
    initial begin
        repeat (5) @(negedge phy_clk);
        reset_n = 1'b1;

        wait (commandCount == 8);
        frame_swap_request = 1'b1;
        timeout = 0;
        while (!frame_done && timeout < 200) begin
            @(negedge phy_clk);
            timeout = timeout + 1;
        end
        if (!frame_done)
            $fatal(1, "DMA did not signal the completed frame");

        repeat (20) @(negedge phy_clk);
        if (commandCount != 8 || cmd_valid)
            $fatal(1, "DMA crossed a pending frame-swap barrier");

        frame_swap_request = 1'b0;
        wait (commandCount == 9);

        wait (wordsPopped >= 32);
        $display("PASS: HDMI DMA bursts, FIFO flow control and swap barrier");
        $finish;
    end
endmodule
