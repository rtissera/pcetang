#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand

# Real-syscard CD boot simulation on GHDL's LLVM backend -- 8.6x faster than mcode
# (3.5 s vs 30.4 s of wall clock per simulated ms), which is what makes a full 31-sector
# boot reachable in about an hour instead of a day.
#
#   TOC_FILE=de2_toc.txt SECTOR_CNT=80 ./run_cd_boot_llvm.sh syscard3.pce sectors.hex
#
# THREE things this needs that mcode does not:
#   1. libLLVM-18.so.18.1 -- Ubuntu ships the same library as libLLVM.so.18.1, so
#      ghdl-llvm fails to start until you symlink the name it looks for:
#        sudo ln -sf /usr/lib/x86_64-linux-gnu/libLLVM.so.18.1 \
#                    /usr/lib/x86_64-linux-gnu/libLLVM-18.so.18.1 && sudo ldconfig
#   2. --max-stack-alloc=0 and ulimit -s unlimited -- compiled backends cap stack objects
#      at 128 kB and this testbench declares one of 1280 kB.
#   3. PROBE_EN=0 -- the `probe` process uses VHDL-2008 external names, which abort every
#      compiled backend with "NULL access dereferenced" at time 0. cdregmon and cdmon were
#      rewritten onto pce_top's real debug ports and work everywhere; probe was not.
#
# SECTOR_BYTE_CYCLES defaults to 214 = the REAL 2 Mbaud MCU byte pace. Do not lower it to
# make runs finish faster: at 8 the producer is driven 27x faster than any real board and
# the resulting byte loss is an artifact of the testbench, not a bug in the RTL. That
# mistake cost a night.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${GHDL_WORK:-$HERE/bootwork_llvm}"
SYSCARD="${1:?usage: run_cd_boot_llvm.sh <syscard.pce> <sectors.hex> [run_us]}"
SECTORS="${2:?need the sector slice}"
RUN_US="${3:-6000000}"
G="${GHDL_BIN:-/usr/bin/ghdl-llvm}"
mkdir -p "$WORK"
F=(--std=08 -fsynopsys -frelaxed --workdir="$WORK" -Wno-hide -Wno-shared)
cd "$ROOT"
for f in \
  src/pce/common/mem/init/voltab_pkg.vhd src/pce/common/mem/init/huc6260_palette_init_pkg.vhd \
  src/pce/common/mem/bram_gowin.vhd src/pce/common/mem/cd_fifos.vhd \
  src/pce/common/mem/vram0_cache.vhd src/pce/common/mem/vram0_prefetch.vhd \
  sim/boot/sim_stubs.vhd \
  src/pce/tg16-mister-rtl/HUC6280/HUC6280_PKG.vhd src/pce/tg16-mister-rtl/HUC6280/AddSubBCD.vhd \
  src/pce/tg16-mister-rtl/HUC6280/HUC6280_ALU.vhd src/pce/tg16-mister-rtl/HUC6280/HUC6280_AG.vhd \
  src/pce/tg16-mister-rtl/HUC6280/HUC6280_MC.vhd src/pce/tg16-mister-rtl/HUC6280/HUC6280_CPU.vhd \
  src/pce/common/core/psg.vhd src/pce/tg16-mister-rtl/HUC6280/HUC6280.vhd \
  src/pce/tg16-mister-rtl/huc6260.vhd src/pce/tg16-mister-rtl/huc6202.vhd \
  src/pce/tg16-mister-rtl/CEGen.vhd src/pce/common/core/huc6270.vhd \
  src/pce/tg16-mister-rtl/cd/MSM5205.vhd src/pce/tg16-mister-rtl/cd/SCSI.vhd \
  src/pce/tg16-mister-rtl/cd/cd.vhd src/pce/common/core/cd_bridge.vhd \
  src/pce/common/core/pce_top.vhd sim/cd/tb_cd_boot.vhd
do "$G" -a "${F[@]}" "$f"; done
"$G" -e "${F[@]}" -o "$WORK/tb_cd_boot" tb_cd_boot

TOC_ARG=()
[ -n "${TOC_FILE:-}" ] && TOC_ARG=(-gTOC_FILE="$TOC_FILE")

ulimit -s unlimited
"$WORK/tb_cd_boot" "${TOC_ARG[@]}" \
    -gROM_FILE="$SYSCARD" -gSECTOR_FILE="$SECTORS" \
    -gSECTOR_CNT="${SECTOR_CNT:-160}" -gRUN_US="$RUN_US" \
    -gVERBOSE=0 -gAC_BUILD_G=0 -gNO_CD_G=0 \
    -gRUN_PRESS_US="${RUN_PRESS_US:-30000}" \
    -gSECTOR_BYTE_CYCLES="${SECTOR_BYTE_CYCLES:-214}" \
    -gPROBE_EN="${PROBE_EN:-0}" --max-stack-alloc=0 2>&1 \
  | stdbuf -oL grep --line-buffered -avE "metavalue|NUMERIC_STD|numeric_std|std_logic_arith|assertion warning"
