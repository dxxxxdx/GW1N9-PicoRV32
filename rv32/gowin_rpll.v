//------------------------------------------------------------------------------
// gowin_rpll.v  --  50MHz -> PSRAM 80MHz / CPU 40MHz
//
// 器件：GW1NR-9C / GW1NR-LV9QN88PC6/I5，输入 50MHz 晶振。
//
// CPU 仍然保持 40MHz：
// 实测（同一份逻辑只换时钟源）：
//   引脚 50MHz 直连          : 0 违反，最差路径 19.884ns
//   同一份逻辑改走 PLL 50MHz : 47 违反，最差路径 21.688ns
// 也就是说 PLL 出来的时钟本身要吃掉约 1.8ns，PicoRV32 在这颗 C6/I5 上
// 用 PLL 时 Fmax 只有 ~46MHz，50MHz 收不了。退到 40MHz 留出余量。
//
// PSRAM PHY 独立跑 80MHz，并由 psramController 的 toggle handshake 跨域。
//
//   fCLKOUT = fCLKIN x (FBDIV_SEL+1) / (IDIV_SEL+1) = 50 x 8 / 5 = 80MHz
//   fVCO    = fCLKOUT x ODIV_SEL = 80 x 8 = 640MHz       （要求 400~1200MHz）
//   fPFD    = fCLKIN / (IDIV_SEL+1) = 50 / 5 = 10MHz     （要求 3~400MHz）
//   fCLKOUTD = fCLKOUT / 2 = 40MHz（CPU / 总线）
//
// clkoutp 是给 PSRAM 送 CK 用的相移时钟。PSDA 每级为 22.5 度；当前实测
// 通过窗口是 2..7，默认取中点 PSDA = 5（112.5 度）：
// PSRAM 在 CK 沿上收发数据，FPGA 用自己的时钟采样，CK 必须相对 fabric 时钟
// 落在合适的数据眼位置。rdLat 只能按整拍挪，不能替代这个拍内相位调整。
// 这个值抄的是能跑通的 1:1 开源设计（dominicbeesley/psram-tang-nano-9k）。
//------------------------------------------------------------------------------
`timescale 1ns / 1ps

module Gowin_rPLL (
    output clkout,      // 80MHz -> PSRAM PHY
    output clkoutp,     // 80MHz动态相移 -> PSRAM CK
    output clkoutd,     // 40MHz -> CPU / 总线
    output lock,
    input  clkin,       // 50MHz 晶振
    input  [3:0] psda   // 动态相位：每级 22.5 度，固件训练后选窗口中心
);

wire clkoutd3_o;
wire gw_vcc;
wire gw_gnd;
wire [3:0] dutyda;

assign gw_vcc = 1'b1;
assign gw_gnd = 1'b0;
// With DYN_DA_EN enabled DUTYDA is the falling-edge position, not a standalone
// duty-cycle value.  Keeping it eight taps after PSDA preserves a 50% clock at
// every phase (the addition deliberately wraps modulo 16).
assign dutyda = psda + 4'd8;

rPLL rpll_inst (
    .CLKOUT     (clkout),
    .LOCK       (lock),
    .CLKOUTP    (clkoutp),
    .CLKOUTD    (clkoutd),
    .CLKOUTD3   (clkoutd3_o),
    .RESET      (gw_gnd),
    .RESET_P    (gw_gnd),
    .CLKIN      (clkin),
    .CLKFB      (gw_gnd),
    .FBDSEL     ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
    .IDSEL      ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
    .ODSEL      ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
    .PSDA       (psda),
    .DUTYDA     (dutyda),
    .FDLY       ({gw_vcc, gw_vcc, gw_vcc, gw_vcc})
);

defparam rpll_inst.FCLKIN           = "50";
defparam rpll_inst.DYN_IDIV_SEL     = "false";
defparam rpll_inst.IDIV_SEL         = 4;        // IDIV = 5  -> fPFD = 10MHz
defparam rpll_inst.DYN_FBDIV_SEL    = "false";
defparam rpll_inst.FBDIV_SEL        = 7;        // FBDIV = 8 -> 50*8/5 = 80MHz
defparam rpll_inst.DYN_ODIV_SEL     = "false";
defparam rpll_inst.ODIV_SEL         = 8;        // fVCO = 640MHz
defparam rpll_inst.PSDA_SEL         = "0101";   // static fallback: measured center tap 5
defparam rpll_inst.DYN_DA_EN        = "true";
defparam rpll_inst.DUTYDA_SEL       = "1101";   // static fallback: PSDA+8
defparam rpll_inst.CLKOUT_FT_DIR    = 1'b1;
defparam rpll_inst.CLKOUTP_FT_DIR   = 1'b1;
defparam rpll_inst.CLKOUT_DLY_STEP  = 0;
defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
defparam rpll_inst.CLKFB_SEL        = "internal";
defparam rpll_inst.CLKOUT_BYPASS    = "false";
defparam rpll_inst.CLKOUTP_BYPASS   = "false";
defparam rpll_inst.CLKOUTD_BYPASS   = "false";
defparam rpll_inst.DYN_SDIV_SEL     = 2;        // CLKOUTD = 80/2 = 40MHz
defparam rpll_inst.CLKOUTD_SRC      = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC     = "CLKOUT";
defparam rpll_inst.DEVICE           = "GW1NR-9C";

endmodule
