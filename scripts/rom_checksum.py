#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reference implementation of the ROM self-test checksum.

pcetang_console60k_cd.vhd sweeps the loaded ROM back out of SDRAM between the end of the
MCU's load and the release of the core, accumulating a checksum per 16KB block and
emitting each one over the RTL debug-trace channel (see pcetang_rtl_trace_channel.md) as
an ``RTL[bb] ...`` line in debug.log.  This computes the identical function over the .pce
file on the PC, so the two can be compared directly.

Why this exists: sim/boot/'s GHDL testbench proved pce_top boots a real HuCard given an
ideal ROM, while the same ROM on real hardware stays black.  Two candidates survive that
bisection -- a wrong ROM image in SDRAM, and synthesis/timing-level failures.  This
settles the first, and localises any corruption to a 16KB block.

The accumulator is rotate-left-by-1 then add, 32-bit, reset at each block boundary, so
byte ORDER matters (a plain sum would not notice a shuffled or mis-strided image).

Usage:
    scripts/rom_checksum.py <rom.pce>                 # print expected per-block sums
    scripts/rom_checksum.py <rom.pce> --log debug.log # parse a real log and diff

A .pce with a 512-byte header (file size % 8192 == 512) is header-stripped first, exactly
as the MCU's loadpce does before streaming it -- otherwise every block would mismatch for
an uninteresting reason.
"""

import argparse
import re
import sys

BLOCK = 1 << 14  # 16KB, must match VFY_BLK_BITS in pcetang_console60k_cd.vhd
MASK = 0xFFFFFFFF


def block_checksums(data: bytes):
    """Yield (block_index, checksum, end_offset) for each 16KB block."""
    out = []
    acc = 0
    for i, b in enumerate(data):
        acc = ((acc << 1) | (acc >> 31)) & MASK  # rotate left 1
        acc = (acc + b) & MASK
        if (i % BLOCK) == BLOCK - 1 or i == len(data) - 1:
            out.append((i // BLOCK, acc, i + 1))
            acc = 0
    return out


def parse_log(path):
    """Pull block checksums out of debug.log's `RTL[tag] b0 b1 ...` lines.

    Payload layout, matching the VHDL concatenation:
        [63:56] block  [55:24] checksum  [23:2] end address  [1:0] pad
    Heartbeat traces use tags >= 0x80 and are skipped here.
    """
    got = {}
    line_re = re.compile(r"RTL\[([0-9a-fA-F]{2})\]\s+((?:[0-9a-fA-F]{2}\s*){8})")
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            m = line_re.search(line)
            if not m:
                continue
            tag = int(m.group(1), 16)
            if tag >= 0x80:
                continue
            payload = bytes(int(x, 16) for x in m.group(2).split())
            val = int.from_bytes(payload, "big")
            blk = (val >> 56) & 0xFF
            chk = (val >> 24) & MASK
            end = (val >> 2) & 0x3FFFFF
            got[blk] = (chk, end)
    return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rom")
    ap.add_argument("--log", help="debug.log captured from the SD card")
    args = ap.parse_args()

    data = open(args.rom, "rb").read()
    if len(data) % 8192 == 512:
        print(f"note: stripping {512}-byte .pce header (as loadpce does)")
        data = data[512:]

    expected = block_checksums(data)
    print(f"{args.rom}: {len(data)} bytes, {len(expected)} blocks of {BLOCK}")

    if not args.log:
        for blk, chk, end in expected:
            print(f"  block {blk:02x}  checksum {chk:08x}  end {end:#08x}")
        return 0

    got = parse_log(args.log)
    if not got:
        print("no RTL[..] block-checksum lines found in the log", file=sys.stderr)
        return 2

    bad = 0
    for blk, chk, end in expected:
        if blk not in got:
            print(f"  block {blk:02x}  MISSING from log")
            bad += 1
            continue
        gchk, gend = got[blk]
        if gchk == chk:
            print(f"  block {blk:02x}  OK       {chk:08x}")
        else:
            print(f"  block {blk:02x}  MISMATCH expected {chk:08x} got {gchk:08x} "
                  f"(end {gend:#08x}, expected {end:#08x})")
            bad += 1

    extra = sorted(set(got) - {b for b, _, _ in expected})
    for blk in extra:
        print(f"  block {blk:02x}  UNEXPECTED in log ({got[blk][0]:08x})")

    print()
    if bad:
        print(f"RESULT: {bad} block(s) wrong -- the ROM image in SDRAM does NOT match "
              f"the file. The load/store path is the fault, not the core.")
    else:
        print("RESULT: every block matches. The ROM image in SDRAM is correct, so the "
              "fault is downstream of it (read path under CPU load, or synthesis/timing).")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
