`timescale 1ns / 1ps
`default_nettype none

// 单个低有效按键的两级同步与消抖。每个物理按键各实例化一次。
module ButtonDebounce #(
    // 50 MHz 下 2,500,000 拍 = 50 ms；有效范围 1~4,194,303。
    parameter [21:0] FILTER_CYCLES = 22'd2_500_000,
    // 复位键用 1：按下后只等同步，不等 50 ms；松开仍消抖 50 ms。
    parameter integer FAST_PRESS = 0,
    // 复位键用 1：FPGA 上电时先视为按下，保持系统复位。
    parameter integer POWERUP_PRESSED = 0
) (
    input  wire clock50MHz,
    input  wire reset_n,      // 本实例的同步复位；复位键实例接 1'b1。
    input  wire button_n,     // 物理按键：按下为 0，松开为 1。
    output wire debounced_n,  // 已确认的按键电平，按下为 0。
    output wire pressPulse    // 确认一次按下时产生一个时钟周期的脉冲。
);
    localparam [21:0] FILTER_LAST = FILTER_CYCLES - 22'd1;

    // 前两级触发器把异步按键采样到 50 MHz 时钟域。
    // 初值确保复位键上电时先保持按下；启动键上电时先保持松开。
    reg buttonMeta = (POWERUP_PRESSED != 0) ? 1'b0 : 1'b1;
    reg buttonSync = (POWERUP_PRESSED != 0) ? 1'b0 : 1'b1;
    wire sampledPressed = !buttonSync;

    reg pressed = (POWERUP_PRESSED != 0);
    reg [21:0] stableCounter = 22'd0;
    reg pulse = 1'b0;

    assign debounced_n = !pressed;
    assign pressPulse = pulse;

    always @(posedge clock50MHz) begin
        if (!reset_n) begin
            buttonMeta <= (POWERUP_PRESSED != 0) ? 1'b0 : 1'b1;
            buttonSync <= (POWERUP_PRESSED != 0) ? 1'b0 : 1'b1;
            pressed <= (POWERUP_PRESSED != 0);
            stableCounter <= 22'd0;
            pulse <= 1'b0;
        end else begin
            buttonMeta <= button_n;
            buttonSync <= buttonMeta;
            pulse <= 1'b0;

            if (sampledPressed == pressed) begin
                stableCounter <= 22'd0;
            end else if ((FAST_PRESS != 0) && sampledPressed) begin
                // 复位键按下尽快生效；松开仍必须通过完整消抖时间。
                pressed <= 1'b1;
                stableCounter <= 22'd0;
                pulse <= 1'b1;
            end else if (stableCounter == FILTER_LAST) begin
                pressed <= sampledPressed;
                stableCounter <= 22'd0;
                if (sampledPressed)
                    pulse <= 1'b1;
            end else begin
                stableCounter <= stableCounter + 22'd1;
            end
        end
    end
endmodule

`default_nettype wire
