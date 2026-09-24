#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand
# Replay a real game's ADPCM playback (golden trace from beetle-pce-fast) against cd.vhd.
# Pass: "PASS: cd.vhd plays exactly what beetle played".
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${GHDL_WORK:-$HERE/adpcmgoldwork}"; mkdir -p "$WORK"
G="${GHDL_BIN:-/usr/bin/ghdl-llvm}"
F=(--std=08 -fsynopsys -frelaxed --workdir="$WORK" -Wno-hide -Wno-shared)
cd "$ROOT"

# The ADPCM fixtures are a real game's disc data (Konami), so they are NOT stored in this
# repository -- only the sector numbers they live at. Regenerate them from your own dump:
#     scripts/make_adpcm_golden.py <game.chd|game.bin>
_need="$ROOT/sim/cd/golden/adpcm_rondo_play8/ram.hex"
if [ ! -f "$_need" ]; then
  echo "error: missing ADPCM golden fixture: ${_need#$ROOT/}" >&2
  echo "       These are real disc data and are not redistributed. Regenerate with:" >&2
  echo "         scripts/make_adpcm_golden.py \"Akumajou Dracula X - Chi no Rondo.chd\"" >&2
  exit 2
fi
for f in src/pce/common/mem/init/voltab_pkg.vhd src/pce/common/mem/init/huc6260_palette_init_pkg.vhd \
         src/pce/common/mem/bram_gowin.vhd src/pce/common/mem/cd_fifos.vhd src/pce/tg16-mister-rtl/CEGen.vhd \
         src/pce/tg16-mister-rtl/cd/MSM5205.vhd src/pce/tg16-mister-rtl/cd/SCSI.vhd \
         src/pce/tg16-mister-rtl/cd/cd.vhd sim/cd/tb_adpcm_golden.vhd; do
  "$G" -a "${F[@]}" "$f"
done
"$G" -e "${F[@]}" -o "$WORK/tb_adpcm_golden" tb_adpcm_golden
ulimit -s unlimited
# Written to a file and left to end on its own: textio to a pipe is block-buffered and is
# lost if a timeout kills the process.
"$WORK/tb_adpcm_golden" -gDIR="${DIR:-sim/cd/golden/adpcm_rondo_play8}" -gFAST_FREQ="${FAST_FREQ:-true}" -gPCM_OUT="$WORK/rtl_pcm.txt" \
    --max-stack-alloc=0 --ieee-asserts=disable > "$WORK/result.txt" 2>&1
grep -aE 'loaded|RESULT|STOPPED|PASS|FAIL|error' "$WORK/result.txt"
