# SPDX-License-Identifier: GPL-3.0-or-later

# Tang Nano 20K, pcetang Phase 1. Two real rPLLs (nano20k_pll.vhd, unchanged from
# NECTang): core master (clk_pce, 43.2 MHz) and HDMI (135/27 MHz, both now real loads
# via sdram32.sv and pce2hdmi.sv respectively -- unlike NECTang's own bring-ups, which
# never load both at once). The 135 MHz net is declared once, as clk_sdram -- see below
# for why not also as clk_135 (nano20k_pll.vhd's own port name for the same net).
#
# Learned from Primer 25K's real first-attempt failure (136/100 violations, see
# docs/ARCHITECTURE.md): a clk_sdram/clk_pce CDC left undeclared analyzes as ordinary
# same-clock logic and fails hard. Applying NECTang's own proven
# nano20k_core_test.sdc's exact CDC constraints here from the start, not discovering it
# the same way twice.

create_clock -name clk -period 37.037 [get_ports {clk}]

create_generated_clock -name clk_pce   -source [get_ports {clk}] -master_clock clk -divide_by 5 -multiply_by 8 [get_nets {clk_pce}]
create_generated_clock -name clk_sdram -source [get_ports {clk}] -master_clock clk -multiply_by 5 [get_nets {clk_sdram}]

# vram0_cache.vhd drives sdram32's RAM_A_* directly from the clk_pce domain -- same CDC
# shape as NECTang's own nano20k_core_test.sdc. Both directions needed -- omitting
# clk_sdram->clk_pce was a real bug NECTang's own history already hit once.
set_multicycle_path -setup 3 -from [get_clocks {clk_pce}] -to [get_clocks {clk_sdram}]
set_multicycle_path -hold  2 -from [get_clocks {clk_pce}] -to [get_clocks {clk_sdram}]
set_multicycle_path -setup 3 -from [get_clocks {clk_sdram}] -to [get_clocks {clk_pce}]
set_multicycle_path -hold  2 -from [get_clocks {clk_sdram}] -to [get_clocks {clk_pce}]

# HDMI 5x/TMDS clock: clk_135 is the SAME PHYSICAL NET as clk_sdram (both driven from
# clk_135_i inside nano20k_pll.vhd) -- first attempt declared it separately, matching
# nano20k_clocks.sdc's pattern, but that file never loads clk_sdram at the same time.
# Loading both here, Gowin's synthesis merges the two same-value nets under one name
# (clk_sdram, processed first) -- real gw_sh measured `ERROR (TA2003): Can't set timing
# constraint to object clk_135`, the name simply doesn't survive to PnR. Deriving clk_27
# from clk_sdram instead (same signal, correct name) -- no clk_135 declaration at all.
create_generated_clock -name clk_27 -source [get_nets {clk_sdram}] -master_clock clk_sdram -divide_by 5 [get_nets {clk_27}]

# pce2hdmi.sv crosses clk_pce -> clk_27 only through its own dual-port BRAM frame
# buffer (same safe async pattern as Console 60K/Primer 25K's clk_pce/clk_pixel split) --
# asynchronous, not a fixed-ratio relationship despite sharing a crystal. clk_sdram is
# already related to clk_pce via the multicycle exceptions above, not asynchronous.
set_clock_groups -asynchronous -group [get_clocks {clk_pce}] -group [get_clocks {clk_27}]
