#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand

"""Diff a video-register trace against a reference, and report the FIRST divergence.

    scripts/vgold_diff.py reference.log ours.log
    scripts/vgold_diff.py ref.log ours.log --context 12 --ignore-frames

Three producers emit the same line format, which is the whole point -- they can be
compared to each other, not just to us:

  golden/sgx_vgold.lua              MAME's `sgx` driver, via a LUA write tap
  golden/beetle-sgx (instrumented)  beetle-supergrafx, PCE_VGOLD_LOG=...
  sim/boot/tb_pce_boot.vhd          our core, VGOLD_FILE=...

    <frame> W <VDC0|VDC1|VPC|VCE> <addr> <data>

USE TWO REFERENCES, NOT ONE. On 1941 (2026-09-18) MAME and beetle disagreed violently:
over the same first 179 frames MAME logged 3848 VDC0 writes and ONE VCE write, while
beetle logged 202784 and 1029. MAME's run stops touching video hardware after frame 2 --
its 1941 is idle -- so a comparison against MAME alone would have "proved" our core
matched the reference when in fact both were doing nothing. Diff the two references
against each other FIRST and only trust the part where they agree.

Addresses are normalised: producers log them with different widths and bases (MAME logs
the full physical 1FExxx, our testbench logs the low 12 bits), so only the low 12 bits
are compared. Frame numbers may sit one apart between producers because each counts a
slightly different moment, so --ignore-frames compares the write STREAM alone, which is
usually what you want; frames still print as context.
"""

import argparse
import sys


def load(path, ignore_frames):
    """-> list of (key, raw_line, frame). key is what actually gets compared."""
    out = []
    with open(path, errors="replace") as fh:
        for raw in fh:
            raw = raw.rstrip("\n")
            if not raw or raw.startswith("#"):
                continue
            parts = raw.split()
            # <frame> W <block> <addr> <data>   (reads are logged by some producers; skip)
            if len(parts) < 5 or parts[1] != "W":
                continue
            frame, blk, addr, data = parts[0], parts[2], parts[3], parts[4]
            try:
                addr = int(addr, 16) & 0xFFF
                data = int(data, 16) & 0xFF
            except ValueError:
                continue
            key = (blk, addr, data) if ignore_frames else (frame, blk, addr, data)
            out.append((key, raw, frame))
    return out


def fmt(entry):
    return entry[1] if entry else "<end of trace>"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reference")
    ap.add_argument("ours")
    ap.add_argument("--context", type=int, default=8,
                    help="lines of agreeing history to show before the divergence")
    ap.add_argument("--ignore-frames", action="store_true", default=True,
                    help="compare the write stream only (default)")
    ap.add_argument("--strict-frames", dest="ignore_frames", action="store_false",
                    help="require frame numbers to match too")
    args = ap.parse_args()

    ref = load(args.reference, args.ignore_frames)
    ours = load(args.ours, args.ignore_frames)
    print(f"reference : {len(ref):>9} writes  {args.reference}")
    print(f"ours      : {len(ours):>9} writes  {args.ours}")

    n = min(len(ref), len(ours))
    div = next((i for i in range(n) if ref[i][0] != ours[i][0]), None)

    if div is None:
        if len(ref) == len(ours):
            print("\nIDENTICAL: both traces agree over their whole length.")
            return 0
        longer, count = ("reference", len(ref)) if len(ref) > len(ours) else ("ours", len(ours))
        print(f"\nPREFIX MATCH: the first {n} writes agree; {longer} then continues "
              f"for {count - n} more.")
        print(f"  next in {longer}: "
              f"{fmt(ref[n] if longer == 'reference' else ours[n])}")
        # A short "ours" is the usual shape of a hang: we stop, the reference goes on.
        return 0

    print(f"\nFIRST DIVERGENCE at write #{div + 1} "
          f"(reference frame {ref[div][2]}, ours frame {ours[div][2]})\n")
    for i in range(max(0, div - args.context), div):
        print(f"      both  {ref[i][1]}")
    print(f"  >>  ref   {fmt(ref[div])}")
    print(f"  >>  ours  {fmt(ours[div])}")
    print()
    for i in range(div + 1, min(div + 1 + args.context, n)):
        print(f"      ref   {ref[i][1]}")
        print(f"      ours  {ours[i][1]}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
