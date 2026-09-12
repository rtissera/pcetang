#!/usr/bin/env bash
# cd_bridge unit + golden-vector tests. Seconds to run, no ROM, no disc image.
#   ./run_cd_bridge.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${GHDL_WORK:-$HERE/brwork}"
mkdir -p "$WORK"
F=(--std=08 -fsynopsys -frelaxed --workdir="$WORK" -Wno-hide -Wno-shared)
cd "$ROOT"
ghdl -a "${F[@]}" src/pce/common/mem/init/voltab_pkg.vhd
ghdl -a "${F[@]}" src/pce/common/mem/init/huc6260_palette_init_pkg.vhd
ghdl -a "${F[@]}" src/pce/common/mem/bram_gowin.vhd
ghdl -a "${F[@]}" src/pce/common/mem/cd_fifos.vhd
ghdl -a "${F[@]}" src/pce/common/core/cd_bridge.vhd
ghdl -a "${F[@]}" sim/cd/tb_cd_bridge.vhd
ghdl -r "${F[@]}" tb_cd_bridge "$@" 2>&1 | grep -avE "metavalue|NUMERIC_STD"
