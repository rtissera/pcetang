# SPDX-License-Identifier: GPL-3.0-or-later

# RETRY 2026-08-30 (real, not reference-only) -- see pcetang_nano20k_cd.vhd's own header
# for why this is being retried now (alternate PnR algorithm + ROM also moved to SDRAM)
# after the first attempt's real regressions (pcetang_nano20k_cd_attempt.md).
#
# pcetang Nano 20K CD attempt: CD-RAM/ADPCM RAM/Arcade Card RAM offloaded to the
# on-package SDRAM via sdram32.sv's newly write-capable, real-bank port B, plus the
# scandoubler HDMI path (pce2hdmi_sd.sv) already proven on Primer 25K plain -- see
# pcetang_nano20k_cd.vhd's own header for the full scope and named exclusions (ROM stays
# on-chip, SGX out of scope, CDDA_FIFO deferred). Run from the repo root:
# gw_sh build_nano20k_cd.tcl

set_device GW2AR-LV18QN88C8/I7 -name GW2AR-18C

add_file src/pce/common/mem/init/voltab_pkg.vhd
add_file src/pce/common/mem/init/huc6260_palette_init_pkg.vhd
add_file src/pce/common/mem/bram_gowin.vhd
add_file src/pce/common/mem/cd_fifos.vhd
add_file src/pce/common/mem/dpram9_dpb_wm01.vhd
add_file src/pce/common/mem/dpram8x16_dpb_wm01.vhd
add_file src/pce/common/mem/vram0_cache.vhd
# vram0_prefetch.vhd (2026-08-30): BAT+CG0/CG1 retried on this build -- see
# pcetang_nano20k_cd.vhd's own generic-map comment. Omitting this file while the
# generic map enables it is the exact class of bug that silently black-boxed Primer
# 25K CD's own BAT+CG for a whole session (EX4760) -- don't repeat it here.
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
add_file src/pce/common/pll/nano20k_pll.vhd
add_file src/pce/common/mem/sdram32.sv
add_file src/pcetang_nano20k_cd.vhd
add_file src/pcetang_nano20k.cst
add_file src/pcetang_nano20k.sdc

set_option -synthesis_tool gowinsynthesis
set_option -output_base_name pcetang_nano20k_cd
set_option -verilog_std sysv2017
set_option -vhdl_std vhd2008
set_option -top_module pcetang_nano20k_cd
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -use_done_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_i2c_as_gpio 1
set_option -use_jtag_as_gpio 1
set_option -bit_compress 1

# Alternate PnR algorithm (2026-08-30): same lever that recovered real margin on every
# other board this session -- see pcetang_status_matrix.md lever 13.
set_option -place_option 2
set_option -route_option 1

run all
