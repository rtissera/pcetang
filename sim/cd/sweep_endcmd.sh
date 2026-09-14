#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand
#
# Sweep the end-of-command phase walk across sector counts and MCU timing. The question:
# can the CD_DATA_END handshake (a one-cycle pulse, no ack, only three cd_bridge states
# listen) ever be lost, leaving SCSI_READ_WAIT_END hung and the system card timing out?
#
# Each line prints PASS/FAIL plus dend_consumed / dend_LOST, so a pass is evidence and
# not just an absence of complaints.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/sweep_results.txt}"
: > "$OUT"
run() {
  local desc="$1"; shift
  local r
  r=$(timeout 1800 "$HERE/run_cd_endcmd.sh" "$@" 2>&1 | grep -aE 'RESULT|PASS|FAIL|TIMEOUT|WRONG|error' | tr '\n' ' ')
  if echo "$r" | grep -q PASS; then echo "PASS  $desc :: $r" | tee -a "$OUT"
  else echo "FAIL  $desc :: $r" | tee -a "$OUT"; fi
}
# 1. sector counts the golden trace actually uses, at the real 2 Mbaud turnaround
for n in 1 2 8 10 12 20; do
  run "sectors=$n uniform10ms" -gSECTORS=$n -gSECTOR_LAT_US=10000
done
# 2. CPU drain rate: the race is CPU-drains-FIFO vs bridge-writes-next-sector
for c in 5 10 43 100 400; do
  run "sectors=8 cpu_cycles=$c" -gSECTORS=8 -gSECTOR_LAT_US=10000 -gCPU_CYCLES=$c
done
# 3. MCU turnaround, from instant to pathological
for l in 0 10 100 1000 10000 50000 200000; do
  run "sectors=8 lat=${l}us" -gSECTORS=8 -gSECTOR_LAT_US=$l
done
# 4. hunk-read asymmetry, as the board's own REQRING shows (hunk_reads=5 of 33 sectors)
for e in 2 3 6; do
  for x in 20000 100000 400000; do
    run "sectors=12 hunk_every=$e extra=${x}us" -gSECTORS=12 -gSECTOR_LAT_US=10000 \
        -gHUNK_EVERY=$e -gHUNK_EXTRA_US=$x
  done
done
# 5. fast CPU against slow jittery MCU -- the worst case for the race
for c in 5 10; do
  for x in 100000 400000; do
    run "sectors=12 cpu=$c hunk_every=2 extra=${x}us" -gSECTORS=12 -gSECTOR_LAT_US=10000 \
        -gCPU_CYCLES=$c -gHUNK_EVERY=2 -gHUNK_EXTRA_US=$x
  done
done
echo "=== SUMMARY ===" | tee -a "$OUT"
echo "pass=$(grep -c '^PASS' "$OUT")  fail=$(grep -c '^FAIL' "$OUT")" | tee -a "$OUT"
grep '^FAIL' "$OUT" || echo "no failures" | tee -a "$OUT"
