# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand

# pcetang Phase 1: Tang Primer 25K, TangCore-integrated (iosys_bl616), HuCard-only,
# EXT_VRAM0 (real Tang SDRAM V1.3 PMOD). Run from the repo root: gw_sh build_primer25k.tcl

set_device GW5A-LV25MG121NC1/I0 -name GW5A-25A

add_file src/pce/common/mem/init/voltab_pkg.vhd
add_file src/pce/common/mem/init/huc6260_palette_init_pkg.vhd
add_file src/pce/common/mem/bram_gowin.vhd
add_file src/pce/common/mem/cd_fifos.vhd
add_file src/pce/common/mem/dpram9_dpb_wm01.vhd
add_file src/pce/common/mem/dpram8x16_dpb_wm01.vhd
add_file src/pce/common/mem/vram0_cache.vhd
# PCE PORT (2026-08-29): was missing -- pcetang_primer25k_cd.vhd's generic map sets
# VRAM0_PREFETCH=>1/VRAM0_CG_PREFETCH=>1 but this file never compiled vram0_prefetch.vhd,
# so PREFETCH0 was silently black-boxed (EX4760, confirmed in a real gw_sh log --
# see pcetang_status_matrix.md's Primer 25K CD BAT/CG finding). This build's own real
# BAT+CG numbers have never actually been measured until this fix.
add_file src/pce/common/mem/vram0_prefetch.vhd
add_file src/pce/tg16-mister-rtl/HUC6280/HUC6280_PKG.vhd
add_file src/pce/tg16-mister-rtl/HUC6280/AddSubBCD.vhd
add_file src/pce/tg16-mister-rtl/HUC6280/HUC6280_ALU.vhd
add_file src/pce/tg16-mister-rtl/HUC6280/HUC6280_AG.vhd
add_file src/pce/tg16-mister-rtl/HUC6280/HUC6280_MC.vhd
add_file src/pce/tg16-mister-rtl/HUC6280/HUC6280_CPU.vhd
add_file src/pce/common/core/psg.vhd
add_file src/pce/tg16-mister-rtl/HUC6280/HUC6280.vhd
add_file src/pce/tg16-mister-rtl/huc6260.vhd
add_file src/pce/tg16-mister-rtl/huc6202.vhd
add_file src/pce/tg16-mister-rtl/CEGen.vhd
add_file src/pce/common/core/arcade.sv
add_file src/pce/common/core/huc6270.vhd
add_file src/pce/tg16-mister-rtl/cd/MSM5205.vhd
add_file src/pce/tg16-mister-rtl/cd/SCSI.vhd
add_file src/pce/tg16-mister-rtl/cd/cd.vhd
add_file src/pce/common/core/cd_bridge.vhd
add_file src/pce/common/core/pce_top.vhd

add_file src/iosys/uart_fixed.v
add_file src/iosys/gowin_dpb_menu.v
add_file src/iosys/textdisp.v
add_file src/input/dualshock_controller.v
add_file src/input/controller_ds2.sv
add_file src/iosys/iosys_bl616.v
add_file src/hdmi2/audio_clock_regeneration_packet.sv
add_file src/hdmi2/audio_info_frame.sv
add_file src/hdmi2/audio_sample_packet.sv
add_file src/hdmi2/auxiliary_video_information_info_frame.sv
add_file src/hdmi2/packet_assembler.sv
add_file src/hdmi2/packet_picker.sv
add_file src/hdmi2/serializer.sv
add_file src/hdmi2/source_product_description_info_frame.sv
add_file src/hdmi2/tmds_channel.sv
add_file src/hdmi2/hdmi.sv

add_file src/pce2hdmi_sd.sv
add_file src/pcetang_console60k_hdmi_pll_480p.vhd
add_file src/pce/common/pll/primer25k_pll.vhd
add_file src/pce/common/mem/sdram.sv
add_file src/pcetang_primer25k_cd.vhd
add_file src/pcetang_primer25k.cst
add_file src/pcetang_primer25k_cd.sdc

set_option -synthesis_tool gowinsynthesis
set_option -output_base_name pcetang_primer25k_cd
set_option -verilog_std sysv2017
set_option -vhdl_std vhd2008
set_option -top_module pcetang_primer25k_cd
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -use_done_as_gpio 1
set_option -use_cpu_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_i2c_as_gpio 1
set_option -use_jtag_as_gpio 1
set_option -bit_compress 1

# Alternate PnR algorithm (2026-08-30): same lever that recovered Nano 20K plain's
# clk_pce margin (+0.019%->+1.85%, see pcetang_status_matrix.md lever 13) for free --
# place_option/route_option default to 0 (compile-speed/congestion) on every board in
# this project, never tried otherwise. Pure PnR-algorithm change, no netlist edit.
# place_option 1 ("routability priority"), 2026-09-12. Swept 0/1/2 on identical trees at
# c525c16, all real gw_sh runs:
#   0 : closes, clk_pce 42.864 MHz, +0.016% margin  <- 7 kHz, effectively none
#   1 : closes, clk_pce 43.081 MHz, +0.523% margin  <- this
#   2 : FAILS, PR0004, 20 unrouted nets
# Worth measuring because this session's CD work narrowed option 0's margin from +0.266%
# (c1cba4f, measured in a worktree) to +0.016% while logic utilisation went DOWN, 93% ->
# 92% -- so it was placement variance, not area pressure, and the placer just needed a
# different objective. Option 1 now beats the pre-session baseline as well.
# 2026-09-17: back to place_option 0. The ADPCM bridge fix (f2b54f6) left place_option 1
# with 16 unrouted nets (PR0004), deterministic over 2 runs, although it uses FEWER LUTs
# than the pre-fix tag (21459 vs 21544) -- placement variance again, not capacity. The
# pre-fix tag still routes with 1 but at +0.002% clk_pce. place_option 0 on HEAD: 0/0,
# clk_pce 43.090/42.857 MHz (+0.54%), clk_sdram 120.78/120, Logic 94%, BSRAM 36/56.
set_option -place_option 0
set_option -route_option 0
# 2026-09-06 real fix, CONFIRMED by a 3-way sweep: place_option 1 (below) stopped routing
# this board once the sdram.sv port-B deadlock fix landed -- ERROR (PR0004), 15 unrouted
# nets, deterministic. Swept place_option 0/2 and route_option 1 on identical trees:
# place_option 0 routes clean (0 errors, 0 setup/hold violations, real bitstream),
# place_option 2 still errors. So this board is back on the project-wide default. The
# place_option 1 history below is kept because it is the record of why it was ever 1, and
# because the same lever may be needed again -- re-read it before changing this line.
# 2026-08-31c real fix, CONFIRMED: place_option 1 = "routability priority" (per Gowin's
# own rtlplaceoptions.xml -- place_option 2, the prior setting, is "timing priority").
# The real failure signature here was unrouted nets (2321, then 1652 after a real LUT
# trim to cd_bridge.vhd, both deterministic across repeated runs), not a timing miss --
# Nano 20K routed clean at 89% Logic while Primer 25K failed at 88%, so raw utilization
# was never the real discriminator. Routability-priority placement (paired with
# route_option 0, congestion-based routing) closes it outright: real gw_sh PASS, 0/0
# setup/hold violations, clk_pce +4.18% margin (44.647MHz vs. the 42.857MHz constraint) --
# a comfortable, clean margin, not razor-thin like Console 60K/Nano 20K CD's own real
# passes on this same feature bundle. See pcetang_cd_scsi_plan.md.

run all
