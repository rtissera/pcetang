# SPDX-License-Identifier: GPL-3.0-or-later

# pcetang Phase 1: Tang Nano 20K, TangCore-integrated (iosys_bl616), HuCard-only,
# EXT_VRAM0 (on-package sdram32.sv), HDMI via the chassis's existing 720x576-class
# clock pair reinterpreted as NTSC 720x480p60 (VIDEO_ID_CODE=2) -- see
# pcetang_nano20k.vhd's header. Run from the repo root: gw_sh build_nano20k.tcl

set_device GW2AR-LV18QN88C8/I7 -name GW2AR-18C

add_file src/pce/common/mem/init/voltab_pkg.vhd
add_file src/pce/common/mem/init/huc6260_palette_init_pkg.vhd
add_file src/pce/common/mem/bram_gowin.vhd
add_file src/pce/common/mem/cd_fifos.vhd
add_file src/pce/common/mem/dpram9_dpb_wm01.vhd
add_file src/pce/common/mem/dpram8x16_dpb_wm01.vhd
add_file src/pce/common/mem/vram0_cache.vhd
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
add_file src/pcetang_nano20k.vhd
add_file src/pcetang_nano20k.cst
add_file src/pcetang_nano20k.sdc

set_option -synthesis_tool gowinsynthesis
set_option -output_base_name pcetang_nano20k
set_option -verilog_std sysv2017
set_option -vhdl_std vhd2008
set_option -top_module pcetang_nano20k
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -use_done_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_i2c_as_gpio 1
set_option -use_jtag_as_gpio 1
set_option -bit_compress 1

run all
