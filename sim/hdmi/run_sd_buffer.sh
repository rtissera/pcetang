#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand
# Does the scandoubler show two source lines inside one output line? See tb_sd_buffer.cpp.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
OBJ="${OBJ_DIR:-$HERE/obj}"
cd "$ROOT"
verilator --cc --exe --build -j 4 -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT \
    --top-module pce2hdmi_sd -Mdir "$OBJ" \
    -CFLAGS "-O1" \
    src/pce2hdmi_sd.sv sim/hdmi/hdmi_stub.sv "$ROOT/sim/hdmi/tb_sd_buffer.cpp" \
    --public-flat-rw >/dev/null 2>&1 || {
      verilator --cc --exe --build -j 4 -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT \
        --top-module pce2hdmi_sd -Mdir "$OBJ" src/pce2hdmi_sd.sv sim/hdmi/hdmi_stub.sv \
        "$ROOT/sim/hdmi/tb_sd_buffer.cpp" --public-flat-rw 2>&1 | tail -20; exit 1; }
"$OBJ/Vpce2hdmi_sd" "${FRAMES:-3}"
