#!/usr/bin/env python3
"""Diff a CD register/command stream against an instrumented-mednafen golden trace.

    scripts/cd_golden_diff.py golden/de2_registers.txt sim/cd/cdboot.log

Both sides are normalised to the same token stream and the FIRST divergence is reported,
because that is the only one that means anything -- everything after it is the two sides
running different code.

Accepted input on either side:
  "PCEREG WR $1802 <= 00" / "PCEREG RD $1800 => 80"   instrumented mednafen
  "[cdreg] WR $1802 <= 00" / "[cdreg] RD $1800 => 80" sim/cd/tb_cd_boot.vhd
  "PCECDB: 08 00 0e 06 02 00"                         mednafen's own CDB dump
  "[scsi] cmd #6  op=08  cdb=00000e0602"              the testbench's CDB dump
  "RTL[DB] 00 07 80 81 00 00 00 00"                   the hardware 0xDB stream

$1800 reads and every $1808 access are dropped by default: a real boot polls $1800 ~94000
times and reads 2048 bytes per sector through $1808, which is 99.6% of the trace and none
of the decisions. --with-polls keeps them.
"""
import argparse
import re
import sys

REG = re.compile(r"(?:PCEREG|\[cdreg\])\s+(WR|RD)\s+\$?(18[0-9A-Fa-f]{2})\s*(?:<=|=>)\s*([0-9A-Fa-f]{2})")
CDB_MED = re.compile(r"PCECDB:\s*((?:[0-9a-f]{2}\s*)+)")
CDB_SIM = re.compile(r"\[scsi\] cmd #\d+\s+op=([0-9A-Fa-f]{2})\s+cdb=([0-9A-Fa-f]+)")
# Hardware: one CD-register access per frame. See CDREG_STREAM in
# src/pcetang_console60k_cd.vhd for the payload layout.
RTL_DB = re.compile(r"RTL\[DB\]\s+((?:[0-9A-Fa-f]{2}\s+){7}[0-9A-Fa-f]{2})")


def normalise(path, with_polls=False):
    """-> list of (token, source_line_number, raw_line)."""
    out = []
    last_seq = None
    for n, raw in enumerate(open(path, errors="replace"), 1):
        m = RTL_DB.search(raw)
        if m:
            b = [int(x, 16) for x in m.group(1).split()]
            seq = (b[0] << 8) | b[1]
            entry = (b[2] << 8) | b[3]
            drops = (b[4] << 8) | b[5]
            rw = "WR" if entry & 0x8000 else "RD"
            reg7 = (entry >> 8) & 0x7F
            # The ring stores a(6:0), so bit 7 of the register's low byte is implied: the
            # only registers above $180F that a PCE CD ever touches are the $18C5-$18C7
            # signature bytes, which land at 0x45-0x47 here.
            low = reg7 + 0x80 if reg7 >= 0x40 else reg7
            val = entry & 0xFF
            if last_seq is not None and seq != ((last_seq + 1) & 0xFFFF):
                out.append((f"GAP after seq {last_seq} -> {seq}", n, raw.rstrip()))
            last_seq = seq
            if drops:
                out.append((f"DROPS {drops}", n, raw.rstrip()))
            out.append((f"{rw} $18{low:02x} {val:02x}", n, raw.rstrip()))
            continue
        m = CDB_MED.search(raw)
        if m:
            by = m.group(1).split()
            # mednafen pads every CDB to its own buffer width; the PCE's CDBs are 6 or 10
            # bytes and the trailing zeros carry no information, so compare the opcode and
            # the bytes that the opcode actually defines.
            n_used = 10 if by[0].lower() == "de" else 6
            out.append(("CDB " + " ".join(by[:n_used]).lower(), n, raw.rstrip()))
            continue
        m = CDB_SIM.search(raw)
        if m:
            # The testbench prints cd_comm as one hex number, so byte 0 of the CDB comes
            # out LAST. Reverse it before comparing, or every command reads as a mismatch
            # while actually matching -- which is exactly what this tool did at first.
            hexs = m.group(2).lower()
            by = [hexs[i:i + 2] for i in range(0, len(hexs), 2)][::-1]
            while by and by[0] == "00" and len(by) > 6:
                by.pop(0)
            n_used = 10 if by[0] == "de" else 6
            by = (by + ["00"] * n_used)[:n_used]
            out.append(("CDB " + " ".join(by), n, raw.rstrip()))
            continue
        m = REG.search(raw)
        if m:
            rw, addr, val = m.group(1), m.group(2).lower(), m.group(3).lower()
            if not with_polls:
                if addr == "1808":
                    continue
                if rw == "RD" and addr == "1800":
                    continue
            out.append((f"{rw} ${addr} {val}", n, raw.rstrip()))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("golden")
    ap.add_argument("actual")
    ap.add_argument("--with-polls", action="store_true")
    ap.add_argument("--context", type=int, default=12)
    a = ap.parse_args()

    g = normalise(a.golden, a.with_polls)
    s = normalise(a.actual, a.with_polls)
    print(f"golden: {len(g)} token(s) from {a.golden}")
    print(f"actual: {len(s)} token(s) from {a.actual}")

    i = 0
    while i < len(g) and i < len(s) and g[i][0] == s[i][0]:
        i += 1

    if i == 0:
        print("\nDIVERGE AT THE VERY FIRST TOKEN -- the two sides are not aligned at all.")
    if i >= len(s):
        print(f"\nACTUAL RAN OUT after {i} matching token(s) -- it stopped early, it did not "
              f"diverge.\ngolden's next: {g[i][0] if i < len(g) else '(also ended)'}")
    elif i >= len(g):
        print(f"\nACTUAL WENT PAST the end of golden after {i} matching token(s).")
    else:
        print(f"\nFIRST DIVERGENCE at token {i}:")
        print(f"  golden {a.golden}:{g[i][1]}   {g[i][0]}")
        print(f"  actual {a.actual}:{s[i][1]}   {s[i][0]}")

    lo = max(0, i - a.context)
    print(f"\n--- last {i - lo} matching, then {a.context} each way "
          f"(golden | actual) ---")
    for k in range(lo, i):
        print(f"  = {g[k][0]}")
    for k in range(a.context):
        gk = g[i + k][0] if i + k < len(g) else ""
        sk = s[i + k][0] if i + k < len(s) else ""
        mark = "  " if gk == sk else " !"
        print(f"{mark} {gk:<26} | {sk}")

    # A command-level summary is what you actually act on.
    gc = [t for t, _, _ in g if t.startswith("CDB")]
    sc = [t for t, _, _ in s if t.startswith("CDB")]
    print(f"\ncommands: golden {len(gc)}, actual {len(sc)}")
    for k in range(max(len(gc), len(sc))):
        gk = gc[k] if k < len(gc) else "(none)"
        sk = sc[k] if k < len(sc) else "(none)"
        print(f"  {k+1:2d} {'ok ' if gk == sk else 'DIFF'} golden {gk:<34} actual {sk}")
    return 0 if i >= len(g) and len(g) == len(s) else 1


if __name__ == "__main__":
    sys.exit(main())
