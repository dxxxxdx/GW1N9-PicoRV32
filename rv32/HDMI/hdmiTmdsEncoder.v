/*
 * TMDS encoder derived from SVO (Simple Video Out FPGA Core).
 * Copyright (C) 2014 Clifford Wolf <clifford@clifford.at>
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted.
 */
`timescale 1ns / 1ps
`default_nettype none

module hdmiTmdsEncoder (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       de,
    input  wire [1:0] ctrl,
    input  wire [7:0] data,
    output reg  [9:0] encoded
);
    function [3:0] countOnes;
        input [7:0] bits;
        integer i;
        begin
            countOnes = 4'd0;
            for (i = 0; i < 8; i = i + 1)
                countOnes = countOnes + bits[i];
        end
    endfunction

    reg [8:0] q_m;
    reg [9:0] q_out;
    reg [9:0] q_pipe;
    reg signed [7:0] disparity;
    reg signed [7:0] nextDisparity;
    reg [9:0] nextOut;
    reg [3:0] onesQm;
    reg [3:0] zerosQm;
    integer j;

    always @* begin
        q_m[0] = data[0];
        if ((countOnes(data) > 4) ||
            ((countOnes(data) == 4) && !data[0])) begin
            for (j = 1; j < 8; j = j + 1)
                q_m[j] = q_m[j-1] ~^ data[j];
            q_m[8] = 1'b0;
        end else begin
            for (j = 1; j < 8; j = j + 1)
                q_m[j] = q_m[j-1] ^ data[j];
            q_m[8] = 1'b1;
        end

        onesQm = countOnes(q_m[7:0]);
        zerosQm = 4'd8 - onesQm;
        nextOut = 10'd0;
        nextDisparity = disparity;

        if ((disparity == 0) || (onesQm == zerosQm)) begin
            nextOut[9] = ~q_m[8];
            nextOut[8] = q_m[8];
            nextOut[7:0] = q_m[8] ? q_m[7:0] : ~q_m[7:0];
            nextDisparity = q_m[8] ? disparity + onesQm - zerosQm :
                                             disparity + zerosQm - onesQm;
        end else if (((disparity > 0) && (onesQm > zerosQm)) ||
                     ((disparity < 0) && (zerosQm > onesQm))) begin
            nextOut = {1'b1, q_m[8], ~q_m[7:0]};
            nextDisparity = disparity + zerosQm - onesQm +
                            (q_m[8] ? 2 : 0);
        end else begin
            nextOut = {1'b0, q_m[8], q_m[7:0]};
            nextDisparity = disparity + onesQm - zerosQm -
                            (q_m[8] ? 0 : 2);
        end
    end

    always @(posedge clk) begin
        if (!reset_n) begin
            disparity <= 0;
            q_out <= 10'd0;
            q_pipe <= 10'd0;
            encoded <= 10'd0;
        end else if (!de) begin
            disparity <= 0;
            case (ctrl)
                2'b00: q_out <= 10'b1101010100;
                2'b01: q_out <= 10'b0010101011;
                2'b10: q_out <= 10'b0101010100;
                default: q_out <= 10'b1010101011;
            endcase
            q_pipe <= q_out;
            encoded <= q_pipe;
        end else begin
            disparity <= nextDisparity;
            q_out <= nextOut;
            q_pipe <= q_out;
            encoded <= q_pipe;
        end
    end
endmodule

`default_nettype wire
