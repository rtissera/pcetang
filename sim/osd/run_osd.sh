#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand
# OSD end-to-end check, see tb_osd.cpp. Usage: run_osd.sh [textdisp.v]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
TD="${1:-$ROOT/src/iosys/textdisp.v}"; OBJ="$HERE/obj_$(basename "$TD" .v)"
cd "$ROOT"
verilator --cc --exe --build -j 2 -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-lint -Wno-style \
  --top-module tb_osd_top -Mdir "$OBJ" -CFLAGS -O1 --public-flat-rw \
  sim/osd/tb_osd_top.sv src/pce2hdmi_sd.sv sim/hdmi_exact/hdmi_stub_exact.sv "$TD" sim/osd/dpb_stub.v \
  "$HERE/tb_osd.cpp" > "$OBJ.log" 2>&1 || { tail -20 "$OBJ.log"; exit 1; }
"$OBJ/Vtb_osd_top"
