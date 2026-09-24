#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand
# The golden decoder reimplements the OKI/Dialogic ADPCM algorithm as found in Mednafen's
# okiadpcm.c/.h (beetle-pce-fast, GPL-2.0-or-later) -- see THIRD_PARTY_LICENSES.md.
"""ADPCM WAVs from a golden case and from the RTL sim, and a diff between them.

  adpcm_wav.py <golden_dir> [rtl_pcm.txt] [out_dir]

golden_dir  sim/cd/golden/<case>: nib.hex (nibbles beetle played) and regs.txt (for $180E rate)
rtl_pcm.txt one AD_S value per consumed nibble, from tb_adpcm_golden -gPCM_OUT=...

Writes golden.wav, and if rtl_pcm is given rtl.wav and diff.wav, and prints the comparison.
The golden decode is an exact port of beetle-pce-fast's OKIADPCM_Decode (mednafen okiadpcm.h):
12-bit predictor that WRAPS (& 0xFFF), no clamping. The RTL MSM5205 clamps at +-2047; the two
only disagree if the signal overflows, which this comparison makes visible.
"""
import sys, os, wave, struct, math

STEP = [16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,
        173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,
        1166,1282,1411,1552]
IDX = [-1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8]

def delta_table():
    # Dialogic integer form, which is what mednafen's OKIADPCM_DeltaTable holds (verified cell
    # by cell against okiadpcm.c): ss>>3, plus ss for bit 2, ss>>1 for bit 1, ss>>2 for bit 0,
    # sign from bit 3. NOT ((2n+1)*ss)/8 -- that differs in 204 of the 784 cells.
    t = []
    for ss in STEP:
        row = []
        for n in range(16):
            v = (ss >> 3) + (ss if n & 4 else 0) + ((ss >> 1) if n & 2 else 0) + ((ss >> 2) if n & 1 else 0)
            row.append(-v if n & 8 else v)
        t.append(row)
    return t
DT = delta_table()

def beetle_decode(nibs):
    cur, ssi, out = 0x800, 0, []
    for n in nibs:
        d = DT[ssi][n]
        ssi = min(48, max(0, ssi + IDX[n]))
        cur = (cur + d) & 0xFFF
        out.append(cur - 2048)
    return out

def read_regs_rate(d):
    f = 0
    for line in open(os.path.join(d, "regs.txt")):
        p = line.split()
        if len(p) == 3 and p[0] == "W" and p[1].lower() == "e":
            f = int(p[2], 16) & 15
    return 32087.5 / (16 - f)

def write_wav(path, samples12, rate):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(int(round(rate)))
        w.writeframes(b"".join(struct.pack("<h", max(-32768, min(32767, s * 16))) for s in samples12))

def main():
    gd = sys.argv[1]
    rtl = sys.argv[2] if len(sys.argv) > 2 else None
    od = sys.argv[3] if len(sys.argv) > 3 else (os.path.dirname(rtl) if rtl else ".")
    os.makedirs(od, exist_ok=True)
    nibs = [int(l, 16) for l in open(os.path.join(gd, "nib.hex")) if l.strip()]
    rate = read_regs_rate(gd)
    g = beetle_decode(nibs)
    write_wav(os.path.join(od, "golden.wav"), g, rate)
    print(f"golden: {len(g)} samples at {rate:.1f} Hz -> {od}/golden.wav")
    if not rtl:
        return
    r16 = [int(l) for l in open(rtl) if l.strip()]
    # AD_S = (SOUT * FADE_VOL) >> 10 with SOUT = sample12 << 4 and, at full volume,
    # FADE_VOL = 1023 -- NOT 1024, so a plain >> 4 is off by one on almost every sample.
    # The map is one-to-one over the 12-bit range, so invert it exactly.
    inv = {((x << 4) * 1023) >> 10: x for x in range(-2048, 2048)}
    unmapped = sum(1 for v in r16 if v not in inv)
    if unmapped:
        print(f"warning: {unmapped} AD_S values not on the full-volume grid (fader active?)")
    r = [inv.get(v, v >> 4) for v in r16]
    # The RTL MSM5205 decodes one nibble BEFORE the first real one: M5205_D resets to 0 and
    # is decoded on the first VCK falling edge, so its output is beetle's decode of
    # [0] + nibbles (one sample of latency, +2 offset). Model that instead of searching lags;
    # measured bit-exact on Rondo PLAY#8 apart from the final sample, where AD_S is gated to
    # 0 because playback has stopped.
    model = beetle_decode([0] + nibs)
    n = min(len(model), len(r))
    diff = [r[i] - model[i] for i in range(n)]
    exact = sum(1 for x in diff if x == 0)
    mx = max(abs(x) for x in diff)
    rms = math.sqrt(sum(x * x for x in diff) / n)
    sg = math.sqrt(sum(x * x for x in model[:n]) / n) or 1
    first = next((i for i, x in enumerate(diff) if x != 0), -1)
    write_wav(os.path.join(od, "rtl.wav"), r, rate)
    write_wav(os.path.join(od, "diff.wav"), diff, rate)
    print(f"rtl:    {len(r)} AD_S samples, compared {n} against beetle decode of [0]+nibbles")
    print(f"diff:   exact={exact}/{n} ({100*exact/n:.2f}%)  max_abs_err={mx}  rms_err={rms:.2f} "
          f"({100*rms/sg:.2f}% of signal rms)  first_diff_at={first}")
    print(f"wavs:   {od}/golden.wav  {od}/rtl.wav  {od}/diff.wav")

main()
