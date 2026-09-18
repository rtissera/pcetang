#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand

"""List source files that no build script compiles, and say why each one is there.

    scripts/audit_sources.py          # report
    scripts/audit_sources.py --check  # exit 1 if an unexpected file is unreferenced

This exists because of a real bug that cost a whole build. src/pce/ carries pristine
copies of several donor files ALONGSIDE the modified copies the builds actually compile:

    src/pce/tg16-mister-rtl/arcade.sv     pristine donor, compiled by NOTHING
    src/pce/common/core/arcade.sv         ours, compiled by all three boards

An Arcade Card change was made to the first one. It synthesised cleanly, changed nothing,
and the result was misread as "the change had no effect" -- when in fact the edited file
had never been part of the design. The same trap is set for huc6270.vhd, pce_top.vhd,
cheatcodes.sv and HUC6280/psg.vhd.

The pristine copies are deliberately KEPT: they are the diff baseline that tells our
modifications apart from srg320's original, which is what THIRD_PARTY_LICENSES.md's
file-by-file provenance rests on. So the fix is not deletion, it is making the situation
visible -- run this before editing anything under src/pce/tg16-mister-rtl/.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, os.pardir))

# Unreferenced ON PURPOSE. Anything unreferenced and NOT listed here is a finding.
EXPECTED_UNREFERENCED = {
    "src/pce/tg16-mister-rtl/huc6270.vhd":
        "pristine donor; the build compiles src/pce/common/core/huc6270.vhd",
    "src/pce/tg16-mister-rtl/pce_top.vhd":
        "pristine donor; the build compiles src/pce/common/core/pce_top.vhd",
    "src/pce/tg16-mister-rtl/arcade.sv":
        "pristine donor; the build compiles src/pce/common/core/arcade.sv",
    "src/pce/tg16-mister-rtl/cheatcodes.sv":
        "pristine donor; the build compiles src/pce/common/core/cheatcodes.sv",
    "src/pce/tg16-mister-rtl/HUC6280/psg.vhd":
        "pristine donor; the build compiles src/pce/common/core/psg.vhd",
    "src/pce2hdmi.sv":
        "superseded by src/pce2hdmi_sd.sv (the scandoubler version all boards use)",
}

SRC_EXT = (".vhd", ".sv", ".v")
# Only things that actually BUILD: Gowin project files and GHDL/Verilator runners.
# Deliberately not .md or .py -- a document that mentions a file does not compile it,
# and including them made this script count its own docstring as a reference.
SCAN_EXT = (".tcl", ".sh")


def referenced_paths():
    """Every src/... path fed to a synthesis project or a simulation runner."""
    found = set()
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in (".git", "impl")]
        for name in files:
            if not name.endswith(SCAN_EXT):
                continue
            try:
                text = open(os.path.join(base, name), errors="replace").read()
            except OSError:
                continue
            found.update(re.findall(r"src/[\w./-]+\.(?:vhd|sv|v)", text))
    return found


def main():
    check = "--check" in sys.argv
    refs = referenced_paths()

    sources = []
    for base, dirs, files in os.walk(os.path.join(ROOT, "src")):
        dirs[:] = [d for d in dirs if d != ".git"]
        for name in files:
            if name.endswith(SRC_EXT):
                sources.append(os.path.relpath(os.path.join(base, name), ROOT))

    unref = sorted(p for p in sources if p not in refs)
    known = [p for p in unref if p in EXPECTED_UNREFERENCED]
    surprises = [p for p in unref if p not in EXPECTED_UNREFERENCED]
    stale = sorted(p for p in EXPECTED_UNREFERENCED if p not in unref)

    print(f"{len(sources)} source files, {len(sources) - len(unref)} compiled, "
          f"{len(unref)} unreferenced\n")

    if known:
        print("Unreferenced on purpose -- do NOT edit these expecting an effect:")
        for p in known:
            print(f"  {p}\n      {EXPECTED_UNREFERENCED[p]}")
        print()

    if surprises:
        print("UNEXPECTED -- unreferenced and undocumented. Either wire it into a build")
        print("script or add it to EXPECTED_UNREFERENCED with a reason:")
        for p in surprises:
            print(f"  {p}")
        print()

    if stale:
        print("STALE ENTRIES -- listed as unreferenced but something compiles them now.")
        print("Remove them from EXPECTED_UNREFERENCED:")
        for p in stale:
            print(f"  {p}")
        print()

    if not surprises and not stale:
        print("OK: every unreferenced file is a documented, deliberate one.")
        return 0
    return 1 if check else 0


if __name__ == "__main__":
    sys.exit(main())
