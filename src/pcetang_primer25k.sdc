# SPDX-License-Identifier: GPL-3.0-or-later

# Tang Primer 25K, pcetang Phase 1. Same clock/PLL math as Console 60K's Phase 1 (same
# GW5A PLLA primitive, same real measured constraints) -- see that board's .sdc header.
#
# clk_sdram (120 MHz off the same console60k_pll instance) was MISSING from this file
# entirely on the first attempt -- real gw_sh measured 136 setup / 100 hold violations,
# every single one starting at `sdram_inst/RAM_A_WAIT_s0/Q` (an undeclared
# `pll/PLLA_inst/CLKOUT1.default_gen_clk`) landing in `core/gen_vram0_ext.VRAM0/...` on
# clk_pce -- a real clk_sdram/clk_pce CDC that this file gave the tool no information
# about, so it was analyzed as ordinary same-clock logic instead of the multicycle-
# tolerant boundary it actually is. NECTang's own real, proven `primer25k_core_test.sdc`
# (checked directly, not assumed) already has the fix for this exact boundary --
# applied verbatim below, not re-derived.

create_clock -name clk -period 20.000 [get_ports {clk}]

create_generated_clock -name clk_pce -source [get_ports {clk}] -master_clock clk -divide_by 7 -multiply_by 6 [get_nets {clk_pce}]

create_generated_clock -name clk_sdram -source [get_ports {clk}] -master_clock clk -divide_by 5 -multiply_by 12 [get_nets {clk_sdram}]

create_generated_clock -name clk_pixel -source [get_ports {clk}] -master_clock clk -divide_by 50 -multiply_by 27 [get_nets {clk_pixel}]

create_generated_clock -name clk_5x_pixel -source [get_ports {clk}] -master_clock clk -divide_by 10 -multiply_by 27 [get_nets {clk_5x_pixel}]

# Same CDC shape as NECTang's own primer25k_core_test.sdc/primer25k_sdram_test.sdc.
set_multicycle_path -setup 3 -from [get_clocks {clk_pce}] -to [get_clocks {clk_sdram}]
set_multicycle_path -hold  2 -from [get_clocks {clk_pce}] -to [get_clocks {clk_sdram}]
set_multicycle_path -setup 3 -from [get_clocks {clk_sdram}] -to [get_clocks {clk_pce}]
set_multicycle_path -hold  2 -from [get_clocks {clk_sdram}] -to [get_clocks {clk_pce}]

set_clock_groups -asynchronous -group [get_clocks {clk_pce}] -group [get_clocks {clk_pixel clk_5x_pixel}]
