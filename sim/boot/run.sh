#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand
#
# Real-ROM boot simulation of pce_top. See tb_pce_boot.vhd's header for what this does
# and does NOT prove.
#
#   ./run.sh <rom.pce> [run_us] [verbose] [sgx] [cd_en] [trace_n] [trace_skip] [rom_lat]
#
# Analysed with --std=08 (the testbench needs VHDL-2008 external names to tap pce_top's
# internal CPU bus without modifying any RTL) and -fsynopsys (the donor uses
# ieee.std_logic_unsigned throughout).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# Override to run several configurations concurrently -- each needs its own analysis
# directory or they clobber each other's work-obj08.cf.
WORK="${GHDL_WORK:-$HERE/work}"

ROM="${1:?usage: run.sh <rom.pce> [run_us] [verbose] [sgx] [cd_en]}"
RUN_US="${2:-120000}"
VERBOSE="${3:-1}"
SGX="${4:-1}"
CD_EN="${5:-0}"
TRACE_N="${6:-0}"
TRACE_SKIP="${7:-0}"
ROM_LAT="${8:-0}"
DUMP_AFTER_VDC="${9:-0}"
AC_BUILD="${10:-1}"
NO_CD="${11:-0}"

# tb_pce_boot's ROM_SZ_G generic defaults to X"080" (512K). Every run before 2026-09-18
# used that default regardless of the actual file, so any ROM that is not 512K was
# simulated with the WRONG pce_top ROM_A mapping -- a 1MB .sgx mirrored its lower half
# over its upper half and could not possibly boot, for a reason the board does not have.
# Derive the bucket from the real file size instead, using exactly the same thresholds
# as pcetang_console60k_cd.vhd's rom_sz_r (search "dynamic bucket rounding" there), so
# sim and board agree by construction. Override with ROM_SZ=0xNNN if needed.
rom_bytes=$(stat -c %s "$ROM")
# A 512-byte copier header is stripped by the firmware before the core ever sees it.
if [ $(( rom_bytes % 1024 )) -eq 512 ]; then rom_bytes=$(( rom_bytes - 512 )); fi
if   [ "$rom_bytes" -le 131072 ];  then rom_sz_default=020
elif [ "$rom_bytes" -le 262144 ];  then rom_sz_default=040
elif [ "$rom_bytes" -le 393216 ];  then rom_sz_default=060
elif [ "$rom_bytes" -le 524288 ];  then rom_sz_default=080
elif [ "$rom_bytes" -le 786432 ];  then rom_sz_default=0C0
elif [ "$rom_bytes" -le 1048576 ]; then rom_sz_default=000
else                                    rom_sz_default=280
fi
ROM_SZ="${ROM_SZ:-$rom_sz_default}"
echo "run.sh: $rom_bytes bytes -> ROM_SZ=X\"$ROM_SZ\"  SGX=$SGX  CD_EN=$CD_EN" >&2

mkdir -p "$WORK"
rm -f "$WORK"/*.o "$WORK"/*.cf "$WORK"/tb_pce_boot 2>/dev/null || true

GHDL_FLAGS=(--std=08 -fsynopsys -frelaxed --workdir="$WORK" -Wno-hide -Wno-shared)

a() { ghdl -a "${GHDL_FLAGS[@]}" "$@"; }

cd "$ROOT"

# packages / memories
a src/pce/common/mem/init/voltab_pkg.vhd
a src/pce/common/mem/init/huc6260_palette_init_pkg.vhd
a src/pce/common/mem/bram_gowin.vhd
a src/pce/common/mem/cd_fifos.vhd
a src/pce/common/mem/vram0_cache.vhd
a src/pce/common/mem/vram0_prefetch.vhd

# SIM-ONLY replacements for the two Gowin-primitive wrappers and the two SystemVerilog
# modules -- must be analysed INSTEAD OF src/pce/common/mem/dpram*_dpb_wm01.vhd.
a sim/boot/sim_stubs.vhd

# CPU
a src/pce/tg16-mister-rtl/HUC6280/HUC6280_PKG.vhd
a src/pce/tg16-mister-rtl/HUC6280/AddSubBCD.vhd
a src/pce/tg16-mister-rtl/HUC6280/HUC6280_ALU.vhd
a src/pce/tg16-mister-rtl/HUC6280/HUC6280_AG.vhd
a src/pce/tg16-mister-rtl/HUC6280/HUC6280_MC.vhd
a src/pce/tg16-mister-rtl/HUC6280/HUC6280_CPU.vhd
a src/pce/common/core/psg.vhd
a src/pce/tg16-mister-rtl/HUC6280/HUC6280.vhd

# video
a src/pce/tg16-mister-rtl/huc6260.vhd
a src/pce/tg16-mister-rtl/huc6202.vhd
a src/pce/tg16-mister-rtl/CEGen.vhd
a src/pce/common/core/huc6270.vhd

# CD
a src/pce/tg16-mister-rtl/cd/MSM5205.vhd
a src/pce/tg16-mister-rtl/cd/SCSI.vhd
a src/pce/tg16-mister-rtl/cd/cd.vhd

a src/pce/common/core/pce_top.vhd
a sim/boot/tb_pce_boot.vhd

# This GHDL is the mcode backend: -e produces no binary, -r elaborates and runs.
ghdl -r "${GHDL_FLAGS[@]}" tb_pce_boot \
	-gROM_FILE="$ROM" \
	-gRUN_US="$RUN_US" \
	-gVERBOSE="$VERBOSE" \
	-gSGX_G="'$SGX'" \
	-gCD_EN_G="'$CD_EN'" \
	-gTRACE_N="$TRACE_N" \
	-gTRACE_SKIP="$TRACE_SKIP" \
	-gROM_SZ_G="X\"$ROM_SZ\"" \
	-gVGOLD_FILE="${VGOLD_FILE:-}" \
	-gROM_LAT="$ROM_LAT" \
	-gDUMP_AFTER_VDC="$DUMP_AFTER_VDC" \
	-gAC_BUILD_G="$AC_BUILD" \
	-gNO_CD_G="$NO_CD" \
	--ieee-asserts=disable
