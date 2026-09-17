#!/usr/bin/env python3
"""Summarise a beetle ADPCM golden trace: how the game feeds ADPCM, and what it plays.
usage: adpcm_analyze.py golden/adpcm/<prefix>"""
import sys, os, struct, re, collections
pre = sys.argv[1]
log = open(pre + ".log").read().splitlines() if os.path.exists(pre + ".log") else []
wr = open(pre + "_writes.bin", "rb").read() if os.path.exists(pre + "_writes.bin") else b""
nib = open(pre + "_nib.bin", "rb").read() if os.path.exists(pre + "_nib.bin") else b""
recs = [struct.unpack("<IHBB", wr[i:i+8]) for i in range(0, len(wr) - len(wr) % 8, 8)]
print(f"register writes: {sum(1 for l in log if ' W ' in l)}   RAM writes: {len(recs)}   played nibbles: {len(nib)}")
src = collections.Counter(r[3] for r in recs)
print(f"write source: CPU($180A)={src.get(0,0)}  DMA-from-CD={src.get(1,0)}")
# group writes into contiguous address runs
runs = []
for fr, ad, v, s in recs:
    if runs and ad == (runs[-1]["end"] + 1) & 0xFFFF and s == runs[-1]["src"]:
        runs[-1]["end"] = ad; runs[-1]["n"] += 1; runs[-1]["f1"] = fr
    else:
        runs.append(dict(start=ad, end=ad, n=1, src=s, f0=fr, f1=fr))
print(f"write runs: {len(runs)}")
for r in runs[:15]:
    print(f"  {'DMA' if r['src'] else 'CPU'} addr {r['start']:04x}-{r['end']:04x} n={r['n']:5d} frames {r['f0']}-{r['f1']}")
print("register activity (first 40 of $1808-$180F writes):")
for l in [l for l in log if ' W ' in l][:40]:
    print("  " + l)
print("playbacks:")
for l in log:
    if "PLAY#" in l: print("  " + l)
