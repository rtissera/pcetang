# SPDX-License-Identifier: GPL-3.0-or-later
# clk_pce / clk_sdram come from primer25k_pll.vhd, this board's own PLL (FVCO 1200,
# ODIV0 28 -> 42.857142 MHz, ODIV1 14 -> 85.714285 MHz).
#
# clk_sdram is constrained at 120 MHz although the PLL makes 85.714. That is an
# OVER-constraint -- conservative, and it closes on main (+1.602% against 120). It was
# relaxed to the true 85.714 on 2026-09-21 and reverted the same day: at 100% CLS the
# relaxation alone changed placement enough to cost clk_pce, and this board has no slack
# to spend on a cosmetic correction. Relax it only together with a change that frees
# logic, and measure.
create_clock -name clk -period 20.000 [get_ports {clk}]
create_generated_clock -name clk_pce -source [get_ports {clk}] -master_clock clk -divide_by 7 -multiply_by 6 [get_nets {clk_pce}]
create_generated_clock -name clk_sdram -source [get_ports {clk}] -master_clock clk -divide_by 5 -multiply_by 12 [get_nets {clk_sdram}]
create_generated_clock -name clk_pixel -source [get_ports {clk}] -master_clock clk -divide_by 50 -multiply_by 27 [get_nets {clk_pixel}]
create_generated_clock -name clk_5x_pixel -source [get_ports {clk}] -master_clock clk -divide_by 10 -multiply_by 27 [get_nets {clk_5x_pixel}]
set_multicycle_path -setup 3 -from [get_clocks {clk_pce}] -to [get_clocks {clk_sdram}]
set_multicycle_path -hold  2 -from [get_clocks {clk_pce}] -to [get_clocks {clk_sdram}]
set_multicycle_path -setup 3 -from [get_clocks {clk_sdram}] -to [get_clocks {clk_pce}]
set_multicycle_path -hold  2 -from [get_clocks {clk_sdram}] -to [get_clocks {clk_pce}]
set_clock_groups -asynchronous -group [get_clocks {clk_pce}] -group [get_clocks {clk_pixel clk_5x_pixel}]
