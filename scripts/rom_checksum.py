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
    dumps = {}
    pattern = {}
    wram = {}
    trap = []
    mpr = []
    line_re = re.compile(r"RTL\[([0-9a-fA-F]{2})\]\s+((?:[0-9a-fA-F]{2}\s*){8})")
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            m = line_re.search(line)
            if not m:
                continue
            tag = int(m.group(1), 16)
            payload = bytes(int(x, 16) for x in m.group(2).split())
            val = int.from_bytes(payload, "big")
            if tag == 0xE3:
                mpr[:] = list(payload)[::-1]   # payload is MPR7..MPR0
                continue
            if 0xE0 <= tag <= 0xE2:
                val = int.from_bytes(payload, "big")
                trap.append(((val >> 40) & 0xFFFFFF, (val >> 16) & 0xFFFFFF))
                continue
            if tag == 0xD1:
                val = int.from_bytes(payload, "big")
                wram["errs"] = (val >> 48) & 0xFFFF
                wram["first_got"] = (val >> 40) & 0xFF
                wram["first_addr"] = (val >> 32) & 0xFF
                wram["tested"] = (val >> 16) & 0xFFFF
                continue
            if tag == 0xD0:
                val = int.from_bytes(payload, "big")
                pattern["errs"] = (val >> 48) & 0xFFFF
                pattern["first_got"] = (val >> 40) & 0xFF
                pattern["first_addr"] = (val >> 32) & 0xFF
                pattern["tested"] = (val >> 16) & 0xFFFF
                pattern["wr_drops"] = val & 0xFFFF
                continue
            if 0xC0 <= tag <= 0xCF:
                dumps[tag - 0xC0] = payload
                continue
            if tag >= 0x80:
                beats.append({
                    "vdc": (val >> 48) & 0xFFFF,
                    "cpu_a": (val >> 27) & 0x1FFFFF,
                    "cpu_ce": (val >> 11) & 0xFFFF,
                    "vbl": val & 0x7FF,
                })
                continue
            passes[(tag >> 6) & 1][tag & 0x3F] = ((val >> 24) & MASK,
                                                  (val >> 2) & 0x3FFFFF)
    return passes, beats, dumps, pattern, wram, trap, mpr


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

    passes, beats, dumps, pattern, wram, trap, mpr = parse_log(args.log)

    if mpr:
        print()
        print("MPR BANK REGISTERS at the moment of derailment:")
        expect = {0: 0xFF, 1: 0xF8, 2: 0x01, 3: 0x02, 4: 0x03, 5: 0x04, 6: 0x05, 7: 0x00}
        for i, v in enumerate(mpr):
            exp = expect.get(i)
            note = ""
            if exp is not None:
                note = "  ok" if v == exp else f"  <-- expected {exp:02X}"
            print(f"    MPR{i} = {v:02X}{note}")
        print()
        print("  (expected values are what 1943 Kai's boot code sets: MPR0=$FF I/O,")
        print("   MPR1=$F8 work RAM, MPR2..6 = ROM banks 1..5 via LE454, MPR7=0 ROM bank 0)")


    if trap:
        entries = [e for pair in trap for e in pair]
        if not any(entries):
            print()
            print("DERAILMENT TRAP: fired, but the capture buffer is ALL ZEROS -- nothing")
            print("was ever recorded, so there is no verdict here. Do not read the byte")
            print("comparison below as evidence; fix the capture trigger first.")
            trap = []
    if trap:
        print()
        print("DERAILMENT TRAP -- last ROM bytes the CPU actually received before it")
        print("entered a nonexistent bank (newest first):")
        bad = 0
        for pair in trap:
            for entry in pair:
                a_ = (entry >> 8) & 0xFFFF
                d_ = entry & 0xFF
                exp = data[a_] if a_ < len(data) else None
                if exp is None:
                    continue
                mark = "" if d_ == exp else f"   <-- FILE HAS {exp:02x}"
                if d_ != exp:
                    bad += 1
                print(f"    ROM {a_:#06x} -> CPU got {d_:02x}{mark}")
        print()
        if bad:
            print(f"  {bad} of the delivered bytes are WRONG. The CPU was fed corrupt data")
            print("  under load, even though the same ROM verifies perfectly when swept")
            print("  with the CPU held in reset. The read path fails only under contention.")
        else:
            print("  Every delivered byte matches the file. The CPU received CORRECT data")
            print("  and still derailed -- so the fault is in the core's execution, not")
            print("  in the memory path.")


    if wram:
        e, n = wram["errs"], wram["tested"]
        print()
        print(f"WORK RAM PATTERN TEST (on-chip BSRAM, port B): {e} mismatches in {n} bytes")
        if e == 0:
            print("  -> Work RAM stores and returns data correctly. Not the corruption source.")
        else:
            print(f"  -> first bad: addr 0x{wram['first_addr']:02x} "
                  f"expected 0x{wram['first_addr'] ^ 0xA5:02x} got 0x{wram['first_got']:02x}")
            print("     WORK RAM IS BROKEN. That explains everything: MPRs come from TAM")
            print("     (accumulator <- RAM), and this game runs its TII trampoline FROM")
            print("     RAM at $2480 with operands in RAM -- corrupt RAM = garbage bank.")


    if pattern:
        e, n = pattern["errs"], pattern["tested"]
        print()
        print(f"SDRAM PATTERN SELF-TEST (FPGA-written, no UART): {e} mismatches in {n} bytes")
        drops = pattern.get("wr_drops", 0)
        print(f"ROM-LOAD BYTES DROPPED by the write bridge: {drops}")
        if drops:
            print("  -> bytes arrived faster than the bridge could write them AND the")
            print("     holding slot was already full. That many ROM bytes are stale.")
        if e == 0:
            print("  -> The SDRAM interface round-trips its OWN data perfectly.")
            print("     So any ROM corruption is UPSTREAM: UART / iosys / the write bridge,")
            print("     NOT the DQ bus or its timing.")
        else:
            print(f"  -> first bad: addr 0x{pattern['first_addr']:02x} "
                  f"expected 0x{pattern['first_addr'] ^ 0x5A:02x} "
                  f"got 0x{pattern['first_got']:02x}")
            print("     The SDRAM interface corrupts its own data, so the fault is the")
            print("     DQ bus / capture timing -- not the loader.")


    if dumps:
        raw = b"".join(dumps[i] for i in sorted(dumps))
        n = len(raw)
        ref = data[:n]
        print()
        print(f"RAW SDRAM READ-BACK, first {n} bytes vs the .pce file:")
        bad = 0
        for off in range(0, n, 16):
            got = raw[off:off + 16]
            exp = ref[off:off + 16]
            mark = "  " if got == exp else "<-"
            if got != exp:
                bad += 1
            print(f"  {off:04x} sdram {got.hex(' ')} {mark}")
            if got != exp:
                print(f"       file  {exp.hex(' ')}")
        if bad == 0:
            print("  -> first bytes MATCH the file exactly.")
        else:
            print(f"  -> {bad} of {(n + 15) // 16} lines differ.")
            # try to name the transformation
            idx = [ref.find(bytes([b])) for b in raw[:8]]
            print(f"  offsets in file of the first 8 bytes read: {idx}")
        print()

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
        ce  = [b["cpu_ce"] for b in beats]
        addrs = [b["cpu_a"] for b in beats]
        print()
        print(f"heartbeat: {len(beats)} samples")
        print(f"  VDC writes {vdc[0]} -> {vdc[-1]}")
        print(f"  CPU_CE     {ce[0]} -> {ce[-1]}  (16-bit, wraps; delta per sample matters)")
        print(f"  VBLANK     {beats[0]['vbl']} -> {beats[-1]['vbl']}")
        print()
        print("  CPU_A samples (physical, 21-bit):")
        for k, a_ in enumerate(addrs):
            bank = (a_ >> 13) & 0xFF
            if bank <= 0x7F:      where = f"ROM offset {a_ & 0x1FFFFF:#07x}"
            elif 0x80 <= bank <= 0x87: where = "CD-RAM"
            elif bank == 0xF7:    where = "BRAM"
            elif 0xF8 <= bank <= 0xFB: where = "work RAM"
            elif bank == 0xFF:    where = "I/O"
            else:                 where = "*** UNMAPPED ***"
            if k < 6 or k >= len(addrs) - 3:
                print(f"    [{k:02d}] {a_:#08x}  bank ${bank:02X}  {where}")
            elif k == 6:
                print("    ...")
        banks = {(a_ >> 13) & 0xFF for a_ in addrs}
        print(f"  distinct banks seen: {sorted(hex(b) for b in banks)}")
    return 1 if (bad_vs_file or disagree) else 0


if __name__ == "__main__":
    sys.exit(main())
