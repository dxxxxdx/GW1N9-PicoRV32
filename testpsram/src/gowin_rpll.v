//------------------------------------------------------------------------------
// gowin_rpll.v  --  rPLL 50MHz -> 80MHz（+ 相移输出 clkoutp）
//
// 目标器件：GW1NR-9C / GW1NR-LV9QN88PC6/I5
//
// 计算（Gowin rPLL 公式）：
//   fCLKOUT = fCLKIN x (FBDIV_SEL+1) / (IDIV_SEL+1)
//           = 50 x 8 / 5 = 80MHz
//   fVCO    = fCLKOUT x ODIV_SEL = 80 x 8 = 640MHz   （要求 400~1200MHz）
//   fPFD    = fCLKIN / (IDIV_SEL+1) = 50 / 5 = 10MHz（要求 3~400MHz）
//
// clkoutp 是给 PSRAM 送 CK 用的相移时钟，相位用 PSDA_SEL 扫：
//   PSDA_SEL = "0000" ~ "1111"，步进和 fVCO 有关（这里 VCO=640MHz）
//   先用 "0010" 起步，上板后用示波器看 CK 和 DQ 的边沿关系再调。
//------------------------------------------------------------------------------
`timescale 1ns/1ps

module Gowin_rPLL (
    output clkout,      // 80MHz  -> fabric
    output clkoutp,     // 80MHz 相移 -> 推 PSRAM CK
    output lock,
    input  clkin        // 50MHz 晶振
);

wire clkoutd_o;
wire clkoutd3_o;
wire gw_gnd;

assign gw_gnd = 1'b0;

rPLL rpll_inst (
    .CLKOUT     (clkout),
    .LOCK       (lock),
    .CLKOUTP    (clkoutp),
    .CLKOUTD    (clkoutd_o),
    .CLKOUTD3   (clkoutd3_o),
    .RESET      (gw_gnd),
    .RESET_P    (gw_gnd),
    .CLKIN      (clkin),
    .CLKFB      (gw_gnd),
    .FBDSEL     ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
    .IDSEL      ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
    .ODSEL      ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
    .PSDA       ({gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
    .DUTYDA     ({gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
    .FDLY       ({gw_gnd, gw_gnd, gw_gnd, gw_gnd})
);

defparam rpll_inst.FCLKIN           = "50";
defparam rpll_inst.DYN_IDIV_SEL     = "false";
defparam rpll_inst.IDIV_SEL         = 4;        // IDIV = 5  -> fPFD = 10MHz
defparam rpll_inst.DYN_FBDIV_SEL    = "false";
defparam rpll_inst.FBDIV_SEL        = 7;        // FBDIV = 8 -> 50*8/5 = 80MHz
defparam rpll_inst.DYN_ODIV_SEL     = "false";
defparam rpll_inst.ODIV_SEL         = 8;        // fVCO = 640MHz
defparam rpll_inst.PSDA_SEL         = "0010";   // CK 相移，上板扫这个值
defparam rpll_inst.DYN_DA_EN        = "true";
defparam rpll_inst.DUTYDA_SEL       = "1000";
defparam rpll_inst.CLKOUT_FT_DIR    = 1'b1;
defparam rpll_inst.CLKOUTP_FT_DIR   = 1'b1;
defparam rpll_inst.CLKOUT_DLY_STEP  = 0;
defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
defparam rpll_inst.CLKFB_SEL        = "internal";
defparam rpll_inst.CLKOUT_BYPASS    = "false";
defparam rpll_inst.CLKOUTP_BYPASS   = "false";
defparam rpll_inst.CLKOUTD_BYPASS   = "false";
defparam rpll_inst.DYN_SDIV_SEL     = 8;
defparam rpll_inst.CLKOUTD_SRC      = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC     = "CLKOUT";
defparam rpll_inst.DEVICE           = "GW1NR-9C";

endmodule
