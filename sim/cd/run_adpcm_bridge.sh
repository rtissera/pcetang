#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand
# ADPCM RAM bridge regression: real cd.vhd + the board's ADPCM arbiter logic + SDRAM model.
# Pass criterion with FIXED=true: never_written=0, stale=0, address_skips=0.
# FIXED=false models the board bridge as it was before 2026-09-17 (expect ~17% / ~23%).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${GHDL_WORK:-$HERE/adpcmwork}"; mkdir -p "$WORK"
G="${GHDL_BIN:-/usr/bin/ghdl-llvm}"
F=(--std=08 -fsynopsys -frelaxed --workdir="$WORK" -Wno-hide -Wno-shared)
cd "$ROOT"
for f in src/pce/common/mem/init/voltab_pkg.vhd src/pce/common/mem/init/huc6260_palette_init_pkg.vhd \
         src/pce/common/mem/bram_gowin.vhd src/pce/common/mem/cd_fifos.vhd src/pce/tg16-mister-rtl/CEGen.vhd \
         src/pce/tg16-mister-rtl/cd/MSM5205.vhd src/pce/tg16-mister-rtl/cd/SCSI.vhd \
         src/pce/tg16-mister-rtl/cd/cd.vhd sim/cd/tb_adpcm_bridge.vhd; do
  "$G" -a "${F[@]}" "$f"
done
"$G" -e "${F[@]}" -o "$WORK/tb_adpcm_bridge" tb_adpcm_bridge
ulimit -s unlimited
# Output goes to a file, and the sim ends on its own: textio to a pipe is block-buffered and
# is LOST if the process is killed by a timeout.
"$WORK/tb_adpcm_bridge" -gFIXED="${FIXED:-true}" -gN_READS="${N_READS:-4000}" \
    --max-stack-alloc=0 --ieee-asserts=disable > "$WORK/result.txt" 2>&1
grep -aE 'RESULT|WRITES|READS' "$WORK/result.txt"
