//------------------------------------------------------------------------------
// gowin_rpll.v  --  50MHz -> 40MHz（+ 相移输出）
//
// 器件：GW1NR-9C / GW1NR-LV9QN88PC6/I5，输入 50MHz 晶振。
//
// !!! 为什么是 40MHz !!!
// 实测（同一份逻辑只换时钟源）：
//   引脚 50MHz 直连          : 0 违反，最差路径 19.884ns
//   同一份逻辑改走 PLL 50MHz : 47 违反，最差路径 21.688ns
// 也就是说 PLL 出来的时钟本身要吃掉约 1.8ns，PicoRV32 在这颗 C6/I5 上
// 用 PLL 时 Fmax 只有 ~46MHz，50MHz 收不了。退到 40MHz 留出余量。
//
// 以后要给显示通道提带宽，走"CPU 40MHz + PHY 80MHz + 跨时钟握手"，
// 那时候只需要改这里和 psramController 的 CDC。
//
//   fCLKOUT = fCLKIN x (FBDIV_SEL+1) / (IDIV_SEL+1) = 50 x 4 / 5 = 40MHz
//   fVCO    = fCLKOUT x ODIV_SEL = 40 x 16 = 640MHz      （要求 400~1200MHz）
//   fPFD    = fCLKIN / (IDIV_SEL+1) = 50 / 5 = 10MHz     （要求 3~400MHz）
//
// clkoutp 是给 PSRAM 送 CK 用的相移时钟。PSDA_SEL = 4 -> 90 度，这是关键：
// PSRAM 在 CK 沿上收发数据，FPGA 用自己的时钟采样，CK 必须相对 fabric 时钟
// 偏 90 度，采样点才落在数据眼中间。之前写成 2（45 度）时读数全是乱的，
// 而且怎么扫 rdLat 都对不上——rdLat 只能按整拍挪，挪不了这半拍以内的事。
// 这个值抄的是能跑通的 1:1 开源设计（dominicbeesley/psram-tang-nano-9k）。
//------------------------------------------------------------------------------
`timescale 1ns / 1ps

module Gowin_rPLL (
    output clkout,      // 40MHz  -> 系统时钟
    output clkoutp,     // 40MHz 相移 -> PSRAM CK
    output lock,
    input  clkin,       // 50MHz 晶振
    input  [3:0] psda   // CK 相移，运行时可调（见下面 DYN_DA_EN 的说明）
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
    .PSDA       (psda),                     // 运行时相移，来自配置窗口
    .DUTYDA     (4'b1000),                  // 占空比中值（1000 = 50%）
    .FDLY       ({gw_gnd, gw_gnd, gw_gnd, gw_gnd})
);

defparam rpll_inst.FCLKIN           = "50";
defparam rpll_inst.DYN_IDIV_SEL     = "false";
defparam rpll_inst.IDIV_SEL         = 4;        // IDIV = 5  -> fPFD = 10MHz
defparam rpll_inst.DYN_FBDIV_SEL    = "false";
defparam rpll_inst.FBDIV_SEL        = 3;        // FBDIV = 4 -> 50*4/5 = 40MHz
defparam rpll_inst.DYN_ODIV_SEL     = "false";
defparam rpll_inst.ODIV_SEL         = 16;       // fVCO = 640MHz
defparam rpll_inst.PSDA_SEL         = "0100";   // DYN_DA_EN=true 时本参数被忽略，见下
// !!! 坑 !!!
// DYN_DA_EN = "false" 时相移取静态的 PSDA_SEL 参数；
// DYN_DA_EN = "true"  时相移取 PSDA **输入端口**，PSDA_SEL 参数被完全忽略。
// 一开始我写的 true 但把 .PSDA 接了 0，于是怎么改 PSDA_SEL 都没反应
// （实测：改成 0100 后输出字节级完全一样）。
// 现在故意用 true，把 PSDA 接到配置窗口的寄存器上 —— 相位变成运行时可调，
// 固件扫一遍就行，不用改代码重新综合。
defparam rpll_inst.DYN_DA_EN        = "true";
defparam rpll_inst.DUTYDA_SEL       = "1000";   // 同上，true 时忽略
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
