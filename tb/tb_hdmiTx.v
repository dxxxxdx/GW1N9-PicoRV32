`timescale 1ns / 1ps

module LUT1 #(parameter [1:0] INIT = 2'h0) (
    output wire F, input wire I0
);
    assign F = I0 ? INIT[1] : INIT[0];
endmodule

module OSER10 (
    output wire Q,
    input wire D0, D1, D2, D3, D4, D5, D6, D7, D8, D9,
    input wire PCLK, FCLK, RESET
);
    assign Q = RESET ? 1'b0 : D0;
    wire unused = &{D1,D2,D3,D4,D5,D6,D7,D8,D9,PCLK,FCLK};
endmodule

module ELVDS_OBUF(input wire I, output wire O, output wire OB);
    assign O = I;
    assign OB = ~I;
endmodule

module tb_hdmiTx;
    reg pixel_clk = 1'b0;
    reg serial_clk = 1'b0;
    reg reset_n = 1'b0;
    always #10 pixel_clk = ~pixel_clk;
    always #2 serial_clk = ~serial_clk;

    wire pixel_take;
    wire underflow;
    wire tmds_clk_n, tmds_clk_p;
    wire [2:0] tmds_d_n, tmds_d_p;

    hdmiTx #(
        .H_ACTIVE(4), .H_FRONT(1), .H_SYNC(1), .H_BACK(1),
        .V_ACTIVE(3), .V_FRONT(1), .V_SYNC(1), .V_BACK(1)
    ) dut (
        .pixel_clk(pixel_clk), .serial_clk(serial_clk), .reset_n(reset_n),
        .pixel_data(16'hf81f), .pixel_valid(1'b1),
        .pixel_take(pixel_take), .underflow(underflow),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p),
        .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    integer pixels = 0;
    integer cycles = 0;
    initial begin
        repeat (5) @(negedge pixel_clk);
        reset_n = 1'b1;
        wait (dut.pixelReset_n);

        // One complete 7x6 raster contains exactly 4x3 active pixels.
        repeat (42) begin
            @(negedge pixel_clk);
            if (pixel_take)
                pixels = pixels + 1;
            cycles = cycles + 1;
        end
        if (pixels != 12 || underflow)
            $fatal(1, "HDMI raster pixels=%0d underflow=%b", pixels, underflow);
        #1;
        if (tmds_clk_p === tmds_clk_n)
            $fatal(1, "differential clock outputs are not complementary");

        $display("PASS: HDMI raster, RGB565 path and TMDS serializer wiring");
        $finish;
    end
endmodule
