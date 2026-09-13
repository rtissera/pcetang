#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand

"""Emit a disc's TOC in the exact convention firmware-bl616's pcecd_read_toc() uses.

    scripts/cd_toc.py game.chd > de2_toc.txt

Output: one "<track> <control> <lba>" line per real track, then track 100 = the lead-out.
That is the same one-write-per-track order the MCU sends over the wire, so
sim/cd/tb_cd_boot.vhd can replay it verbatim into cd_bridge's TOC_WR port.

The arithmetic below is a line-for-line port of pcecd_read_toc(): plba starts at -150,
track 1 always gets a 150-frame pregap, a PGTYPE starting with 'V' means the pregap is
NOT in the file (so it advances the logical LBA only), and everything else means the
pregap is real. Verified against an instrumented mednafen run of Dungeon Explorer II:
track 2 = LBA 3590, track 34 = LBA 299077, lead-out = LBA 316011, all three matching.
"""
import re
import subprocess
import sys

META = re.compile(
    r"TRACK:(\d+) TYPE:(\S+) SUBTYPE:(\S+) FRAMES:(\d+) PREGAP:(\d+) "
    r"PGTYPE:(\S+) PGSUB:(\S+) POSTGAP:(\d+)"
)


def main(chd, chdman="chdman"):
    info = subprocess.run([chdman, "info", "-v", "-i", chd],
                          capture_output=True, text=True).stdout
    plba, n, out = -150, 0, []
    for m in META.finditer(info):
        _, ttype, _, frames, pregap, pgtype, _, postgap = m.groups()
        frames, pregap, postgap = int(frames), int(pregap), int(postgap)
        n += 1
        real_pregap = 150 if n == 1 else (0 if pgtype[0] == "V" else pregap)
        real_pregap_dv = pregap if pgtype[0] == "V" else 0
        plba += real_pregap + real_pregap_dv
        out.append((n, 0x00 if ttype == "AUDIO" else 0x04, plba))
        plba += (frames - real_pregap_dv) + postgap
    if not out:
        sys.exit("no track metadata in %s" % chd)
    for t, ctl, lba in out:
        print("%d %d %d" % (t, ctl, lba))
    print("100 0 %d" % plba)
    print("# %d real track(s), lead-out LBA=%d" % (n, plba), file=sys.stderr)


if __name__ == "__main__":
    main(*sys.argv[1:])
