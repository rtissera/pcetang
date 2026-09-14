#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand
#
#   ./run_cd_endcmd.sh [-gSECTORS=8] [-gSECTOR_LAT_US=10000] [-gCPU_CYCLES=43] ...
#
# The FIRST testbench that puts cd_bridge and SCSI.vhd together. tb_cd_bridge stubs the
# SCSI side, tb_scsi_phase stubs the bridge, and the suspected defect is in the handshake
# BETWEEN them -- so neither can see it. See tb_cd_endcmd.vhd's header.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
G="${GHDL_BIN:-/usr/bin/ghdl-llvm}"
WORK="${GHDL_WORK:-$HERE/endwork}"
mkdir -p "$WORK"
F=(--std=08 -fsynopsys -frelaxed --workdir="$WORK" -Wno-hide -Wno-shared)
cd "$ROOT"
for f in src/pce/common/mem/init/voltab_pkg.vhd \
         src/pce/common/mem/init/huc6260_palette_init_pkg.vhd \
         src/pce/common/mem/bram_gowin.vhd src/pce/common/mem/cd_fifos.vhd \
         src/pce/tg16-mister-rtl/cd/SCSI.vhd src/pce/common/core/cd_bridge.vhd \
         sim/cd/tb_cd_endcmd.vhd; do
  "$G" -a "${F[@]}" "$f"
done
ulimit -s unlimited
"$G" -e "${F[@]}" -o "$WORK/tb" tb_cd_endcmd
# stdbuf on the SIM too: GHDL block-buffers its own report output into a pipe, so a
# long run shows nothing at all until it exits -- progress reports are invisible.
stdbuf -oL -eL "$WORK/tb" "$@" --max-stack-alloc=0 --ieee-asserts=disable 2>&1 \
  | stdbuf -oL grep --line-buffered -avE "metavalue|NUMERIC_STD|numeric_std"
