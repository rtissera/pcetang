# SPDX-License-Identifier: GPL-3.0-or-later

# Tang Console 60K, pcetang Phase 2 (CD, scandoubler HDMI path). Same clk/clk_pce as
# Phase 1's pcetang_console60k.sdc (console60k_pll.vhd unchanged) -- only clk_pixel/
# clk_5x_pixel differ, since this variant uses pcetang_console60k_hdmi_pll_480p.vhd
# (27.000/135.000 MHz for CEA-861 720x480p60) instead of the 720p pair. See
# docs/OVERHEAD.md sections 5-7 for why this board needs the scandoubler path at all.

create_clock -name clk -period 20.000 [get_ports {clk}]

# clk_pce: 42.857 MHz (FVCO 1200 MHz / ODIV0 28) -- same math as NECTang's own
# console60k_pll.vhd, unchanged here.
create_generated_clock -name clk_pce -source [get_ports {clk}] -master_clock clk -divide_by 7 -multiply_by 6 [get_nets {clk_pce}]

# clk_pixel: 27.000 MHz (FVCO 1350 MHz / ODIV0 50), -0.0999% vs the nominal 27.027
# CEA-861 720x480p60 spec -- see pcetang_console60k_hdmi_pll_480p.vhd's header for the
# real PLLA-parameter derivation (same constraint set the 720p PLL's own header
# documents: PFD 19-87.5 MHz, VCO 700-1400 MHz).
create_generated_clock -name clk_pixel -source [get_ports {clk}] -master_clock clk -divide_by 50 -multiply_by 27 [get_nets {clk_pixel}]

# clk_5x_pixel: 135.000 MHz (FVCO 1350 MHz / ODIV1 10), same -0.0999%, exact 5x preserved.
create_generated_clock -name clk_5x_pixel -source [get_ports {clk}] -master_clock clk -divide_by 10 -multiply_by 27 [get_nets {clk_5x_pixel}]

set_clock_groups -asynchronous -group [get_clocks {clk_pce}] -group [get_clocks {clk_pixel clk_5x_pixel}]
