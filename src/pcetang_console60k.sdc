# SPDX-License-Identifier: GPL-3.0-or-later

# Tang Console 60K, pcetang Phase 1. Four clock domains off one 50 MHz crystal, two
# independent PLLA instances (console60k_pll.vhd for clk_pce/clk_sdram, unchanged from
# NECTang; pcetang_console60k_hdmi_pll.vhd for the HDMI pair) -- clk_pce is NOT
# phase-related to clk_pixel/clk_5x_pixel even though both trace to the same crystal,
# so they're marked asynchronous clock groups below.
#
# clk_sdram (2026-08-28, added when ROM moved onto SDRAM): same console60k_pll instance
# and same 120 MHz math as pcetang_primer25k.vhd's clk_sdram -- see that file's header
# for the real, hard-won precedent this multicycle fix is copied from verbatim: leaving
# clk_sdram out of the .sdc entirely measured 136 setup / 100 hold violations on Primer
# 25K, every one starting at the sdram_inst/RAM_x_WAIT crossing into clk_pce because an
# undeclared generated clock gets analyzed as ordinary same-clock logic instead of the
# real, multicycle-tolerant CDC it is.

create_clock -name clk -period 20.000 [get_ports {clk}]

# clk_pce: 42.857 MHz (FVCO 1200 MHz / ODIV0 28) -- same math as NECTang's own
# console60k_pll.vhd, unchanged here.
create_generated_clock -name clk_pce -source [get_ports {clk}] -master_clock clk -divide_by 7 -multiply_by 6 [get_nets {clk_pce}]

create_generated_clock -name clk_sdram -source [get_ports {clk}] -master_clock clk -divide_by 5 -multiply_by 12 [get_nets {clk_sdram}]

# clk_pixel: 75.000 MHz (FVCO 750 MHz / ODIV0 10), +1.01% vs the nominal 74.25 HDMI
# spec -- see pcetang_console60k_hdmi_pll.vhd's header for the three real PLL-parameter
# measurements (invalid MDIV_SEL, VCO range 700-1400 MHz, PFD range 19-87.5 MHz) that
# ruled out the earlier attempts.
create_generated_clock -name clk_pixel -source [get_ports {clk}] -master_clock clk -divide_by 2 -multiply_by 3 [get_nets {clk_pixel}]

# clk_5x_pixel: 375.000 MHz (FVCO 750 MHz / ODIV1 2), same +1.01%, exact 5x preserved.
create_generated_clock -name clk_5x_pixel -source [get_ports {clk}] -master_clock clk -divide_by 2 -multiply_by 15 [get_nets {clk_5x_pixel}]

# Same CDC shape as pcetang_primer25k.sdc -- see header above.
set_multicycle_path -setup 3 -from [get_clocks {clk_pce}] -to [get_clocks {clk_sdram}]
set_multicycle_path -hold  2 -from [get_clocks {clk_pce}] -to [get_clocks {clk_sdram}]
set_multicycle_path -setup 3 -from [get_clocks {clk_sdram}] -to [get_clocks {clk_pce}]
set_multicycle_path -hold  2 -from [get_clocks {clk_sdram}] -to [get_clocks {clk_pce}]

# Syntax error on the original multi-name single-group form (TA2000) -- Gowin's SDC
# parser wants get_clocks, not a bare space-separated name list, inside one -group.
set_clock_groups -asynchronous -group [get_clocks {clk_pce}] -group [get_clocks {clk_pixel clk_5x_pixel}]
