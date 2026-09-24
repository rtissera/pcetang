#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand
# ADPCM co-simulation: real cd.vhd + port-C arbiter (ghdl synth -> Verilog) + REAL sdram.sv +
# chip model, in Verilator. Replays a golden case and writes a WAV comparison.
#   CDRAM=1 adds CD-RAM traffic on the shared port; AB=1 adds port A/B contention in sdram.sv.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
OBJ="$HERE/obj"; mkdir -p "$OBJ"
CASE="${CASE:-$ROOT/sim/cd/golden/adpcm_rondo_play8}"
cd "$ROOT"

python3 "$HERE/check_arbiter_drift.py"

# 1. VHDL -> Verilog for cd.vhd and the arbiter
W="$OBJ/ghdl"; rm -rf "$W"; mkdir -p "$W"
F=(--std=08 -fsynopsys -frelaxed --workdir="$W" -Wno-hide -Wno-shared)
for f in src/pce/common/mem/init/voltab_pkg.vhd src/pce/common/mem/init/huc6260_palette_init_pkg.vhd \
         src/pce/common/mem/bram_gowin.vhd src/pce/common/mem/cd_fifos.vhd src/pce/tg16-mister-rtl/CEGen.vhd \
         src/pce/tg16-mister-rtl/cd/MSM5205.vhd src/pce/tg16-mister-rtl/cd/SCSI.vhd \
         src/pce/tg16-mister-rtl/cd/cd.vhd sim/cd/cosim/portc_arbiter.vhd; do
  ghdl-mcode -a "${F[@]}" "$f"
done
ghdl-mcode synth "${F[@]}" --out=verilog cd            > "$OBJ/cd_raw.v"
ghdl-mcode synth "${F[@]}" --out=verilog portc_arbiter > "$OBJ/portc_arbiter.v"
# GHDL's Verilog output declares a net twice when an instance output shares a signal's name,
# and adds `assign x = x; // (signal)`. Both are no-ops; Verilator rejects the duplicate.
python3 - "$OBJ/cd_raw.v" "$OBJ/cd.v" <<'PY'
import re, sys
out=[]; seen=set()
for ln in open(sys.argv[1]).read().split('\n'):
    if re.match(r'\s*module\s+\S+', ln): seen=set()
    d=re.match(r'\s*(wire|reg)\s*(\[[^\]]+\])?\s*([A-Za-z_][\w$]*)\s*;', ln)
    if d:
        if d.group(3) in seen: continue
        seen.add(d.group(3))
    s=re.match(r'\s*assign\s+([A-Za-z_][\w$]*)\s*=\s*([A-Za-z_][\w$]*)\s*;\s*//\s*\(signal\)', ln)
    if s and s.group(1)==s.group(2): continue
    out.append(ln)
open(sys.argv[2],'w').write('\n'.join(out))
PY

# 2. sdram.sv with Gowin-only port defaults stripped (same transform as sim/sdram)
python3 - src/pce/common/mem/sdram.sv "$OBJ/sdram_vlt.sv" <<'PY'
import re, sys
s = open(sys.argv[1]).read(); i = s.find('module sdram'); j = s.find(');', i)
ports = re.sub(r"\s*=\s*\d+'[hdb][0-9a-fA-FxzZ_]+", '', s[i:j])
open(sys.argv[2], 'w').write(s[:i] + ports + s[j:])
PY

# 3. Verilator build
verilator --cc --exe --build -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKANDNBLK \
  -Wno-UNOPTFLAT -Wno-PINMISSING -Wno-MULTIDRIVEN --top-module tb_adpcm_cosim_top \
  --Mdir "$OBJ/vl" -I"$ROOT/sim/sdram" \
  "$HERE/tb_adpcm_cosim_top.sv" "$OBJ/cd.v" "$OBJ/portc_arbiter.v" "$OBJ/sdram_vlt.sv" \
  "$ROOT/sim/sdram/sdram_chip_model.sv" "$ROOT/sim/sdram/ODDR.v" "$HERE/tb_adpcm_cosim.cpp" \
  -o tb_adpcm_cosim > "$OBJ/build.log" 2>&1 || { tail -30 "$OBJ/build.log"; exit 1; }

# 4. run + WAV
"$OBJ/vl/tb_adpcm_cosim" "$CASE" "$OBJ/rtl_pcm.txt" "${FAST:-1}" "${CDRAM:-0}" "${AB:-0}"
python3 "$ROOT/sim/cd/adpcm_wav.py" "$CASE" "$OBJ/rtl_pcm.txt" "$OBJ"
