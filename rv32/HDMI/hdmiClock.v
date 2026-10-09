`timescale 1ns / 1ps
`default_nettype none

// Tang Nano 9K reference-video clock tree:
//   system 40 MHz -> 126.6667 MHz serializer -> CLKDIV /5 -> 25.3333 MHz pixel.
// The resulting 640x480 timing is the same slightly-fast mode used by the
// board example (about 60.3 Hz with an 800x525 total raster).
module hdmiClock (
    input  wire clk40,
    input  wire reset_n,
    output wire pixel_clk,
    output wire serial_clk,
    output wire locked
);
    wire pllLock;

    Gowin_HDMI_rPLL pll (
        .clkout(serial_clk), .lock(pllLock), .clkin(clk40)
    );

    Gowin_HDMI_CLKDIV div5 (
        .clkout(pixel_clk), .hclkin(serial_clk),
        .resetn(reset_n && pllLock)
    );

    assign locked = pllLock;
endmodule

module Gowin_HDMI_rPLL (
    output wire clkout,
    output wire lock,
    input  wire clkin
);
    wire clkoutpUnused;
    wire clkoutdUnused;
    wire clkoutd3Unused;
    wire gwGnd = 1'b0;

    // 高云专用原语 rPLL：把系统 40MHz 提升为 TMDS 串行器使用的
    // 126.6667MHz。移植时换成目标器件的 PLL/MMCM；必须保留 lock，
    // 并让它参与下级像素时钟和发送器的复位释放。
    // 下方 defparam 是 Gowin 的参数编码，其他厂商需要重新计算。
    rPLL rpll_inst (
        .CLKOUT(clkout), .LOCK(lock), .CLKOUTP(clkoutpUnused),
        .CLKOUTD(clkoutdUnused), .CLKOUTD3(clkoutd3Unused),
        .RESET(gwGnd), .RESET_P(gwGnd), .CLKIN(clkin), .CLKFB(gwGnd),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0), .PSDA(4'b0),
        .DUTYDA(4'b0), .FDLY(4'b0)
    );

    // 40 MHz * (18 + 1) / (5 + 1) = 126.6667 MHz.
    defparam rpll_inst.FCLKIN = "40";
    defparam rpll_inst.DYN_IDIV_SEL = "false";
    defparam rpll_inst.IDIV_SEL = 5;
    defparam rpll_inst.DYN_FBDIV_SEL = "false";
    defparam rpll_inst.FBDIV_SEL = 18;
    defparam rpll_inst.DYN_ODIV_SEL = "false";
    defparam rpll_inst.ODIV_SEL = 4;
    defparam rpll_inst.PSDA_SEL = "0000";
    defparam rpll_inst.DYN_DA_EN = "true";
    defparam rpll_inst.DUTYDA_SEL = "1000";
    defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
    defparam rpll_inst.CLKOUTP_FT_DIR = 1'b1;
    defparam rpll_inst.CLKOUT_DLY_STEP = 0;
    defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
    defparam rpll_inst.CLKFB_SEL = "internal";
    defparam rpll_inst.CLKOUT_BYPASS = "false";
    defparam rpll_inst.CLKOUTP_BYPASS = "false";
    defparam rpll_inst.CLKOUTD_BYPASS = "false";
    defparam rpll_inst.DYN_SDIV_SEL = 2;
    defparam rpll_inst.CLKOUTD_SRC = "CLKOUT";
    defparam rpll_inst.CLKOUTD3_SRC = "CLKOUT";
    defparam rpll_inst.DEVICE = "GW1NR-9C";
endmodule

module Gowin_HDMI_CLKDIV (
    output wire clkout,
    input  wire hclkin,
    input  wire resetn
);
    // 高云专用全局时钟分频原语：126.6667MHz / 5 = 25.3333MHz。
    // 它与上面的串行时钟保持固定 5:1 关系。移植时优先使用目标器件的
    // 专用全局时钟分频器或 PLL 第二路输出，不要用普通逻辑计数器造时钟。
    CLKDIV clkdiv_inst (
        .CLKOUT(clkout), .HCLKIN(hclkin), .RESETN(resetn), .CALIB(1'b0)
    );
    defparam clkdiv_inst.DIV_MODE = "5";
    defparam clkdiv_inst.GSREN = "false";
endmodule

`default_nettype wire
