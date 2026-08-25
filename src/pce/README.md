# Vendored PCE RTL (temporary — see docs/ARCHITECTURE.md's "Open, unresolved dependency")

Snapshot copy, 2026-08-26, not a git submodule/subtree — NECTang isn't a tracked repo
yet. Two directories:

- `common/` — NECTang's own forked/written RTL (`src/common/` there): `pce_top.vhd`,
  chip-core forks (`huc6270.vhd`, `psg.vhd`, `arcade.sv`), Gowin memory wrappers
  (`mem/`), per-board PLLs (`pll/`). GPL-3.0-or-later, this author's own work.
- `tg16-mister-rtl/` — the actual RTL subset of `TurboGrafx16_MiSTer`
  (`upstream/tg16-mister/rtl/` in NECTang), pruned from the donor's full clone (which
  also carries ~200MB of prebuilt release binaries and docs images, neither needed
  here). **Licensing note, inherited from NECTang's own `THIRD_PARTY_LICENSES.md`**:
  this donor codebase has no explicit license grant — a documented, risk-accepted gap in
  NECTang, not resolved here either. Read that file (once NECTang itself is tracked
  somewhere pcetang can reference) before assuming this is clean to distribute further.

This will be replaced by a real dependency mechanism (submodule onto a tracked NECTang
repo, most likely) once that decision is made — not part of this session's scope.
