# MEASUREMENT ONLY (branch measure/*): clk_pce/clk_sdram over-constrained to 44/88 MHz (+2.9%)
# to find the real Fmax ceiling -- the placer stops once timing is met. NEVER ship this SDC.
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
create_generated_clock -name clk_pce -source [get_ports {clk}] -master_clock clk -divide_by 25 -multiply_by 22 [get_nets {clk_pce}]

create_generated_clock -name clk_sdram -source [get_ports {clk}] -master_clock clk -divide_by 25 -multiply_by 44 [get_nets {clk_sdram}]

# clk_pixel: 73.750 MHz (FVCO 1475 MHz / ODIV0 20), -0.67% vs the nominal 74.25 CEA-861
# 1280x720p60 spec -- see pcetang_console60k_hdmi_pll_720p.vhd's header for the real
# PLLA-parameter derivation. Ratio: 50MHz * (MDIV_SEL=59) / (IDIV_SEL=2 * ODIV0_SEL=20).
# EXACT VIDEO LOCK. clk_pixel comes off the CORE PLL's 1200 MHz VCO (ODIV2 = 35), not a
# separate HDMI PLL: 50 * 43/80 = 26.875000 MHz. With H_total 858 that is exactly two
# output lines per source line. See console60k_pll.vhd.
create_generated_clock -name clk_pixel -source [get_ports {clk}] -master_clock clk -divide_by 80 -multiply_by 43 [get_nets {clk_pixel}]

# clk_5x_pixel: 368.750 MHz (FVCO 1475 MHz / ODIV1 4), same -0.67%, exact 5x preserved.
# Ratio: 50MHz * (MDIV_SEL=59) / (IDIV_SEL=2 * ODIV1_SEL=4).
# clk_5x_pixel: 171.4286 MHz (1200 / ODIV3 7) = 50 * 24/7. Exact 5x preserved, and less
# than HALF the 371.875 MHz the old 720p PLL ran at -- the largest serializer margin of
# any configuration this board has been built with.
create_generated_clock -name clk_5x_pixel -source [get_ports {clk}] -master_clock clk -divide_by 16 -multiply_by 43 [get_nets {clk_5x_pixel}]

# 2026-09-07: the four `set_multicycle_path -setup 3 / -hold 2` lines that used to sit
# here are DELETED, not relaxed. They claimed the receiver samples only every 3rd cycle
# on the clk_pce<->clk_sdram crossing. The bridge state machines sample romb_wait EVERY
# cycle, so that was a promise the design never kept -- STA duly reported "0 violations"
# for paths it was not really checking, and hardware behaviour then varied build to build
# for reasons no report showed. clk_sdram is now exactly 2x clk_pce off the same PLL
# (see console60k_pll.vhd), so the crossing is SYNCHRONOUS and the default single-cycle
# relationship is both correct and checkable. If this now reports violations, they are
# real ones that were always there and simply hidden -- fix them, do not re-add these.

set_clock_groups -asynchronous -group [get_clocks {clk_pce}] -group [get_clocks {clk_pixel clk_5x_pixel}]
