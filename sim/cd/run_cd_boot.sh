#!/usr/bin/env bash
# Real-syscard CD boot simulation: pce_top + cd_bridge + a real disc's sectors.
#
# sim/boot/run.sh ties the whole CD interface off (CD_STAT => x"00", CD_COMM => open,
# CD_RAM_DI => x"FF"), so it can never reproduce a CD fault -- the boot program would be
# loaded into a tied-off CD-RAM. This runs the actual system card on the actual pce_top
# against the actual cd_bridge, fed from a flat sector slice extracted with chdman.
#
#   ./run_cd_boot.sh <syscard.pce> <sectors.hex> [run_us]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${GHDL_WORK:-$HERE/bootwork}"
SYSCARD="${1:?usage: run_cd_boot.sh <syscard.pce> <sectors.hex> [run_us]}"
SECTORS="${2:?need the sector slice}"
RUN_US="${3:-400000}"

mkdir -p "$WORK"
GHDL_FLAGS=(--std=08 -fsynopsys -frelaxed --workdir="$WORK" -Wno-hide -Wno-shared)
a() { ghdl -a "${GHDL_FLAGS[@]}" "$@"; }

cd "$ROOT"
a src/pce/common/mem/init/voltab_pkg.vhd
a src/pce/common/mem/init/huc6260_palette_init_pkg.vhd
a src/pce/common/mem/bram_gowin.vhd
a src/pce/common/mem/cd_fifos.vhd
a src/pce/common/mem/vram0_cache.vhd
a src/pce/common/mem/vram0_prefetch.vhd
a sim/boot/sim_stubs.vhd
a src/pce/tg16-mister-rtl/HUC6280/HUC6280_PKG.vhd
a src/pce/tg16-mister-rtl/HUC6280/AddSubBCD.vhd
a src/pce/tg16-mister-rtl/HUC6280/HUC6280_ALU.vhd
a src/pce/tg16-mister-rtl/HUC6280/HUC6280_AG.vhd
a src/pce/tg16-mister-rtl/HUC6280/HUC6280_MC.vhd
a src/pce/tg16-mister-rtl/HUC6280/HUC6280_CPU.vhd
a src/pce/common/core/psg.vhd
a src/pce/tg16-mister-rtl/HUC6280/HUC6280.vhd
a src/pce/tg16-mister-rtl/huc6260.vhd
a src/pce/tg16-mister-rtl/huc6202.vhd
a src/pce/tg16-mister-rtl/CEGen.vhd
a src/pce/common/core/huc6270.vhd
a src/pce/tg16-mister-rtl/cd/MSM5205.vhd
a src/pce/tg16-mister-rtl/cd/SCSI.vhd
a src/pce/tg16-mister-rtl/cd/cd.vhd
a src/pce/common/core/cd_bridge.vhd
a src/pce/common/core/pce_top.vhd
a sim/cd/tb_cd_boot.vhd

ghdl -r "${GHDL_FLAGS[@]}" tb_cd_boot \
    -gROM_FILE="$SYSCARD" \
    -gSECTOR_FILE="$SECTORS" \
    -gRUN_US="$RUN_US" \
    -gROM_SZ_G="000001000000" \
    -gSGX_G="'0'" \
    -gCD_EN_G="'1'" \
    -gVERBOSE=0 \
    -gAC_BUILD_G=0 \
    -gNO_CD_G=0 -gRUN_PRESS_US="${RUN_PRESS_US:-30000}" -gSECTOR_BYTE_CYCLES="${SECTOR_BYTE_CYCLES:-214}"
