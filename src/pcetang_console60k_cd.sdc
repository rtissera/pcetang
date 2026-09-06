# SPDX-License-Identifier: GPL-3.0-or-later

# Tang Console 60K, pcetang Phase 2 (CD, scandoubler HDMI path). Same clk/clk_pce as
# Phase 1's pcetang_console60k.sdc (console60k_pll.vhd unchanged) -- only clk_pixel/
# clk_5x_pixel differ. See docs/OVERHEAD.md sections 5-7 for why this board needs the
# scandoubler path at all.
#
# 2026-09-06: clk_pixel/clk_5x_pixel switched from pcetang_console60k_hdmi_pll_480p.vhd
# (27.000/135.000 MHz, CEA-861 720x480p60) to pcetang_console60k_hdmi_pll_720p.vhd
# (73.750/368.750 MHz, CEA-861 1280x720p60) -- pure debug, some real HDMI sinks reject
# 480p60 outright. See that file's own header for the real PLLA derivation.
#
# clk_sdram (2026-08-28, added when ROM/CD-RAM moved onto SDRAM): same console60k_pll
# instance and same 120 MHz math as pcetang_console60k.sdc's own clk_sdram -- see that
# file's header for the real, hard-won precedent this multicycle fix is copied from
# verbatim (Primer 25K originally, 136 setup / 100 hold violations from an undeclared
# generated clock analyzed as ordinary same-clock logic).

create_clock -name clk -period 20.000 [get_ports {clk}]

# clk_pce: 42.857 MHz (FVCO 1200 MHz / ODIV0 28) -- same math as NECTang's own
# console60k_pll.vhd, unchanged here.
create_generated_clock -name clk_pce -source [get_ports {clk}] -master_clock clk -divide_by 7 -multiply_by 6 [get_nets {clk_pce}]

create_generated_clock -name clk_sdram -source [get_ports {clk}] -master_clock clk -divide_by 5 -multiply_by 12 [get_nets {clk_sdram}]

# clk_pixel: 73.750 MHz (FVCO 1475 MHz / ODIV0 20), -0.67% vs the nominal 74.25 CEA-861
# 1280x720p60 spec -- see pcetang_console60k_hdmi_pll_720p.vhd's header for the real
# PLLA-parameter derivation. Ratio: 50MHz * (MDIV_SEL=59) / (IDIV_SEL=2 * ODIV0_SEL=20).
create_generated_clock -name clk_pixel -source [get_ports {clk}] -master_clock clk -divide_by 40 -multiply_by 59 [get_nets {clk_pixel}]

# clk_5x_pixel: 368.750 MHz (FVCO 1475 MHz / ODIV1 4), same -0.67%, exact 5x preserved.
# Ratio: 50MHz * (MDIV_SEL=59) / (IDIV_SEL=2 * ODIV1_SEL=4).
create_generated_clock -name clk_5x_pixel -source [get_ports {clk}] -master_clock clk -divide_by 8 -multiply_by 59 [get_nets {clk_5x_pixel}]

set_multicycle_path -setup 3 -from [get_clocks {clk_pce}] -to [get_clocks {clk_sdram}]
set_multicycle_path -hold  2 -from [get_clocks {clk_pce}] -to [get_clocks {clk_sdram}]
set_multicycle_path -setup 3 -from [get_clocks {clk_sdram}] -to [get_clocks {clk_pce}]
set_multicycle_path -hold  2 -from [get_clocks {clk_sdram}] -to [get_clocks {clk_pce}]

set_clock_groups -asynchronous -group [get_clocks {clk_pce}] -group [get_clocks {clk_pixel clk_5x_pixel}]
