# vram0_prefetch GHDL verification harness

`tb_cg_check.vhd` is a real-trace GHDL testbench for
`src/pce/common/mem/vram0_prefetch.vhd`'s BAT-row and CG0/CG1-row prefetch buffers. It
instantiates the REAL, unmodified `src/pce/common/core/huc6270.vhd` (VDC) and
`src/pce/tg16-mister-rtl/huc6260.vhd` (VCE) — not a synthetic address generator — driving
a real PC Engine-style register-init and VRAM-upload sequence, then a real multi-frame
BG-only display window, against `vram0_prefetch.vhd` and the real
`src/pce/common/mem/vram0_cache.vhd` underneath it. A mock SDRAM responder (calibrated
busy-cycle timing, see the file's own header) stands in for `sdram.sv`.

It reconstructs a live shadow reference model of VRAM0 content from the mock SDRAM's own
real write commits, and on every real BAT/CG0/CG1 read compares the actual delivered
`RAM_DI` against that reference — this is how the original CG0/CG1 tag-aliasing bug
(single global `cg_row_valid_for` register, fixed by moving to a per-entry `{code,row}`
tag in `cg_tag`) was originally found, and how the fix below was verified.

## Compile

```
R=/path/to/pcetang-dev/pcetang
ghdl -a --std=08 -frelaxed -fsynopsys --workdir=work \
  $R/src/pce/common/mem/init/voltab_pkg.vhd \
  $R/src/pce/common/mem/init/huc6260_palette_init_pkg.vhd \
  $R/src/pce/common/mem/bram_gowin.vhd \
  $R/src/pce/common/mem/dpram8x16_dpb_wm01.vhd \
  $R/src/pce/common/mem/dpram9_dpb_wm01.vhd \
  $R/src/pce/tg16-mister-rtl/huc6260.vhd \
  $R/src/pce/common/core/huc6270.vhd \
  $R/src/pce/common/mem/vram0_cache.vhd \
  $R/src/pce/common/mem/vram0_prefetch.vhd \
  tb_cg_check.vhd
```

Notes:
- `-fsynopsys` is required (`huc6260.vhd` uses `ieee.std_logic_unsigned`) — omitting it is
  a hard compile error, not a warning.
- File order matters (entity-before-use, GHDL analyses top to bottom).
- `src/pce/common/mem/bram_gowin.vhd` is the real `dpram`/`dpram_difclk`/`spram` entity set
  actually used by every board's `build_*.tcl` (Gowin BSRAM retarget) — do NOT compile
  `src/pce/tg16-mister-rtl/dpram.vhd` (a dead donor file using `altera_mf`, not part of
  any real build and not GHDL-simulatable without that library).
- `dpram8x16_dpb_wm01.vhd`/`dpram9_dpb_wm01.vhd` instantiate Gowin `DPB`/`DPX9B` primitives
  as unbound components under GHDL (expected `[-Wbinding]` warnings, harmless here: the
  testbench never exercises `huc6270`'s SAT/sprite-line-buffer path, see below).

## Run

Baseline (BAT-only path, proves the harness itself is unchanged/faithful):
```
ghdl -r --std=08 -frelaxed -fsynopsys --workdir=work tb_top \
  -gG_CG_PREFETCH=false -gG_STRESS=false --stop-time=5000ms
```
Expect (exact, historical, harness-fidelity check):
`hit_checked=66739 hit_wrong=0`, `pf_hit_total=226807 pf_overrun_total=0`,
`cg_hit_total=0`.

CG0/CG1 buffer, with stress stimulus (live BYR/scroll-Y rewrite and live SCREEN-width
change mid-run — the two race conditions the original bug and its fix both concern):
```
ghdl -r --std=08 -frelaxed -fsynopsys --workdir=work tb_top \
  -gG_CG_PREFETCH=true -gG_STRESS=true --stop-time=5000ms
```
`--stop-time` is only a safety cap; the testbench self-terminates via `std.env.finish`
once its own measurement window completes (~78.8ms simulated for either run above).

## Real, current results (2026-08-29, `vram0_prefetch.vhd` post-fix — per-entry `cg_tag`
instead of the removed global `cg_row_valid_for`)

Baseline (`G_CG_PREFETCH=false`) — byte-identical to the historical pre-fix baseline,
proving the fix didn't disturb the already-proven BAT-only path:
```
hit_checked=66739 hit_wrong=0
pf_hit_total=226807 pf_overrun_total=0 cg_hit_total=0 cg_overrun_total=0
```

CG0/CG1, with stress (`G_CG_PREFETCH=true G_STRESS=true`) — headline result:
```
STEADY        cg_hit_checked=13172 cg_hit_wrong=0
STRESS_BYR    cg_hit_checked=3442  cg_hit_wrong=0
STRESS_SCREEN cg_hit_checked=3630  cg_hit_wrong=0
overrun_windows_total=12 cg_hit_checked_during_overrun_recovery=50 cg_hit_wrong_during_overrun_recovery=0
pf_hit_total=206663 pf_overrun_total=1 cg_hit_total=169493 cg_overrun_total=12
```
`cg_hit_wrong=0` in every window, including `STRESS_BYR` (the exact scenario the original
bug reproduced in: pre-fix, this same window read `cg_hit_checked=200 cg_hit_wrong=35`).
`STRESS_BYR`'s `cg_hit_checked` landed real, non-degenerate coverage (3442, not the "0/0
unverified gap" a mis-wired stress window would produce), so this is a real pass, not a
vacuous one.

A separate, smaller, pre-existing anomaly in `vram0_cache.vhd`'s own un-buffered path
(documented elsewhere as that file's own deadline-miss behavior, unrelated to
`vram0_prefetch.vhd`) is still present at a similar rate to before the fix:
```
QACAL off=0 hit_checked=65253 hit_wrong=50
```
Every one of these wrong values coincides with `dbg_cg_hit='0'` (the CG buffer correctly
reporting a miss; the wrong data comes from `vram0_cache`'s own pre-existing fallback
path) — never `dbg_cg_hit='1'`. This is proven two ways: (1) `hitwrong_dump`'s first 30
instances all show `dbg_cg_hit='0'` explicitly; (2) exhaustively, since `cg_check`'s own
`STEADY`/`STRESS_BYR`/`STRESS_SCREEN` tally covers every real read cycle where
`dbg_cg_hit='1'` regardless of `vram0_cache`'s own `hit_e`, and all three read
`cg_hit_wrong=0` — so no `dbg_cg_hit='1'` cycle anywhere in the run delivered a wrong
value. Not a regression from this fix.
