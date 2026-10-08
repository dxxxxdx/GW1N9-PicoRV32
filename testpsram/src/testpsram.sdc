//------------------------------------------------------------------------------
// testpsram.sdc
//
// 只需要约束输入晶振。rPLL 的输出时钟 Gowin 会自动推导出来：
//   clock50MHz 20ns  ->  PLL  ->  clk/clk_p 12.5ns (80MHz)
// 时序报告里要看的是 clk 域到 ODDR、以及 IDDR 回 clk 域的 setup/hold。
//------------------------------------------------------------------------------

create_clock -name clock50MHz
    -period 20.000
    -waveform {0.000 10.000}
    [get_ports {clock50MHz}]
