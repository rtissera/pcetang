#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand
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
    tam = {}
    tloads = {}
    bviews = {}
    sel = {}
    line_re = re.compile(r"RTL\[([0-9a-fA-F]{2})\]\s+((?:[0-9a-fA-F]{2}\s*){8})")
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            m = line_re.search(line)
            if not m:
                continue
            tag = int(m.group(1), 16)
            payload = bytes(int(x, 16) for x in m.group(2).split())
            val = int.from_bytes(payload, "big")
            if tag == 0xEB:
                v = (val >> 32) & 0x3FFFFF
                sel["mpr_sel"]  = (v >> 14) & 0xFF
                sel["idx"]      = (v >> 11) & 0x7
                sel["mc_addr"]  = (v >> 8) & 0x7
                sel["a_out"]    = v & 0xFF
                continue
            if 0xE9 <= tag <= 0xEA:
                v = val
                bviews[tag - 0xE9] = {
                    "rom_a": (v >> 40) & 0x1FFFFF,
                    "rom_do": (v >> 32) & 0xFF,
                }
                continue
            if 0xE5 <= tag <= 0xE8:
                # IR | DI | ADDR_BUS(15:0) | A | STATE(5) LOAD_T(3) | pad | wait_ever
                v = val
                tloads[tag - 0xE5] = {
                    "ir": (v >> 56) & 0xFF,
                    "di": (v >> 48) & 0xFF,
                    "addr": (v >> 32) & 0xFFFF,
                    "alu": (v >> 24) & 0xFF,
                    "state": (v >> 19) & 0x1F,
                    "load_t": (v >> 16) & 0x7,
                    "wait_ever": v & 1,
                }
                continue
            if tag == 0xE4:
                # TAM_CNT | IR | T | A, then 4 pad bytes.
                tam["cnt"] = payload[0]
                tam["ir"] = payload[1]
                tam["t"] = payload[2]
                tam["a"] = payload[3]
                continue
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
                # 2026-09-09 layout (see pcetang_console60k_cd.vhd's heartbeat):
                # [63:48] VDC writes | [47:32] output frames | [31:16] source frames
                # | [15:6] vs_cy | [5:0] vtotal_extra
                beats.append({
                    "vdc":  (val >> 48) & 0xFFFF,
                    "outf": (val >> 32) & 0xFFFF,
                    "srcf": (val >> 16) & 0xFFFF,
                    "vs_cy": (val >> 6) & 0x3FF,
                    "vtx":  val & 0x3F,
                })
                continue
            passes[(tag >> 6) & 1][tag & 0x3F] = ((val >> 24) & MASK,
                                                  (val >> 2) & 0x3FFFFF)
    return passes, beats, dumps, pattern, wram, trap, mpr, tam, tloads, bviews, sel


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

    passes, beats, dumps, pattern, wram, trap, mpr, tam, tloads, bviews, sel = parse_log(args.log)

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

    if sel:
        print()
        print("MPR READ-SELECT at the moment of derailment:")
        print(f"    MPR_SEL (mux output) = {sel['mpr_sel']:02X}")
        print(f"    index ADDR_BUS(15:13) = {sel['idx']}   MC.ADDR_BUS = {sel['mc_addr']}")
        print(f"    A_OUT(20:13) actually driven = {sel['a_out']:02X}")
        if mpr:
            held = mpr[sel['idx']] if sel['idx'] < len(mpr) else None
            print(f"    MPR{sel['idx']} in the array = "
                  + (f"{held:02X}" if held is not None else "?"))
            print()
            if held is not None and sel['mpr_sel'] != held:
                print("  VERDICT: the MUX OUTPUT DISAGREES with the array at its own index.")
                print("           The read select is broken -- the array is not the problem.")
            elif sel['a_out'] != sel['mpr_sel'] and sel['mc_addr'] != 5:
                print("  VERDICT: MPR_SEL matches the array, but A_OUT does NOT match")
                print("           MPR_SEL. The fault is AFTER the mux, on the address bus.")
            else:
                print("  VERDICT: mux, array and A_OUT all agree. Then the $ED bank seen by")
                print("           the trap came from a DIFFERENT cycle than this snapshot --")
                print("           i.e. the trap is firing on a transient, not on real")
                print("           execution, and the derailment narrative needs rechecking.")

    if bviews:
        print()
        print("BRIDGE VIEW at the CPU's two most recent T-loads (newest first).")
        print("rom_a is the PHYSICAL address pce_top was asking for at that instant;")
        print("rom_do is the byte the ROM bridge was handing back at that same instant.")
        for i in sorted(bviews):
            b = bviews[i]
            print(f"   [{i}] rom_a = {b['rom_a']:06X}   rom_do = {b['rom_do']:02X}")
        if tloads and 0 in tloads and 0 in bviews:
            want = tloads[0]["addr"] & 0x1FFF
            got_a = bviews[0]["rom_a"] & 0x1FFF
            print()
            if got_a == want:
                print(f"  Bridge was on the SAME offset the CPU wanted ({want:04X}).")
                print("  -> the address path is fine; the byte itself is wrong or late.")
            else:
                print(f"  MISMATCH: CPU wanted offset {want:04X}, bridge was on {got_a:04X}"
                      f" (delta {got_a - want:+d}).")
                print("  -> the bridge is serving a DIFFERENT address than the CPU asked")
                print("     for, which is why its own (addr,data) pairs all look correct.")

    if tam:
        print()
        print("TAM EXECUTION EVIDENCE at the moment of derailment:")
        print(f"    TAM writes since reset : {tam['cnt']}  (expected 7 at this point)")
        print(f"    IR = {tam['ir']:02X}   T = {tam['t']:02X}   A = {tam['a']:02X}")
        print()
        # This is the whole point of the tag: it splits the two hypotheses the MPR
        # dump on its own cannot separate.
        if tam["cnt"] == 0:
            print("  VERDICT: the TAM write-enable NEVER fired. `IR = x\"53\" and LAST_CYCLE`")
            print("           never went true on hardware, so the MPRs hold their reset")
            print("           value and the fault is in instruction decode, not storage.")
        elif tam["cnt"] == 7:
            print("  VERDICT: all 7 TAMs fired. The write-enable decode is correct, so the")
            print("           corruption is in the MPR flops themselves or in the read")
            print("           select -- which is what the explicit-mux change targets.")
        elif tam["cnt"] > 7:
            print(f"  VERDICT: {tam['cnt']} TAMs fired -- MORE than the 7 that precede")
            print("           `jsr $4003`. The CPU got PAST the jsr and derailed later, so")
            print("           the bank fault is not where the trap window suggests.")
        else:
            print(f"  VERDICT: {tam['cnt']} TAMs fired, not 7. Neither 'never decoded' nor")
            print("           'decoded correctly' -- the CPU took a different path through")
            print("           the boot code than the simulation does. Chase the count first.")
        print()
        print("  Ground truth from sim/boot (real ROM, 20 ms): the boot code executes 7")
        print("  TAMs before `jsr $4003`, leaving MPR = FF F8 01 02 03 04 05 00, and a")
        print("  further 5 AFTER it (12 total) which zero MPR2..MPR6 again. Hardware never")
        print("  completes the jsr, so 7 is the expected count AT THE TRAP.")
        print()
        print("  NOTE: $A0 appears in the MPR dump but the boot path writes only $FF, $F8")
        print("        and $01..$05 -- no A value in it can be $A0. $A0 was not produced by")
        print("        masking a written value; it came from a write this code did not make.")

    if tloads:
        print()
        print("T-LOAD HISTORY (last 4 commits of DI into T, newest first).")
        print("This is the measurement that separates the two live mechanisms:")
        print("  DI captured at the OPCODE address  -> control fired EARLY (microcode)")
        print("  DI captured at the OPERAND address -> data arrived LATE (memory bridge)")
        print()
        print("   #  IR  DI  ADDR  ALU_OUT STATE LOAD_T   (LOAD_T 1=ALU_OUT 2=X 3=Y 4=DI)")
        for i in sorted(tloads):
            e = tloads[i]
            print(f"   {i}  {e['ir']:02X}  {e['di']:02X}  {e['addr']:04X}    {e['alu']:02X}"
                  f"     {e['state']:02X}     {e['load_t']}")
        we = [e["wait_ever"] for e in tloads.values()]
        print()
        print(f"  WAIT_N ever asserted since reset (sticky): {'YES' if any(we) else 'NO'}")
        if not any(we):
            print("    -> the CPU was NEVER stalled. If a ROM fetch ever took longer than")
            print("       the bus cycle, DI would have been stale and nothing held the CPU.")
        # The decisive automatic call, where the data allows one.
        for i in sorted(tloads):
            e = tloads[i]
            if e["di"] == 0x53 or e["alu"] == 0x53:
                print()
                src = "ALU_OUT" if e["alu"] == 0x53 else "DI"
                print(f"  Entry {i} carries $53 (the TAM opcode) on {src}, at ADDR {e['addr']:04X},")
                print(f"  committed via LOAD_T={e['load_t']}. TAM's microcode row uses 1 = ALU_OUT.")
                print("  Compare that against the TAM instruction's own address in the ROM:")
                print("  equal -> the opcode byte was re-read or never replaced (mechanism b);")
                print("  one greater -> the operand address was driven but stale data came")
                print("  back (also b, bridge side); anything else -> chase the microcode.")
                break


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
        print()
        print(f"heartbeat: {len(beats)} samples (~100 ms apart)")
        print(f"  {'#':>3} {'VDCwr':>7} {'outFrm':>7} {'srcFrm':>7} {'vs_cy':>6} {'vtx':>4}")
        for k, b in enumerate(beats):
            print(f"  {k:3d} {b['vdc']:7d} {b['outf']:7d} {b['srcf']:7d} "
                  f"{b['vs_cy']:6d} {b['vtx']:4d}")

        d_vdc  = beats[-1]["vdc"]  - beats[0]["vdc"]
        d_out  = (beats[-1]["outf"] - beats[0]["outf"]) & 0xFFFF
        d_src  = (beats[-1]["srcf"] - beats[0]["srcf"]) & 0xFFFF
        print()
        print("VERDICT")
        if d_src == 0:
            print("  source frames FLAT -> the core is not emitting frames at all "
                  "(or video_vbl never falls).\n"
                  "  The servo has no input; the video path is downstream of the real "
                  "fault. Look at the core.")
        elif d_out == 0:
            print("  output frames FLAT -> the output raster is stopped. The pixel clock "
                  "or hdmi.sv is the fault.")
        else:
            # PRECISION NOTE. The out/src frame RATIO is a coarse instrument: both are
            # integer counts over a ~3 s window, so it only pins the rate to about
            # +-0.5%, which is the same order as the whole error being measured. The
            # precise instrument is vs_cy -- it is a sub-frame PHASE, and unwrapping its
            # walk measures the period mismatch directly.
            #
            # vs_cy is the output raster line on which the source's active area began.
            # If the source frame is longer than the output frame, that line creeps
            # forward every frame and wraps at frameHeight. Over N output frames the
            # unwrapped creep is exactly N * (frameHeight_needed - frameHeight_current)
            # output lines, so:
            #
            #     frameHeight_needed = frameHeight_current + creep / N
            #
            # No assumption about the core's line count enters, which is the point --
            # the "+2.28 lines/frame" figure that this replaced came from ASSUMING
            # huc6260's 262-line branch, and real hardware showed the 263-line branch.
            # Drop startup samples: vs_cy holds its reset value until the first source
            # frame has been seen, and srcf == 0 marks exactly that window. Including
            # them turns the initial jump-from-zero into fake creep -- on the first log
            # decoded that alone read 6.87 lines/frame instead of the true 5.13.
            # debug.log APPENDS across runs, and the heartbeat reuses tags 0x80-0x9F
            # every run, so an un-cleared log holds several runs back to back. Splitting
            # on the source-frame counter going BACKWARDS keeps only the most recent one;
            # without this the creep is computed across a run boundary and reports pure
            # fiction (a real 64-sample log read "+3.246 lines/frame, needs 758.2" when
            # the last run was in fact locked dead on target).
            runs, cur = [], []
            for b in beats:
                if cur and b["srcf"] < cur[-1]["srcf"]:
                    runs.append(cur); cur = []
                cur.append(b)
            if cur: runs.append(cur)
            if len(runs) > 1:
                print(f"  NOTE: log holds {len(runs)} runs; using the last "
                      f"({len(runs[-1])} samples). Clear debug.log before a run.")
            beats = runs[-1]
            live = [b for b in beats if b["srcf"] > 0]
            if len(live) < 3:
                print("  too few valid samples after the startup window to measure phase.")
                return 1 if (bad_vs_file or disagree) else 0
            d_out = (live[-1]["outf"] - live[0]["outf"]) & 0xFFFF
            d_src = (live[-1]["srcf"] - live[0]["srcf"]) & 0xFFFF
            vtx  = [b["vtx"] for b in live]
            cys  = [b["vs_cy"] for b in live]
            extra = max(set(vtx), key=vtx.count)      # applied vtotal_extra (modal)
            fh    = 750 + extra

            unwrapped, acc = [cys[0]], cys[0]
            for prev, cur in zip(cys, cys[1:]):
                step = cur - prev
                if step < -fh // 2:                    # wrapped forward
                    step += fh
                elif step > fh // 2:                   # wrapped backward
                    step -= fh
                acc += step
                unwrapped.append(acc)
            creep = unwrapped[-1] - unwrapped[0]

            print(f"  core alive: VDC writes +{d_vdc}, source frames +{d_src}, "
                  f"output frames +{d_out}")
            print(f"  applied vtotal_extra = {extra} (min {min(vtx)} max {max(vtx)})"
                  f" -> frameHeight {fh}")
            if len(set(vtx)) > 1:
                print("  !! vtotal_extra is NOT constant -- the raster is being modulated."
                      "\n     Sinks blank on unstable vertical totals; that is a separate"
                      " fault from any drift below.")

            if d_out == 0:
                print("  cannot measure phase: no output frames elapsed.")
            else:
                slip   = creep / d_out                 # output lines per output frame
                needed = fh + slip
                print(f"  vs_cy creep = {creep:+d} lines over {d_out} output frames")
                print(f"  => slip {slip:+.3f} lines/frame; frameHeight NEEDED = "
                      f"{needed:.3f}")
                if abs(slip) < 1e-6:
                    print("  -> LOCKED exactly.")
                else:
                    roll_frames = abs(fh / slip)
                    print(f"  => roll period {roll_frames:.0f} frames = "
                          f"{roll_frames / 60.10:.1f} s")
                # The figure above averages the ACQUISITION transient in with the
                # locked state, which makes it fiction once the servo is working. The
                # last few samples are the honest steady-state measurement.
                if len(live) >= 10:
                    tl = live[-8:]
                    dn = (tl[-1]["outf"] - tl[0]["outf"]) & 0xFFFF
                    cw, ac = 0, tl[0]["vs_cy"]
                    for p0, p1 in zip(tl, tl[1:]):
                        st = p1["vs_cy"] - p0["vs_cy"]
                        if st < -fh // 2: st += fh
                        elif st > fh // 2: st -= fh
                        cw += st
                    ss_extra = sorted({b["vtx"] for b in tl})
                    if dn:
                        print(f"  STEADY STATE (last 8 samples): creep {cw:+d} lines over "
                              f"{dn} frames = {cw/dn:+.3f} lines/frame")
                        print(f"    vs_cy {[b['vs_cy'] for b in tl]}  vtotal_extra {ss_extra}")
                        if abs(cw) <= 2 and len(ss_extra) <= 2:
                            print("    -> LOCKED: phase held and only two adjacent "
                                  "vertical totals in use.")
                best = round(needed) - 750
                print(f"  best static vtotal_extra = {best} "
                      f"(residual {needed - (750 + best):+.3f} lines/frame)")
                frac = needed - int(needed)
                print(f"  for EXACT lock: {int(needed)} lines with {frac:.3f} of frames "
                      f"at {int(needed)+1}")

    return 1 if (bad_vs_file or disagree) else 0


if __name__ == "__main__":
    sys.exit(main())
