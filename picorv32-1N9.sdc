 create_clock -name clock50MHz 
      -period 20.000 
      -waveform {0.000 10.000} 
      [get_ports {clock50MHz}]

# Pixel data crosses between the 80 MHz PSRAM and 25.333 MHz video domains
# only through Gray-pointer synchronizers and a true dual-clock BSRAM FIFO.
# The HDMI serializer and pixel clocks stay in the same group so OSER10 is
# still checked as a related 5:1 clock pair.
create_generated_clock -name psramClk80 -source [get_ports {clock50MHz}] -multiply_by 8 -divide_by 5 [get_pins {sysPll/rpll_inst/CLKOUT}]
create_generated_clock -name psramClkP80 -source [get_ports {clock50MHz}] -multiply_by 8 -divide_by 5 [get_pins {sysPll/rpll_inst/CLKOUTP}]
create_generated_clock -name systemClk40 -source [get_ports {clock50MHz}] -multiply_by 4 -divide_by 5 [get_pins {sysPll/rpll_inst/CLKOUTD}]
create_generated_clock -name hdmiSerial126 -source [get_pins {sysPll/rpll_inst/CLKOUTD}] -multiply_by 19 -divide_by 6 [get_pins {hdmiClocks/pll/rpll_inst/CLKOUT}]
create_generated_clock -name hdmiPixel25 -source [get_pins {hdmiClocks/pll/rpll_inst/CLKOUT}] -divide_by 5 [get_pins {hdmiClocks/div5/clkdiv_inst/CLKOUT}]
set_clock_groups -asynchronous -group [get_clocks {psramClk80 psramClkP80 systemClk40}] -group [get_clocks {hdmiSerial126 hdmiPixel25}]

# Each OSER reset is launched on a serializer rising edge and deliberately
# delayed past the immediately following falling edge.  Static recovery
# analysis does not roll that path forward to the next (safe) edge, so exclude
# only the three startup-reset pins; TMDS data/PCLK/FCLK remain fully timed.
set_false_path -to [get_pins {hdmiOutput/serBlue/RESET hdmiOutput/serGreen/RESET hdmiOutput/serRed/RESET}]
