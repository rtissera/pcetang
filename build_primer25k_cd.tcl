# SPDX-License-Identifier: GPL-3.0-or-later

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
add_file src/pce/common/pll/console60k_pll.vhd
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
set_option -place_option 2
set_option -route_option 1

run all
