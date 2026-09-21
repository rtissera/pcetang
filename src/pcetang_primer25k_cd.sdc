# SPDX-License-Identifier: GPL-3.0-or-later
# clk_pce / clk_sdram come from primer25k_pll.vhd, this board's OWN PLL: FVCO 1200 with
# ODIV0 28 and ODIV1 14, i.e. 42.857142 and 85.714285 MHz.
#
# clk_sdram was constrained here to 120 MHz until 2026-09-21 -- a frequency the PLL stopped
# producing when ODIV1 went 10 -> 14 during the Console 60K SDRAM work. It was
# OVER-CONSTRAINED by ~40%, which manufactures setup violations on paths that are actually
# fine; two of this board's reported failures were on clk_sdram.
create_clock -name clk -period 20.000 [get_ports {clk}]
create_generated_clock -name clk_pce -source [get_ports {clk}] -master_clock clk -divide_by 7 -multiply_by 6 [get_nets {clk_pce}]
create_generated_clock -name clk_sdram -source [get_ports {clk}] -master_clock clk -divide_by 7 -multiply_by 12 [get_nets {clk_sdram}]
create_generated_clock -name clk_pixel -source [get_ports {clk}] -master_clock clk -divide_by 50 -multiply_by 27 [get_nets {clk_pixel}]
create_generated_clock -name clk_5x_pixel -source [get_ports {clk}] -master_clock clk -divide_by 10 -multiply_by 27 [get_nets {clk_5x_pixel}]
set_multicycle_path -setup 3 -from [get_clocks {clk_pce}] -to [get_clocks {clk_sdram}]
set_multicycle_path -hold  2 -from [get_clocks {clk_pce}] -to [get_clocks {clk_sdram}]
set_multicycle_path -setup 3 -from [get_clocks {clk_sdram}] -to [get_clocks {clk_pce}]
set_multicycle_path -hold  2 -from [get_clocks {clk_sdram}] -to [get_clocks {clk_pce}]
set_clock_groups -asynchronous -group [get_clocks {clk_pce}] -group [get_clocks {clk_pixel clk_5x_pixel}]
