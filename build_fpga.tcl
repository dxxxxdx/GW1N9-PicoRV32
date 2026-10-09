# Reproducible Gowin build for GW1NR-LV9QN88PC6/I5.
# Run with: gw_sh build_fpga.tcl

set project_dir [file dirname [file normalize [info script]]]
open_project [file join $project_dir GW1NR9_rv32.gprj]

set_option -synthesis_tool gowinsynthesis
set_option -output_base_name GW1NR9_rv32
set_option -verilog_std v2001
set_option -gen_text_timing_rpt 1
set_option -print_all_synthesis_warning 1
set_option -timing_driven 1
# Higher-effort placement/routing is needed because the design runs 80 MHz
# PSRAM and 126.667 MHz OSER clocks concurrently.
set_option -place_option 2
set_option -route_option 2

# irq_n is on the package's multiplexed SSPI pin 56.
set_option -use_sspi_as_gpio 1

run all
run close
exit
