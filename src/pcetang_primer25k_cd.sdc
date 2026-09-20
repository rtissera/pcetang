# SPDX-License-Identifier: GPL-3.0-or-later
create_clock -name clk -period 20.000 [get_ports {clk}]
create_generated_clock -name clk_pce -source [get_ports {clk}] -master_clock clk -divide_by 7 -multiply_by 6 [get_nets {clk_pce}]
create_generated_clock -name clk_sdram -source [get_ports {clk}] -master_clock clk -divide_by 5 -multiply_by 12 [get_nets {clk_sdram}]
# EXACT VIDEO LOCK (2026-09-20). clk_pixel now comes off the CORE PLL's 1200 MHz VCO
# (ODIV2 = 20) instead of the separate 480p PLL: 50 * 6/5 = 60.000 MHz. With H_total 1274
# that is exactly three output lines per source line. See console60k_pll.vhd.
create_generated_clock -name clk_pixel -source [get_ports {clk}] -master_clock clk -divide_by 5 -multiply_by 6 [get_nets {clk_pixel}]
# clk_5x_pixel: 300.000 MHz (1200 / ODIV3 4) = 50 * 6. Exact 5x preserved.
create_generated_clock -name clk_5x_pixel -source [get_ports {clk}] -master_clock clk -divide_by 1 -multiply_by 6 [get_nets {clk_5x_pixel}]
set_multicycle_path -setup 3 -from [get_clocks {clk_pce}] -to [get_clocks {clk_sdram}]
set_multicycle_path -hold  2 -from [get_clocks {clk_pce}] -to [get_clocks {clk_sdram}]
set_multicycle_path -setup 3 -from [get_clocks {clk_sdram}] -to [get_clocks {clk_pce}]
set_multicycle_path -hold  2 -from [get_clocks {clk_sdram}] -to [get_clocks {clk_pce}]
set_clock_groups -asynchronous -group [get_clocks {clk_pce}] -group [get_clocks {clk_pixel clk_5x_pixel}]
