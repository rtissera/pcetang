#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ADPCM DMA-from-CD load vs beetle-pce-fast golden (Rondo's first load). SECTORS=1..32.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${GHDL_WORK:-$HERE/adpcmdmawork}"; mkdir -p "$WORK"
G="${GHDL_BIN:-/usr/bin/ghdl-llvm}"
F=(--std=08 -fsynopsys -frelaxed --workdir="$WORK" -Wno-hide -Wno-shared)
cd "$ROOT"

# The ADPCM fixtures are a real game's disc data (Konami), so they are NOT stored in this
# repository -- only the sector numbers they live at. Regenerate them from your own dump:
#     scripts/make_adpcm_golden.py <game.chd|game.bin>
_need="$ROOT/sim/cd/golden/adpcm_rondo_dma1/sectors.hex"
if [ ! -f "$_need" ]; then
  echo "error: missing ADPCM golden fixture: ${_need#$ROOT/}" >&2
  echo "       These are real disc data and are not redistributed. Regenerate with:" >&2
  echo "         scripts/make_adpcm_golden.py \"Akumajou Dracula X - Chi no Rondo.chd\"" >&2
  exit 2
fi
python3 sim/cd/cosim/check_arbiter_drift.py > /dev/null || { python3 sim/cd/cosim/check_arbiter_drift.py; exit 1; }
for f in src/pce/common/mem/init/voltab_pkg.vhd src/pce/common/mem/init/huc6260_palette_init_pkg.vhd \
         src/pce/common/mem/bram_gowin.vhd src/pce/common/mem/cd_fifos.vhd src/pce/tg16-mister-rtl/CEGen.vhd \
         src/pce/tg16-mister-rtl/cd/MSM5205.vhd src/pce/tg16-mister-rtl/cd/SCSI.vhd \
         src/pce/tg16-mister-rtl/cd/cd.vhd src/pce/common/core/cd_bridge.vhd \
         sim/cd/cosim/portc_arbiter.vhd sim/cd/tb_adpcm_dma.vhd; do
  "$G" -a "${F[@]}" "$f"
done
"$G" -e "${F[@]}" -o "$WORK/tb_adpcm_dma" tb_adpcm_dma
ulimit -s unlimited
"$WORK/tb_adpcm_dma" -gSECTORS="${SECTORS:-4}" -gDMA_REG="${DMA_REG:-2}" --max-stack-alloc=0 --ieee-asserts=disable \
    --stop-time=${STOP_MS:-400}ms > "$WORK/result.txt" 2>&1 || true
grep -aE 'RESULT|PASS|FAIL|TIMEOUT|error|STATUS not|^HB' "$WORK/result.txt"
