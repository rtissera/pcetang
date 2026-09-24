#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand
# ADPCM golden trace for one disc: beetle-pce-fast headless under xvfb, RUN pressed every
# KEY_EVERY seconds so the syscard/title are passed, then the game is left to play.
#   ./run_adpcm_gold.sh /path/game.chd out_prefix [seconds] [key_every_s]
# Output: adpcm/<prefix>.log, _writes.bin, _ram_<n>.bin, _nib.bin (see beetle pcecd.c hook).
set -u
G="$(cd "$(dirname "$0")" && pwd)"
CHD="${1:?usage}"; OUT="${2:?prefix}"; SECS="${3:-120}"; KEVERY="${4:-4}"
CORE="$G/../beetle-src/mednafen_pce_fast_libretro.so"
mkdir -p "$G/adpcm"
export PCE_ADPCM_LOG="$G/adpcm/$OUT"
rm -f "$G/adpcm/${OUT}"*
xvfb-run -a --server-args="-screen 0 640x480x24" bash -c '
  retroarch --config '"$G"'/cfg/retroarch.cfg -L '"$CORE"' "'"$CHD"'" > '"$G/adpcm/${OUT}"'_retroarch.txt 2>&1 &
  RA=$!
  sleep 4
  WID=$(xdotool search --name RetroArch 2>/dev/null | head -1)
  [ -n "$WID" ] && xdotool windowfocus --sync "$WID" 2>/dev/null
  t=0
  while [ $t -lt '"$SECS"' ]; do
     sleep '"$KEVERY"'; t=$((t+'"$KEVERY"'))
     [ -n "$WID" ] && xdotool windowfocus "$WID" 2>/dev/null
     xdotool keydown Return 2>/dev/null; sleep 0.15; xdotool keyup Return 2>/dev/null
  done
  kill $RA 2>/dev/null; wait $RA 2>/dev/null
'
echo "done: $(ls "$G/adpcm/" | grep "^$OUT" | wc -l) files"
