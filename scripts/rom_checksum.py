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

BLOCK = 1 << 15  # 32KB, must match VFY_BLK_BITS in pcetang_console60k_cd.vhd
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
    """Pull block checksums and the heartbeat out of debug.log's `RTL[tag] b0..b7` lines.

    Tag layout: 0_P_bbbbbb -- bit 6 is the sweep pass, so pass 0 is 0x00-0x3F and pass 1
    is 0x40-0x7F. Tags >= 0x80 are the runtime heartbeat.

    Block payload:     [63:56] block  [55:24] checksum  [23:2] end address  [1:0] pad
    Heartbeat payload: [63:32] cumulative VDC0 write count  [31:16] ROM-read watchdog
                       timeouts  [15:14] rd_state  [13:11] rom_rd/rom_rdy/romb_wait
                       [10:0]  VBLANK count
    """
    passes = {0: {}, 1: {}}
    beats = []
    line_re = re.compile(r"RTL\[([0-9a-fA-F]{2})\]\s+((?:[0-9a-fA-F]{2}\s*){8})")
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            m = line_re.search(line)
            if not m:
                continue
            tag = int(m.group(1), 16)
            payload = bytes(int(x, 16) for x in m.group(2).split())
            val = int.from_bytes(payload, "big")
            if tag >= 0x80:
                beats.append({
                    "vdc": (val >> 32) & MASK,
                    "timeouts": (val >> 16) & 0xFFFF,
                    "rd_state": (val >> 14) & 0x3,
                    "rom_rd": (val >> 13) & 1,
                    "rom_rdy": (val >> 12) & 1,
                    "romb_wait": (val >> 11) & 1,
                    "vbl": val & 0x7FF,
                })
                continue
            passes[(tag >> 6) & 1][tag & 0x3F] = ((val >> 24) & MASK,
                                                  (val >> 2) & 0x3FFFFF)
    return passes, beats


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

    passes, beats = parse_log(args.log)
    if not passes[0] and not passes[1]:
        print("no RTL[..] block-checksum lines found in the log", file=sys.stderr)
        return 2

    bad_vs_file = 0
    disagree = 0
    for blk, chk, end in expected:
        p0 = passes[0].get(blk)
        p1 = passes[1].get(blk)
        if p0 is None and p1 is None:
            print(f"  block {blk:02x}  MISSING from log")
            bad_vs_file += 1
            continue
        g0 = p0[0] if p0 else None
        g1 = p1[0] if p1 else None
        if g0 is not None and g1 is not None and g0 != g1:
            print(f"  block {blk:02x}  PASSES DISAGREE  pass0 {g0:08x}  pass1 {g1:08x}"
                  f"  (file {chk:08x})")
            disagree += 1
            continue
        got = g0 if g0 is not None else g1
        if got == chk:
            print(f"  block {blk:02x}  OK       {chk:08x}")
        else:
            print(f"  block {blk:02x}  MISMATCH file {chk:08x} got {got:08x}")
            bad_vs_file += 1

    print()
    if disagree:
        print(f"RESULT: {disagree} block(s) read back DIFFERENTLY on two identical "
              f"sweeps.\n        The SDRAM READ PATH is unreliable -- the stored image "
              f"may be perfectly fine.\n        Look at the bridge's unsynchronised "
              f"clk_pce/clk_sdram crossing, not at the loader.")
    elif bad_vs_file:
        print(f"RESULT: {bad_vs_file} block(s) wrong, but both sweeps agree with each "
              f"other.\n        The ROM image in SDRAM really does NOT match the file "
              f"-- the LOAD path is the fault.")
    else:
        print("RESULT: both sweeps agree with each other and with the file. The ROM "
              "image\n        in SDRAM is correct AND reads back reliably, so the fault "
              "is elsewhere\n        (synthesis/timing, or the read path only under "
              "concurrent CPU load).")

    if beats:
        vdc = [b["vdc"] for b in beats]
        last = beats[-1]
        states = {0: "IDLE", 1: "SETTLE", 2: "WAIT"}
        print()
        print(f"heartbeat: {len(beats)} samples, VDC write count "
              f"{vdc[0]} -> {vdc[-1]}, VBLANK {last['vbl']}")
        print(f"        rd_state={states.get(last['rd_state'], '?')} "
              f"rom_rdy={last['rom_rdy']} romb_wait={last['romb_wait']}  "
              f"ROM-read watchdog timeouts={last['timeouts']}")
        if last["timeouts"] == 0 and last["rd_state"] != 2:
            print("        ROM read path healthy: no stalled reads, bridge not parked "
                  "in WAIT.")
        elif last["timeouts"]:
            print(f"        *** {last['timeouts']} ROM reads STALLED and were escaped by "
                  f"the watchdog.\n        The clk_pce/clk_sdram deadlock is NOT fully "
                  f"fixed -- but the CPU kept running.")
        if last["rd_state"] == 2 and last["romb_wait"]:
            print("        *** bridge parked in RB_WAIT with romb_wait high -- SDRAM "
                  "read never completed.")
        if vdc[-1] == 0:
            print("        VDC write count is FLAT ZERO -- the CPU never reached the "
                  "code that\n        programs the VDC. The fault is UPSTREAM of the "
                  "video path.")
        elif len(set(vdc)) == 1:
            print(f"        VDC write count is FROZEN at {vdc[-1]} across every sample "
                  f"-- the CPU\n        started programming the VDC and then STOPPED. "
                  f"For reference the GHDL\n        sim reaches 3335 by 20ms and 17772 "
                  f"by 76ms, still climbing.")
        else:
            print("        VDC write count is CLIMBING -- the CPU is running and "
                  "programming the\n        VDC, so the fault is DOWNSTREAM (video path "
                  "/ HDMI).\n        For reference the GHDL sim reaches 3335 by 20ms, "
                  "17772 by 76ms.")
    else:
        print("\nheartbeat: no RTL[80+] samples in the log -- the core may never have "
              "been released.")

    return 1 if (bad_vs_file or disagree) else 0


if __name__ == "__main__":
    sys.exit(main())
