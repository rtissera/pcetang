#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand

# SCSI.vhd phase-line property test. See the header of tb_scsi_phase.vhd.
#   ./run_scsi_phase.sh [-gTURNAROUND_US=...]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${GHDL_WORK:-$HERE/phwork}"
mkdir -p "$WORK"
F=(--std=08 -fsynopsys -frelaxed --workdir="$WORK" -Wno-hide -Wno-shared)
cd "$ROOT"
ghdl -a "${F[@]}" src/pce/common/mem/init/voltab_pkg.vhd
ghdl -a "${F[@]}" src/pce/common/mem/init/huc6260_palette_init_pkg.vhd
ghdl -a "${F[@]}" src/pce/common/mem/bram_gowin.vhd
ghdl -a "${F[@]}" src/pce/common/mem/cd_fifos.vhd
ghdl -a "${F[@]}" src/pce/tg16-mister-rtl/cd/SCSI.vhd
ghdl -a "${F[@]}" sim/cd/tb_scsi_phase.vhd
ghdl -r "${F[@]}" tb_scsi_phase "$@" 2>&1 | stdbuf -oL grep --line-buffered -avE "metavalue|NUMERIC_STD"
