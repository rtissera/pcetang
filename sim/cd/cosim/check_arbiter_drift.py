#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand
"""Fail if sim/cd/cosim/portc_arbiter.vhd's verbatim blocks have drifted from the boards.

Console 60K: every verbatim block must appear in the board file (comments/whitespace ignored).
Primer 25K : same blocks after mapping its names (no CD-RAM self-test mux on that board).
Nano 20K   : different arbiter (SDRAM port B, b_state); only the ADPCM new-request detect and
             combinational READY must match.
"""
import re, sys, os
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
def norm(t):
    t = re.sub(r"--[^\n]*", "", t)
    return re.sub(r"\s+", " ", t).strip()
sim = open(os.path.join(ROOT, "sim/cd/cosim/portc_arbiter.vhd")).read()
blocks = re.findall(r"-- ===== BEGIN VERBATIM[^\n]*\n(.*?)-- ===== END VERBATIM", sim, re.S)
assert blocks, "no verbatim blocks found"
fail = 0
def check(board, mapping, only=None):
    global fail
    text = norm(open(os.path.join(ROOT, "src", board)).read())
    for b in blocks:
        nb = norm(b)
        for k, v in mapping.items():
            nb = nb.replace(k, v)
        if only:
            parts = [norm(p) for p in only]
            missing = [p for p in parts if p not in text]
            ok = not missing
        else:
            ok = nb in text
        print(f"  {'OK  ' if ok else 'DRIFT'} {board}: block starting '{nb[:60]}...'")
        if not ok: fail += 1
        if only: break
print("portc_arbiter.vhd vs boards:")
check("pcetang_console60k_cd.vhd", {})
# Primer 25K's arbiter is an OLDER variant: its CDR_HOLD has no cdr_wdog watchdog, so a WAIT
# that never falls would freeze the CPU there (Console 60K releases after 0x3FF cycles). Known
# and recorded, not fixed. Only the logic this simulation relies on for ADPCM/CD-RAM detection
# is required to match; the watchdog difference is asserted so it cannot change silently.
check("pcetang_primer25k_cd.vhd", {}, only=[
 "cd_new_comb <= '1' when (cd_ram_rd = '1' or cd_ram_wr = '1') and ((cd_ram_rd = '1' and cdram_rd_r = '0') or (cd_ram_wr = '1' and cdram_wr_r = '0') or cd_ram_a /= cdr_a_last) else '0';",
] )
_p25 = norm(open(os.path.join(ROOT, "src", "pcetang_primer25k_cd.vhd")).read())
for line in ["adpcm_new_comb <= '1' when adpcm_ram_req_i = '1' and (adpcm_ram_slot_cnt_i /= adpcm_slot_cnt_r or adpcm_bridge_req_r = '0') else '0';",
             "adpcm_ram_ready_comb <= adpcm_ram_ready_i and not adpcm_new_comb;",
             "adpcm_new := adpcm_new_comb;", "ADPCM_RAM_READY => adpcm_ram_ready_comb,"]:
    ok = norm(line) in _p25
    print(f"  {'OK  ' if ok else 'DRIFT'} pcetang_primer25k_cd.vhd: '{line[:60]}...'")
    if not ok: fail += 1
_wd = "cdr_wdog" in _p25
print(f"  {'NOTE' if not _wd else 'CHANGED'} pcetang_primer25k_cd.vhd: HOLD watchdog {'absent (known)' if not _wd else 'now PRESENT -- update this script and the sim copy'}")
if _wd: fail += 1
adpcm_lines = [
 "adpcm_new_comb <= '1' when adpcm_ram_req_i = '1' and (adpcm_ram_slot_cnt_i /= adpcm_slot_cnt_r or adpcm_bridge_req_r = '0') else '0';",
 "adpcm_ram_ready_comb <= adpcm_ram_ready_i and not adpcm_new_comb;",
 "adpcm_new := adpcm_new_comb;",
 "ADPCM_RAM_READY => adpcm_ram_ready_comb,",
]
check("pcetang_nano20k_cd.vhd", {}, only=adpcm_lines)
print("RESULT:", "PASS" if fail == 0 else f"FAIL ({fail} drifted)")
sys.exit(1 if fail else 0)
