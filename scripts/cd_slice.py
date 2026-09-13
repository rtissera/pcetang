#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand

"""Extract a sector slice from a chdman-extracted .bin, for sim/cd/tb_cd_boot.vhd.

    chdman extractcd -i game.chd -o game.cue -ob game.bin
    scripts/cd_slice.py game.bin 3584 160 > de2_sectors.hex          # contiguous
    scripts/cd_slice.py game.bin --lbas 3590,3591,11944-11967 > x.hex  # sparse

A contiguous run wastes the whole span between the sectors a boot actually touches --
Dungeon Explorer II's real boot reads 31 sectors spread from LBA 3590 to 11967, which as
one run is 8378 sectors and 34 MB of hex that GHDL would load at elaboration. The sparse
form emits "<lba> <hex>" lines instead, and the testbench looks sectors up by LBA.

The .bin's sector numbering is NOT the disc LBA -- chdman drops pregaps, so the two are
offset by a constant. Rather than assume it, the shift is SOLVED from a sector's own
Mode-1 header (MSF at offset 12), which is authoritative.

Output: one line per sector, 4096 hex chars = 2048 bytes of USER data (Mode 1, offset 16).
"""
import sys

def bcd(b): return (b >> 4) * 10 + (b & 0xf)

def solve_shift(f, probe=3590):
    f.seek(probe * 2352)
    raw = f.read(2352)
    disc = (bcd(raw[12]) * 60 + bcd(raw[13])) * 75 + bcd(raw[14]) - 150
    return disc - probe
def parse_lbas(spec):
    """"3590,3591,11944-11967" -> a sorted, de-duplicated list of LBAs."""
    out = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            lo, hi = part.split("-", 1)
            out.update(range(int(lo), int(hi) + 1))
        else:
            out.add(int(part))
    return sorted(out)

def emit(f, shift, lbas, sparse):
    for lba in lbas:
        f.seek((lba - shift) * 2352)
        raw = f.read(2352)
        if len(raw) < 2352:
            print(f"# warning: LBA {lba} is past the end of the file", file=sys.stderr)
            continue
        if raw[15] != 1:
            print(f"# warning: LBA {lba} is mode {raw[15]}, not Mode 1", file=sys.stderr)
        data = raw[16:16 + 2048].hex()
        print(f"{lba} {data}" if sparse else data)

def main(argv):
    f = open(argv[0], "rb")
    shift = solve_shift(f)
    if argv[1] == "--lbas":
        lbas = parse_lbas(argv[2])
        print(f"# sparse: {len(lbas)} sector(s) file_shift={shift}", file=sys.stderr)
        emit(f, shift, lbas, sparse=True)
    else:
        base, count = int(argv[1]), int(argv[2])
        print(f"# base_lba={base} count={count} bytes_per_sector=2048 file_shift={shift}",
              file=sys.stderr)
        emit(f, shift, range(base, base + count), sparse=False)

if __name__ == "__main__":
    main(sys.argv[1:])
