#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand
# Exact-lock phase test for pce2hdmi_sd.sv, see tb_exact.cpp. Usage: run_exact.sh [frames jump_at stall]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
OBJ="${OBJ_DIR:-$HERE/obj}"
cd "$ROOT"
verilator --cc --exe --build -j 2 -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT \
    --top-module pce2hdmi_sd -Mdir "$OBJ" -GVIDEOID=200 -GCLKFRQ=26875 -CFLAGS "-O1" \
    src/pce2hdmi_sd.sv sim/hdmi_exact/hdmi_stub_exact.sv "$HERE/tb_exact.cpp" \
    --public-flat-rw > "$OBJ.build.log" 2>&1 || { tail -30 "$OBJ.build.log"; exit 1; }
"$OBJ/Vpce2hdmi_sd" "$@"
