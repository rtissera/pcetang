# clk_pce/clk_sdram come from console60k_pll.vhd, SHARED with the Console 60K build.
# 2026-09-21: that PLL moved to FVCO 940.625 (see its header), so clk_pce is 42.755682
# and clk_sdram 85.511364 MHz here too.
# NOTE this file previously constrained clk_sdram to 120 MHz, a value the PLL stopped
# producing when ODIV1 went 10 -> 14 for the Console 60K SDRAM work. It was
# OVER-CONSTRAINED by ~40%, which manufactures violations on paths that are actually
# fine -- two of this board's reported failures were on clk_sdram.
# SPDX-License-Identifier: GPL-3.0-or-later
create_clock -name clk -period 20.000 [get_ports {clk}]
create_generated_clock -name clk_pce -source [get_ports {clk}] -master_clock clk -divide_by 352 -multiply_by 301 [get_nets {clk_pce}]
create_generated_clock -name clk_sdram -source [get_ports {clk}] -master_clock clk -divide_by 176 -multiply_by 301 [get_nets {clk_sdram}]
create_generated_clock -name clk_pixel -source [get_ports {clk}] -master_clock clk -divide_by 50 -multiply_by 27 [get_nets {clk_pixel}]
create_generated_clock -name clk_5x_pixel -source [get_ports {clk}] -master_clock clk -divide_by 10 -multiply_by 27 [get_nets {clk_5x_pixel}]
set_multicycle_path -setup 3 -from [get_clocks {clk_pce}] -to [get_clocks {clk_sdram}]
set_multicycle_path -hold  2 -from [get_clocks {clk_pce}] -to [get_clocks {clk_sdram}]
set_multicycle_path -setup 3 -from [get_clocks {clk_sdram}] -to [get_clocks {clk_pce}]
set_multicycle_path -hold  2 -from [get_clocks {clk_sdram}] -to [get_clocks {clk_pce}]
set_clock_groups -asynchronous -group [get_clocks {clk_pce}] -group [get_clocks {clk_pixel clk_5x_pixel}]
