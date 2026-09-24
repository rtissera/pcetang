#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand
# Sweep the register-level end-of-command walk (cd.vhd + cd_bridge, CPU modelled as the
# system card really behaves). See tb_cd_regwalk.vhd's header.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/sweep_regwalk_results.txt}"
: > "$OUT"
run() {
  local desc="$1"; shift
  local r
  r=$(timeout 3600 "$HERE/run_cd_regwalk.sh" "$@" 2>&1 \
        | grep -aE 'RESULT|PASS:|TIMEOUT|WRONG|assertion' | tr '\n' ' ')
  if echo "$r" | grep -q 'PASS:'; then echo "PASS  $desc :: $r" | tee -a "$OUT"
  else echo "FAIL  $desc :: $r" | tee -a "$OUT"; fi
}
for n in 2 8 10 12; do
  run "sectors=$n real10ms" -gSECTORS=$n -gSECTOR_LAT_US=10000
done
for x in 40000 200000; do
  run "sectors=8 hunk_every=2 extra=${x}us" -gSECTORS=8 -gSECTOR_LAT_US=10000 \
      -gHUNK_EVERY=2 -gHUNK_EXTRA_US=$x
done
for c in 5 200; do
  run "sectors=8 cpu_cycles=$c" -gSECTORS=8 -gSECTOR_LAT_US=10000 -gCPU_CYCLES=$c
done
echo "=== SUMMARY pass=$(grep -c '^PASS' "$OUT") fail=$(grep -c '^FAIL' "$OUT") ===" | tee -a "$OUT"
grep '^FAIL' "$OUT" || echo "no failures" | tee -a "$OUT"
