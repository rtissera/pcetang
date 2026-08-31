# SPDX-License-Identifier: GPL-3.0-or-later

# pcetang Phase 2: Tang Console 60K, CD/SCSI/ADPCM elaborated, full 64KB ADPCM RAM
# (real CD-ROM2 spec) via a scandoubler-based HDMI path (pce2hdmi_sd.sv) instead of
# pce2hdmi.sv's full-frame capture -- see docs/OVERHEAD.md sections 5-7 for why.
# Run: gw_sh build_console60k_cd.tcl

set_device GW5AT-LV60PG484AC1/I0 -name GW5AT-60B

# PCE chip-core RTL, vendored from NECTang (see src/pce/README.md) -- same file order
# NECTang's own files_common.tcl uses (entity-before-instantiation for Gowin's parser).
add_file src/pce/common/mem/init/voltab_pkg.vhd
add_file src/pce/common/mem/init/huc6260_palette_init_pkg.vhd
add_file src/pce/common/mem/bram_gowin.vhd
add_file src/pce/common/mem/cd_fifos.vhd
add_file src/pce/common/mem/dpram9_dpb_wm01.vhd
add_file src/pce/common/mem/dpram8x16_dpb_wm01.vhd
add_file src/pce/common/mem/vram0_cache.vhd
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
add_file src/pce/common/core/cheatcodes.sv
add_file src/pce/common/core/huc6270.vhd
add_file src/pce/tg16-mister-rtl/cd/MSM5205.vhd
add_file src/pce/tg16-mister-rtl/cd/SCSI.vhd
add_file src/pce/tg16-mister-rtl/cd/cd.vhd
add_file src/pce/common/core/cd_bridge.vhd
add_file src/pce/common/core/pce_top.vhd

# TangCore integration layer, vendored from nestang (see THIRD_PARTY_LICENSES.md)
add_file src/iosys/uart_fixed.v
add_file src/iosys/gowin_dpb_menu.v
add_file src/iosys/textdisp.v
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

# This repo's own new RTL
add_file src/pce2hdmi_sd.sv
add_file src/pce/common/mem/sdram.sv
add_file src/pcetang_console60k_hdmi_pll_480p.vhd
add_file src/pce/common/pll/console60k_pll.vhd
add_file src/pcetang_console60k_cd.vhd
add_file src/pcetang_console60k.cst
add_file src/pcetang_console60k_cd.sdc

set_option -synthesis_tool gowinsynthesis
set_option -output_base_name pcetang_console60k_cd
set_option -verilog_std sysv2017
set_option -vhdl_std vhd2008
set_option -top_module pcetang_console60k_cd
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -use_done_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_i2c_as_gpio 1
set_option -use_jtag_as_gpio 1
set_option -bit_compress 1

# Alternate PnR algorithm (2026-08-30): same lever that recovered Nano 20K plain's
# clk_pce margin (+0.019%->+1.85%, see pcetang_status_matrix.md lever 13) for free --
# place_option/route_option default to 0 (compile-speed/congestion) on every board in
# this project, never tried otherwise. Pure PnR-algorithm change, no netlist edit.
set_option -place_option 2
set_option -route_option 0
# route_option forced 0 (2026-08-30), NOT project-standard 1 -- CONFIRMED real fix for
# a 2h19m routing-phase-0 hang with the CDDA-shrink revival live on this board (96%+
# BSRAM baseline, tightest in project). route_option 1 (timing-priority routing) is a
# real congestion trigger here; route_option 0 (default, congestion-based) completes
# full PnR clean in ~2min, 0 setup/hold violations. Real cost: clk_pce margin dropped
# from the pre-CDDA +6.21% (with route_option 1) to +0.84% (with route_option 0 +
# CDDA) -- board-specific, do not "fix" by reverting to 1 without re-testing for the
# hang. See pcetang_status_matrix.md lever 18.

# 2026-08-31d/e real margin-recovery attempts against the current real critical path
# (ALUCtrl_0_s23/DO[6], HuC6280 microcode, fanning out to many register clock-enables,
# near-zero logic, almost pure fanout/routing delay) -- ALL TRIED, ALL REAL NO-OPS,
# reverted:
#   -timing_driven 1 + -correct_hold_violation 0  -> bit-identical (42.858MHz, 0/0)
#   -route_maxfan 8                                -> bit-identical (42.858MHz, 0/0)
# Baseline (no extra flags) is the best real result found: 42.858MHz, +0.002% margin,
# 0/0 violations. Real, razor-thin, deterministic. See pcetang_status_matrix.md lever 24
# and advisor consult 2026-08-31e for the full record.

run all
