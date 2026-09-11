#!/usr/bin/env python3
"""Extract a flat sector slice from a chdman-extracted .bin, for sim/cd/tb_cd_boot.vhd.

    chdman extractcd -i game.chd -o game.cue -ob game.bin
    scripts/cd_slice.py game.bin 3584 160 > de2_sectors.hex

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

def main(path, base, count):
    f = open(path, "rb")
    shift = solve_shift(f)
    print(f"# base_lba={base} count={count} bytes_per_sector=2048 file_shift={shift}",
          file=sys.stderr)
    for i in range(count):
        f.seek((base + i - shift) * 2352)
        raw = f.read(2352)
        if raw[15] != 1:
            print(f"# warning: LBA {base+i} is mode {raw[15]}, not Mode 1", file=sys.stderr)
        print(raw[16:16 + 2048].hex())

if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]))
