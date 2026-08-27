# pcetang architecture — TangCore integration plan

Goal (set 2026-08-26): build pcetang Phase 1-3 on Console 60K, Primer 25K, and Nano 20K
(TangCore-integrated: ROM load, joypad, OSD via `iosys_bl616`), real `gw_sh` results.

This core is the PC Engine / SuperGrafx / TurboGrafx-CD chip-level RTL from
[NECTang](../../NECTang) (this same author's separate, standalone-board port —
`docs/PORTING.md` there has the full real-`gw_sh` history: CPU/PSG/VCE/VDC, CD/SCSI/ADPCM,
SGX, on all three boards, with real measured resource numbers). pcetang wires that RTL
into `nand2mario/tangcore`'s BL616-based loader/OSD/joypad framework instead of
NECTang's own fixed-test-pattern bring-ups.

## What TangCore actually provides (verified against real source, not the README)

Read directly from `rtissera/nestang` (private fork of `nand2mario/nestang`, TangCore's
own documented template for a new core) at clone time 2026-08-25/26:

- **`src/iosys/iosys_bl616.v`** (546 lines) — the entire UART protocol engine to the
  BL616 companion MCU. Key ports this core must drive/consume:
  - `overlay`/`overlay_x`/`overlay_y`/`overlay_color` (BGR5) — OSD pixel interface,
    256x224, backed internally by `textdisp.v` + `gowin_dpb_menu.v` (a Gowin BSRAM
    character/font memory — small, cheap).
  - `joy1`/`joy2` (12-bit DS2/SNES-style) and `hid1`/`hid2` (16-bit USB HID) — joypad
    input, both DS2 PMOD and USB paths already handled by the framework.
  - `rom_loading`/`rom_do`/`rom_do_valid` — the ROM byte stream. `rom_loading` pulses
    0→1 at load start, 1→0 at load end; `rom_do`/`rom_do_valid` is a plain byte-at-a-time
    stream, no addressing — the CONSUMER (this core) tracks its own write address as
    bytes arrive.
  - `mgmt_address`/`mgmt_read`/`mgmt_write`/`mgmt_readdata`/`mgmt_writedata` +
    `fdd_request[1:0]` — a **sector-level block-device interface**, already built and
    working for `pctang` (PC/XT)'s floppy disk emulation. UART commands `0x0a`/`0x0b` and
    responses `0x04`/`0x05` (see protocol table in the file) move 512-byte sectors by LBA
    between BL616 (which owns the filesystem) and the FPGA core. **This is the interface
    to extend for CD, not a new protocol** — see "CD via CHD" below.
  - `uart_tx`/`uart_rx` — physical UART pins to the BL616, 2 Mbps.
  - `kbd_data`/`kbd_data_valid` — PS/2-style scancode stream (PCXT-specific management,
    likely irrelevant to a PCE core, kept for reference).

- **`src/nestang_top.sv`** (469 lines) — the wiring pattern. Confirmed by reading it
  directly (not assumed from the dev-guide's prose):
  - `rom_do`/`rom_do_valid` → `game_loader`'s `indata`/`indata_clk`, which parses the
    iNES header and produces a plain `mem_addr`/`mem_data`/`mem_write` stream into a
    dual-port on-chip BRAM shared with the CPU's cartridge-read port (mux on `loading`).
    For a HuCard-only PCE build (no CD), the equivalent is trivial: replace NECTang's
    fixed-test-pattern `spram` in each board bring-up with one gated by `rom_loading`,
    writing `rom_do` at an internally-tracked incrementing address while
    `rom_do_valid` pulses. No NES-style header parsing needed (PCE headers are simpler
    metadata already partly hardcoded in NECTang's `ROM_SZ`/`ROM_POP` handling).
  - `nes2hdmi` — the NES-specific scan-doubler/scaler feeding the shared `hdmi2/hdmi.sv`
    TMDS output core at 720p. **This needs a real PCE-specific equivalent
    (`pce2hdmi.sv` or similar) — not reusable as-is.** PCE's VDC outputs its own
    dot-clock/scanline timing (NTSC-ish, non-square pixels, variable per-game
    resolution modes), structurally different from NES's fixed PPU timing. This is new
    design work, sized similarly to `nes2hdmi.sv` (268 lines) but not a port — needs
    real thought about which PCE video mode(s) to support first pass.
  - `joy1_btns | joy_usb1` → `iosys_bl616.joy1` — DS2/SNES-shaped buttons OR'd with USB
    HID, both already decoded upstream. PCE's controller is simpler (2-button pad, no
    SNES-style extra buttons) — bit mapping needs a real spec check against PCE pad
    layout, not assumed to line up with the NES bit order used here.

- **`src/iosys/textdisp.v`** — 32x28 text-mode OSD overlay, self-contained, reusable
  as-is (already copied into `pcetang/src/iosys/`, along with its `gowin_dpb_menu.v`
  BSRAM backing and `iosys_bl616.v`'s own UART engine in `uart_fixed.v`).

- **`src/hdmi2/*.sv`** — the shared TMDS/HDMI output core (10 files, video+audio info
  frames, packet assembly, serializer). Copied as-is into `pcetang/src/hdmi2/`; this is
  genuinely reusable, board/core-agnostic 720p HDMI output — same one every TangCore
  core uses. **Not yet build-tested against this project's Gowin toolchain** — the
  serializer likely instantiates a Gowin-specific OSER10 primitive; first real `gw_sh`
  attempt will confirm or find a gap, per this project's own "measure don't deduce"
  discipline (see NECTang's `docs/PORTING.md` for why that discipline exists — it found
  real toolchain bugs nobody would have guessed from inspection).

## Board support reality (verified, not assumed)

From `tangcore`'s own install guide (`doc/tangcore_install.md`, fetched 2026-08-25):

| Board | Status |
|---|---|
| Tang Console 60K | ✔️ Great |
| Tang Mega 60K / 138K | ✔️ Great |
| Tang Primer 25K | ⚠️ Limited (NESTang, SNESTang only) |
| Tang Nano 20K | ❌ Not working ("Unsupported") |

Checked separately (web search, 2026-08-25): Nano 20K **does** have the BL616 MCU
onboard (it's the same chip used for JTAG programming/UART-over-USB on that board) — so
"not working" is a software/porting gap, not a missing-hardware wall. `nestang` itself
has a `nestang_nano20k.gprj` project (single-core, presumably the older
`iosys_picorv32` RISC-V-softcore IO path, not `iosys_bl616`) — meaning Nano 20K support
for the BL616/TangCore path specifically has never been built by anyone, for any core.
This is new bring-up work, not a resurrection of something broken.

**Real risk for Nano 20K specifically**: it's the smallest chip in the lineup (20K LUT4),
and NECTang's own real, measured builds already use 63-81% of Nano 20K's Logic just for
the PCE engine + CD + backup RAM (see NECTang's `README.md` status table). Adding
`iosys_bl616` + HDMI + OSD framework overhead on top is a real, unmeasured question —
could genuinely not fit. Not assumed either way; first real Nano 20K `gw_sh` attempt
(after Console 60K and Primer 25K prove the pattern) will measure it for real.

## CD via CHD — reusing the FDD sector interface, not inventing a new one

`rtissera/libchdr`'s `contrib/tangcore-bl616/` (own prior work, checked 2026-08-25) has
a real `chd_fatfs.c` (FatFS-backed CHD reader) and a patch vendoring it into
`firmware-bl616`, currently only link-probed (not wired to an actual loader — its own
`Status` note says so explicitly).

`iosys_bl616.v`'s existing `mgmt_*`/`fdd_request` sector interface (UART commands
`0x0a`/`0x0b`, responses `0x04`/`0x05`, 512-byte sectors by LBA) was built for `pctang`'s
floppy emulation but is structurally exactly what CD sector access needs: LBA-addressed,
sector-granularity, request/response over the same UART link. The real work for Phase 2:

1. In the `firmware-bl616` fork (`rtissera/firmware-bl616`, private): wire
   `chd_fatfs_open()`/`chd_read()` to actually answer `mgmt_address`/`fdd_request` reads
   with real CHD-decoded sector data, instead of (or alongside) raw FAT-image sectors.
   CD sectors are 2048 bytes vs. the existing 512-byte floppy sector — either extend the
   protocol's sector size or serve 4 consecutive 512-byte LBAs per CD sector. Needs a
   real design decision, not made here.
2. In `pcetang`'s FPGA side: bridge the `mgmt_*` sector stream to NECTang's already-real,
   already-measured `cd.vhd`/SCSI/ADPCM path (`CD_RAM_A`/`CD_RAM_DI`/`CD_RAM_DO`/
   `CD_RAM_RD`/`CD_RAM_WR` ports on `pce_top.vhd`) — this needs the external-RAM/SDRAM
   work NECTang's own `docs/PORTING.md` already scoped as its own project (multi-bank
   SDRAM controller widening, in progress there in scratch, separate from this repo).

## Phased plan

**Phase 1 — Console 60K, HuCard-only (no CD, no SGX), real `gw_sh` bitstream.**
Smallest real slice: `pcetang_top.sv` instantiating `iosys_bl616` + `hdmi2` + a new
`pce2hdmi.sv` (new work) + NECTang's `pce_top.vhd` (`LITE=1`, `NO_CD=1`, matching
NECTang's own already-proven Console 60K config), ROM loading via `rom_do`/`rom_loading`
into on-chip BRAM (no external memory needed for Console 60K per NECTang's own numbers —
whole engine fits on-chip there), joypad via `joy1`/`joy2` into `pce_top`'s `JOY_IN`. This
is the phase that proves the integration pattern; get it real and measured before Primer
25K or Nano 20K.

**Phase 2 — CD via CHD (Console 60K first, since it's the only board with CD already
proven to fit, per NECTang's `docs/PORTING.md`).** Needs Phase 1's ROM path (CD games
still need the initial IPL/BIOS-style boot ROM), the `firmware-bl616` CHD-sector work
above, and NECTang's SDRAM-external-RAM work for the Arcade Card / CD RAM window
(separate project, tracked in NECTang's own docs, not duplicated here).

**Phase 3 — Primer 25K and Nano 20K.** Apply the Phase 1 pattern to each board's own
pin/PLL/SDRAM specifics (NECTang already has real, measured per-board differences
documented — GW5A vs. GW2AR, on-package vs. PMOD SDRAM). Primer 25K is "experimental"
even for NESTang/SNESTang in TangCore today — expect to hit real gaps, not a clean
port. Nano 20K is genuinely new territory (see board-support section above) — Logic
budget is the real open question, measure before assuming it fits.

## Status (2026-08-26)

Research phase complete: real source read (not just docs) for `iosys_bl616.v`,
`nestang_top.sv`, `textdisp.v`, board-support table, `libchdr`'s BL616 integration.
Repos forked/created (`rtissera/tangcore`, `rtissera/firmware-bl616`, `rtissera/nestang`,
`rtissera/pcetang`, all private). Reusable infrastructure (`iosys_bl616.v`, `textdisp.v`,
`uart_fixed.v`, `gowin_dpb_menu.v`, `hdmi2/*.sv`) copied into this repo's `src/`.

**Phase 1 (Console 60K): real bitstream, 2026-08-26.** `pcetang_console60k.vhd` +
`pce2hdmi.sv` (new file, first cut, see its own header) + `pcetang_console60k_hdmi_pll.vhd`
wired together and built via `build_console60k.tcl`. Five real `gw_sh` attempts, each
fixing one concrete, measured problem, none guessed:

1. `iosys_bl616.v`'s `kbd_data` port fixed from `input` to `output` (`ERROR (EX0344)`,
   multiple drivers) -- a genuine donor bug, apparently unhit until this repo's top-level
   actually connected the port (no other TangCore core wires up PCXT's keyboard
   interface). Fixed in this repo's vendored copy, documented at the fix site.
2. ROM buffer sized 512K (`addr_width=19`) -- `ERROR (RP0001)`, 3,518,715 DFF needed.
   Not an inference bug: 512K x8 alone is bigger than Console 60K's entire on-chip BSRAM
   (118 blocks x 18Kbit =~ 2.1Mbit). Corrected to 32K (`addr_width=15`), the same
   proven-safe depth class NECTang's own PRAM/RAM/VRAM0/VRAM1 already use.
3. HDMI PLL (`pcetang_console60k_hdmi_pll.vhd`) needed three rounds to find this part's
   real constraints, each a genuine measured number: `MDIV_SEL=297` silently replaced by
   a default (`WARN (EX0205)`, invalid parameter); `MDIV_SEL=30/IDIV_SEL=1` (FVCO 1500
   MHz) rejected by `WARN (PA1019)`, real VCO range 700-1400 MHz; `IDIV_SEL=4` (PFD 12.5
   MHz) rejected by `ERROR (PA2078)`, real PFD range 19-87.5 MHz. Landed on
   `IDIV_SEL=2`/`MDIV_SEL=30` (FVCO 750 MHz, reusing the already-parameter-confirmed 30):
   clk_pixel 75.000 MHz / clk_5x_pixel 375.000 MHz, +1.01% vs. the 74.25/371.25 HDMI
   spec, exact 5x ratio preserved.
4. An SDC syntax error (`ERROR (TA2000)`) on the original multi-clock-name
   `set_clock_groups` form -- Gowin's parser wants `get_clocks`, not a bare
   space-separated name list, inside one `-group`.

Real result, `impl/pnr/pcetang_console60k.fs`:

```
Logic     7883/59904  (14%)
Register  3049/60780  (6%)
CLS       5185/29952  (18%)
BSRAM     106/118     (90%)   -- SDPB 56, DPB 38, DPX9B 3, pROMX9 9
Setup violations: 0    Hold violations: 0
```

BSRAM at 90% (up from NECTang's own 82/118 baseline for the bare engine) is the number
to watch going forward -- the new TangCore/HDMI/framebuffer infrastructure costs 24
blocks on top of the engine, not nothing. **Not verified on real hardware** -- pin
assignments for the BL616 UART link are still unconfirmed (see `pcetang_console60k.cst`),
joypad button mapping is a first guess, and the video capture in `pce2hdmi.sv` has never
been checked against an actual picture. A clean `gw_sh` run proves synthesis/timing
closure, not a working picture or working controls.

Next: Primer 25K and Nano 20K (Phase 3), then CD/CHD (Phase 2) -- see the goal state for
current priority order.

**Open, unresolved dependency**: NECTang itself is not a git repository yet (local
working tree only, no `.git`) — this repo's plan to pull `pce_top.vhd` and the rest of
NECTang's `src/common/` from it assumes that dependency will exist in some form
(submodule, subtree, or plain copy) before Phase 1's top-level file can actually
reference it. Not resolved here — turning NECTang into a tracked, pushable repo is a
separate, real decision (what to `.gitignore` — `impl/` alone is a large volume of
generated synthesis artifacts — and whether/where to push it) that wasn't part of this
session's authorization and should be confirmed explicitly, not assumed.

**Phase 1 (Primer 25K): real bitstream, but NOT clean, 2026-08-26.**
`pcetang_primer25k.vhd` reuses the Console 60K pattern plus NECTang's own real,
proven `EXT_VRAM0=>1` external-SDRAM wiring (`sdram.sv`, required here — Primer 25K's
whole engine does not fit on-chip, unlike Console 60K). HDMI/UART pins reused directly
from nand2mario's own `nestang` `primer25k.cst` (his own board, his own working config)
rather than adapted like Console 60K's cross-protocol guess.

One real problem found and fixed before reaching a bitstream: the same 256x224
framebuffer that worked fine on Console 60K (118 total BSRAM blocks) hit `ERROR
(IF0008): 65536 DFF ... exceeds the resource limit(23280)` on Primer 25K (only 56 total
BSRAM blocks) — the front-end never named which specific memory failed, but by
elimination it's the largest single new memory relative to the working Console 60K
build. Parameterized `pce2hdmi.sv`'s `CAP_WIDTH`/`CAP_HEIGHT` (default still 256x224,
unchanged for Console 60K) and instantiated Primer 25K at 160x144 — inference cleared.

Real result, `impl/pnr/pcetang_primer25k.fs`:

```
Logic     12691/23040  (56%)
Register  8193/23280   (36%)
CLS       10210/11520  (89%)
BSRAM     56/56        (100%)  -- SDPB 34, DPB 6, DPX9B 7, pROMX9 9
Setup violations: 136   Hold violations: 100
```

**Root-caused and fixed, not left as "probably congestion."** The BSRAM/CLS-congestion
theory above was wrong — checked instead of assumed, by reading the actual violating
paths in `pcetang_primer25k_tr_content.html`'s Setup/Hold Slack tables. Every single one
of the 236 violations (136 setup + 100 hold) started at the identical net,
`sdram_inst/RAM_A_WAIT_s0/Q`, clocked by `pll/PLLA_inst/CLKOUT1.default_gen_clk` — an
**undeclared, auto-generated clock object**, because `pcetang_primer25k.sdc` never
declared `clk_sdram` (the PLL's `CLKOUT1`, feeding `sdram.sv`) at all. Every path landed
in `core/gen_vram0_ext.VRAM0/...` on `clk_pce` — a genuine `clk_sdram`-to-`clk_pce`
clock-domain crossing that the SDC gave the tool zero information about, so it was
analyzed as ordinary same-clock logic (worst slack -6.881 ns) instead of the
multicycle-tolerant boundary `vram0_cache.vhd` actually implements.

NECTang's own real, proven `primer25k_core_test.sdc` (checked directly) already has the
exact fix for this boundary: `create_generated_clock -name clk_sdram` plus
`set_multicycle_path -setup 3`/`-hold 2` in both directions between `clk_pce` and
`clk_sdram`. Applied verbatim, not re-derived. Real result after rebuilding, identical
resource numbers, timing now closed:

```
Logic     12691/23040  (56%)
Register  8193/23280   (36%)
CLS       10210/11520  (89%)
BSRAM     56/56        (100%)  -- SDPB 34, DPB 6, DPX9B 7, pROMX9 9
Setup violations: 0    Hold violations: 0
```

**Phase 1 is now real and clean on both Console 60K and Primer 25K.** The lesson worth
keeping: when a build isn't clean, read the actual violating paths before theorizing
about congestion or utilization — the real cause here was one missing clock
declaration, not the numbers that looked suspicious (BSRAM 100%, CLS 89%) at first
glance.

**Correction (2026-08-26, later same day): "clean" here means "silent."** Every Phase 1
top ties `PSG_SL`/`PSG_SR => open` (`pcetang_console60k.vhd`'s own header already named
this: "nothing wires PSG/CDDA/ADPCM outputs to anything"), so `psg` and its BSRAM get
dead-code-swept on all three boards, same as the Phase 2 CD builds until the correction
above. The Phase 2 audio-observability test (Console 60K CD variant, `66110ee`) measured
this cost directly and for real: wiring `PSG_SL`/`PSG_SR` live costs **6 more BSRAM
blocks** than the silent baseline. PSG is the same RTL regardless of board or CD — this
number doesn't shrink on a smaller device.

**Primer 25K's Phase 1 result above, `BSRAM 56/56 (100%)`, is a zero-headroom result.**
It does not need a new `gw_sh` run to show what adding PSG's 6 blocks would do: there is
no free block to put them in. **This "clean" Phase 1 build describes a PC Engine with
no sound and no room to add any**, not a placeholder gap that can be closed later
without changing something else first. This is a materially stronger claim than "not
verified on hardware" — it's a real, already-measured capacity shortfall on the goal's
own Phase 1 deliverable for this board.

Console 60K's Phase 1 has real headroom (Phase 1 alone measures well under its device's
118-block ceiling — see its own numbers earlier in this section) and the CD-variant
audio result is at least a same-board, same-device data point suggesting it's fine.
Nano 20K's Phase 1 is `37/46 (81%)`, 9 blocks free against a 6-block cost — plausible on
the numbers, but **not directly measured**: Nano 20K's Phase 1 top uses `pce2hdmi.sv`,
not the `pce2hdmi_sd.sv` variant PSG was wired into here, so confirming it would mean
adding the same audio ports to the shared `pce2hdmi.sv` file all three Phase 1 tops
depend on — a wider blast radius than the CD-only variant this fix was made in, and a
deliberate follow-up, not a quick one. Not attempted this session.

**Update (2026-08-27): the zero-headroom claim above is now obsolete.** Per an
independent Fable-model audit's finding that no board could load a real commercial
HuCard (`ROM_ABITS:=15`, 32K on-chip, smallest real HuCard is 128K; `ROM_SZ=>x"008"`
hardcoded, always hit `pce_top`'s straight-1MB-mapping else branch regardless of real
size), Primer 25K's Phase 1 ROM moved off the on-chip `dpram` onto SDRAM port B (same
read/write bridge pattern as `pcetang_primer25k_cd.vhd`'s proven syscard ROM bridge,
copied verbatim). New 1MB region covers every standard HuCard size `pce_top.vhd:672-680`
can mirror (128K/256K/384K/512K/768K/1MB) -- SF2's 2560K bank-switched mapper is not
supported (would need a separate `rombank` register `pce_top` has no port for).
`ROM_SZ` is now latched dynamically from the real loaded byte count (`rom_wr_addr` at
`rom_loading`'s falling edge), replacing the hardcoded value that was always wrong for
anything but the "1MB and others" fallback bucket.

While there, fixed a real, separate bug surfaced during this work: `RESET`/`COLD_RESET`
only ever depended on board-level `reset_n` (button+PLL), never on `rom_loading` -- the
CPU ran the *entire* ROM load, issuing real `ROM_RD` fetches into a partially-written
SDRAM region while port B was mux'd to the write side, reading back stale/torn data.
New `core_resetn` holds the core in reset through the whole load, releasing exactly on
`rom_loading`'s falling edge -- the same shape as NECTang's own `nestang_top.sv`
reference (`reset_nes`). Same missing gate confirmed still present, unfixed, on
nano20k/console60k/console60k_cd (not touched this pass).

Real `gw_sh` result, `impl/pnr/pcetang_primer25k.fs` (GW5A-25A):

```
Logic     9038/23040   (40%)
Register  4000/23280   (18%)
CLS       6247/11520   (55%)
BSRAM     45/56        (81%)  -- SDPB 22, DPB 7, DPX9B 7, pROMX9 9
DSP       1/28         (4%)
clk_pce:    42.857 MHz constraint, 43.398 MHz actual Fmax (+1.26%)
clk_sdram:  120.000 MHz constraint, 120.300 MHz actual Fmax (+0.25%)
clk_pixel:  75.000 MHz constraint, 76.237 MHz actual Fmax (+1.65%)
Setup/Hold TNS: 0 ns on every clock (0 violations)
```

**BSRAM dropped from `56/56 (100%)` to `45/56 (81%)` -- 11 blocks freed**, moving the ROM
off-chip cost far less BSRAM than the 32K on-chip store it replaced (SDPB 34->22, the
rest of the bridge is pure logic/registers). **This directly resolves the zero-headroom
finding above**: PSG's measured 6-block cost (see the Phase 2 audio-observability result
this section already cites) now fits inside the new 11-block margin with room to spare.
Wiring audio into this build is a follow-up, not attempted in this pass.

Toolchain note: this `gw_sh` run needed `gowin-edu`, not `gowin-pro` -- `gowin-pro`'s
`gw_sh` segfaults inside its own `libgwsyn.so` during the inference stage on this
machine, reproduced on a completely unmodified board file (not caused by this change),
independent of display/GL setup (tried both a real X session and headless Xvfb+software
GL, identical crash both ways). `gowin-edu` completes the same builds cleanly. Also
needed `LD_PRELOAD=<system libfreetype.so.6>` (system `fontconfig` needs newer symbols
than Gowin's bundled `libfreetype`) and `LD_LIBRARY_PATH=<gowin IDE>/lib` (so a bundled
lib's own transitive dependency resolves to the matching bundled Qt rather than the
system copy).

**Phase 1 (Nano 20K): real bitstream, clean on the first real attempt after one SDC
fix, 2026-08-26.** Caught before building, not after: PCE is NTSC-native 60 Hz, and
`nano20k_pll.vhd`'s existing HDMI clock pair (`clk_135`/`clk_27`, unused until now) was
originally derived for 720x576p**50** (PAL) — reusing it for PCE would have gotten the
refresh rate wrong, not just the clock accuracy. Fixed by parameterizing
`pce2hdmi.sv`'s video mode (`VIDEOID`, `CLKFRQ`, `SCREEN_WIDTH/HEIGHT`, `WINDOW_WIDTH`,
`VIDEO_REFRESH`, all defaulting to Console 60K/Primer 25K's unchanged 720p60) and using
`VIDEO_ID_CODE=2` (CEA-861 720x480p, NTSC-region 60 Hz) for Nano 20K — same 27 MHz-class
pixel clock family, ~0.1% off spec (27.000 vs. 27.027 MHz), smaller than several
already-accepted deviations elsewhere in this project, and gets the refresh rate right.

GW2AR-18C's real 2-PLL ceiling (both already spent by `nano20k_pll.vhd`) meant no new
PLL instance was possible or needed — real, hardware-informed HDMI clocks already
existed in that unchanged file, just never loaded by any NECTang bring-up before this.

One real SDC bug found and fixed before the first successful build: `clk_135` and
`clk_sdram` are the *same physical net* (`nano20k_pll.vhd`'s `clk_sdram <= clk_135_i`).
Declaring both as separately-named generated clocks work fine individually (as
NECTang's own `nano20k_clocks.sdc` does — but that file never loads `clk_sdram`, so the
name collision never surfaces there). Loading both at once here, Gowin's synthesis
merges the two same-value nets under one surviving name (`clk_sdram`) — real gw_sh
measured `ERROR (TA2003): Can't set timing constraint to object clk_135`. Fixed by
deriving `clk_27` from `clk_sdram` instead, no separate `clk_135` declaration at all.

Real result, `impl/pnr/pcetang_nano20k.fs`:

```
Logic     7953/20736  (39%)
Register  3195/15915  (21%)
CLS       5068/10368  (49%)
BSRAM     37/46       (81%)   -- SPX9 1, SDPB 17, DPB 6, DPX9B 4, pROMX9 9
Setup violations: 0    Hold violations: 0
```

**All three boards now have real, clean (0/0 violations) Phase 1 results** — this
closes the "Phase 1 to 3" scope of the standing goal (ROM load, joypad, OSD via
`iosys_bl616`, ported and measured on Console 60K, Primer 25K, and Nano 20K). Not
started: Phase 2 (CD/CHD, the FDD-sector-interface approach documented above) — a
substantially larger, separate undertaking (BL616 firmware protocol extension, real
CHD sector serving) not begun this session. Also not verified anywhere: real hardware,
the `textdisp`/OSD path (swept away as dead logic in synthesis on every board so far —
plausible given nothing drives real UART traffic in these builds, but not confirmed
correct rather than actually broken), and joypad button mapping.

## Phase 2 (CD via CHD) — real architecture finding: SCSI-command interpretation is HPS/firmware work, not RTL

Before touching RTL, read `TurboGrafx16.sv` (upstream `tg16-mister`'s real MiSTer
top-level, the only real consumer of `pce_top.vhd`'s `CD_COMM`/`CD_STAT`/`CD_DOUT`
ports anywhere in either donor tree). Finding: there is no RTL-side SCSI target
anywhere in this donor. `CD_COMM` (96-bit SCSI CDB) and `CD_DOUT`/`CD_STAT` get
shipped wholesale to MiSTer's ARM HPS over the `HPS_EXT` co-processor bus
(`cd_in`/`cd_out` registers, `TurboGrafx16.sv:411-438`) — a Linux-side driver
interprets the SCSI commands (TEST UNIT READY, READ TOC, READ(10), etc.) against a
real disc image and answers back. None of that interpretation logic is FPGA-side.

For pcetang this means: the real Phase 2 SCSI-command interpreter has to be written
as new BL616 firmware (`rtissera/firmware-bl616`), consuming `CD_COMM`/answering
`CD_STAT`/`CD_DOUT`/streaming `CD_DATA`, backed by `libchdr`'s already-vendored
`chd_fatfs.c`. That's real, substantial, from-scratch software work — no existing
open-source reference implements this for BL616 — and it cannot be exercised or
measured by `gw_sh` at all (`gw_sh` only proves the FPGA side synthesizes and closes
timing, not that SCSI commands get answered correctly). Not started this session;
correctly out of `gw_sh`'s reach regardless of effort spent here.

**What `gw_sh` *can* answer for Phase 2: does CD fit on top of Console 60K's Phase 1
TangCore integration at all.** Per NECTang's own `docs/PORTING.md`, CD is already
proven to fit on bare Console 60K (`NO_CD=>0`, 106/118 BSRAM = 90%, no TangCore infra
at all). Phase 1's TangCore/HDMI/OSD layer already pushed that same BSRAM number to
106/118 on its own (no CD) — meaning flipping `NO_CD=>0` on top of Phase 1 asks for
both budgets at once, an open question, not assumed either way.

**Real first attempt (2026-08-26): does not fit.** `pcetang_console60k.vhd`'s
`pce_top` generic flipped to `NO_CD => 0`, `CD_COMM`/`CD_DATA`/`CD_STAT`/etc. left
tied to the same safe stubs NECTang's own bring-ups use (`(others => '0')`/`'0'`/`open`
— this measures fit/timing with CD elaborated, not real CD function). Real `gw_sh`
result:

```
Logic     49711/59904  (83%)   -- was 14% Phase 1-only
CLS       25806/29952  (87%)   -- was 18% Phase 1-only
BSRAM     118/118      (100%)  -- was 90% Phase 1-only, zero headroom left
Routing:  ERROR (PR0004) -- 13106 unrouted nets, after 1h02m in Routing Phase 1
```

Placement succeeded; routing failed outright, not a timing-closure problem — a real,
measured "doesn't fit" result, consistent with landing at exactly 100% BSRAM (zero
placement slack) plus CD's SCSI/ADPCM state machine adding ~35k LUTs of Logic on top
of Phase 1's baseline. Not a guess: BSRAM at 100% with CD elaborated matches
PORTING.md's own measured "CD costs ~21 blocks" delta on Nano 20K almost exactly (Phase
1 baseline 106/118 + CD's real cost saturates the remaining 12).

**Real second attempt (2026-08-26): still doesn't fit, off by exactly one BSRAM
block.** Shrunk `pce2hdmi`'s on-chip capture buffer from 256x224 to 160x144
(`CAP_WIDTH`/`CAP_HEIGHT` generics, the identical fix already used for Primer 25K's
`ERROR (IF0008)` in Phase 1) to free BSRAM headroom, expecting the same net-BSRAM-drop
that fix produced on Primer 25K. It did not: `GowinSynthesis`'s own resource summary
still reports exactly `118/118 (100%)` (not lower — the smaller buffer inferred
differently, not smaller, the same non-monotonic BSRAM-reshuffle behavior already seen
on Nano 20K's backup-RAM addition in NECTang's own history), and the independent
netlist-read step at the start of PnR then counts **119** blocks for the identical
design and fails outright: `ERROR (PA2017): The number(119) of BSRAM in the design
exceeds the resource limit(118)`. Two different counting passes inside the same `gw_sh`
run disagree by one block on the same netlist — a real, measured tool behavior, not
explained by anything guessed here; not investigated further given each attempt costs
roughly an hour of wall-clock synthesis+routing time.

**Stopping the iterate-and-rebuild loop here rather than guessing at a third shrink.**
Two real attempts (default 256x224 capture: BSRAM 118/118 exactly, routing fails with
13106 unrouted nets; 160x144 capture: BSRAM 118-or-119 depending on which pass counts,
fails before routing even starts) show CD sits right at Console 60K's BSRAM ceiling
once Phase 1's TangCore/HDMI/OSD infrastructure is already loaded — not comfortably
over, not comfortably under, closer than a blind further shrink deserves another hour
of compute to discover. The honest, measured Phase 2 FPGA-fit answer for Console 60K
today is **no** at both capture-buffer sizes tried. A real fix would need either a
smaller net BSRAM cut than `pce2hdmi`'s framebuffer provides (e.g. trimming
`textdisp`/`gowin_dpb_menu`'s OSD memory, or `cd_fifos.vhd`'s CDDA/CDSUBC FIFO depths,
both currently swept as dead logic anyway per the `WARN (NL0002)` lines in this same
build's log — meaning even their *nominal* BSRAM cost might be recoverable by removing
the RTL outright rather than relying on the optimizer's sweep) or accepting CD on a
board with more BSRAM headroom than Console 60K's TangCore-integrated Phase 1 leaves.
Not attempted further this session — a real decision point for the user, not something
to keep guessing at silently.

**Why further trimming would be misleading, not just unproductive — checked directly,
not assumed (2026-08-26).** The CDDA_FIFO/CDSUBC_FIFO/PSG sweeps aren't random dead
code — traced to a real, single cause: `pcetang_console60k.vhd`'s `pce_top`
instantiation ties **every** audio output to `open` (`CDDA_SL/SR => open, ADPCM_S =>
open, PSG_SL/SR => open`, line 309 — real audio mixing was never wired in this repo,
same silent-audio gap noted for Phase 1). With no observable sink, the synthesizer
correctly proves PSG, CD's ADPCM/CDDA decode chain, and their FIFOs are dead and
removes them for free. **This means the 118/119-block "doesn't fit" result already
excludes CD's real audio pipeline entirely** — it's the resource cost of CD's
data/SCSI path alone, not a functionally complete CD build. Wiring real audio (which
any actual playable CD build needs eventually, same as Phase 1's video path needed
`pce2hdmi.sv`) would put PSG/CDDA/ADPCM's BSRAM back into the count and make the fit
problem strictly worse, not better. Trimming OSD/FIFO memory elsewhere to force a
"fit" while audio stays dead-code-eliminated would report a real `gw_sh` pass for a
build that isn't the real deliverable — the same category of mistake this project's
own discipline (see Phase 1's "measure, don't deduce" note above) exists to catch.
**Conclusion: Console 60K CD-fit is a real no, not a some-more-guessing-away no**, and
chasing a synthesis pass here without also wiring real audio would misrepresent, not
solve, the problem.

**Primer 25K and Nano 20K: real attempts, both confirm the inference (2026-08-26), user
explicitly asked to try them rather than stop at the Console 60K result.** Both fail
fast (inference-stage, not a multi-hour PnR run) — real `gw_sh`, not guessed:

**Primer 25K** (`pcetang_primer25k.vhd`, `NO_CD` flipped to `0`): `ERROR (IF0008)`, a
memory failed to map to any BSRAM primitive at all and fell back to registers —
294912 DFF needed against the 23280 limit. Root cause understood, not just observed:
Primer 25K's Phase 1 alone is already `56/56 (100%)` BSRAM (zero headroom), and CD's
own real cost is nontrivial (NECTang's own CD-alone-no-infra Primer 25K build needs
54/56 blocks by itself, per NECTang's `docs/PORTING.md`). With no BSRAM primitives left to allocate,
Gowin's inferencer falls back to registers for whichever memory loses the race, and
that DFF count alone blows the budget ~13x over. Same underlying finding as Console 60K
(CD's real memory demand exceeds what's left after Phase 1's TangCore/HDMI/OSD layer),
surfacing through a different failure mode (inference-time fallback vs. post-mapping
routing collapse) because Primer 25K's starting margin was zero, not Console 60K's ~10%.

**Nano 20K** (`pcetang_nano20k.vhd`, `NO_CD` flipped to `0`): `ERROR (RP0001)`, the
same registers-instead-of-BSRAM class of failure — 249280 DFF needed against a 15915
limit, ~15x over. Consistent with Phase 1 already at `37/46 (81%)` while NECTang's own
bare-CD-zero-infra Nano 20K build needs the *entire* `46/46 (100%)` on its own — the
smallest chip in the lineup, predictably the worst margin.

**All three boards now have a real, measured "CD does not fit on top of Phase 1"
result** — two different concrete failure signatures (routing collapse at 100% BSRAM
on Console 60K; registers-fallback inference failure on Primer 25K and Nano 20K), both
traced to the same root cause: CD's own real BSRAM cost (independently confirmed by
NECTang's own zero-TangCore-infra CD builds: Console 60K fits with 90% baseline,
Primer 25K needs 54/56 alone, Nano 20K needs 46/46 alone) has nowhere to go once Phase
1's TangCore/HDMI/OSD integration has already spent 81-100% of each board's BSRAM.
This is not a synthesis-tool quirk or a guessable RTL bug on either board — reverted
all three top-level files back to `NO_CD=>1` so the tracked builds stay the real, clean
Phase 1 references.

**Follow-up experiment (2026-08-26): RGB222 framebuffer, decisive negative, closes this
avenue.** Added a `COLOR_BITS` generic to `pce2hdmi.sv` (default 3, matching PCE's real
HuC6260 output depth) to test whether cutting the capture buffer's per-channel depth
3->2 bits (256x224x9 -> 256x224x6, a real ~9-block nominal BSRAM saving by the same
arithmetic used for the earlier 160x144 attempt) would clear Console 60K's CD fit.
Killed at the synthesis-stage BSRAM check (before the ~1h routing phase) once the
number was known, per the same measure-early discipline used throughout this project.
**Result at the time: still exactly `118/118`, byte-for-byte identical to both the
original 256x224x9 attempt and the 160x144x9 attempt.** Three real attempts spanning a
~3x range in nominal framebuffer bit demand (516096, 207360, 344064 bits) all reported
the identical 118/118 ceiling.

**CORRECTION (2026-08-26, later same day): the conclusion drawn from this was wrong,
caught before acting on it further.** 118 is `GW5AT-60`'s *physical maximum* BSRAM
count. All three framebuffer sizes were tested while total demand was still over
capacity (CD's full 64KB `ADPCM_DRAM` alone, ~28 blocks, was still in the design) — the
report was pinned at the device ceiling, not actually measuring the framebuffer's
marginal cost. A ceiling reading is uninformative about the size of the thing you
changed; it only says total demand exceeded 118, which was already known. The later
ADPCM bisection (below) proves this directly: once total demand dropped under 118 (real
capacity headroom restored), the numbers moved *linearly* with size (4KB ADPCM stub:
108/118; 16KB ADPCM: 115/118 — a +7-block delta for +12KB, consistent with real
18Kbit-block arithmetic). The framebuffer-size lever was never actually tested under
conditions where it could show an effect. Reverted `pcetang_console60k.vhd`'s
`pce2hdmi` instantiation to default `COLOR_BITS` and `NO_CD` back to `1` regardless
(correct regardless of this correction, since neither variant was being kept). See
`docs/OVERHEAD.md` for where this reopened avenue led.

**Bisection (2026-08-26): a real cost driver identified — `ADPCM_DRAM`,
`cd.vhd:655`.** Two framebuffer trim strategies (spatial 160x144, color-depth RGB222)
had reported no change against the 118/118 ceiling — now understood (see correction
above) to mean total demand was still over capacity both times, not that the
framebuffer was cost-free. Bisected further:
`gw_sh` doesn't expose a per-instance BSRAM breakdown, so isolated candidates by
temporarily shrinking one CD memory at a time and rebuilding, checking the
synthesis-stage BSRAM number before committing to a full ~1h routing run. `ADPCM_DRAM`
(`entity work.dpram generic map (17,4)`, 524288 bits — the real PC-Engine/CD-ROM²
ADPCM working RAM, 128Kx4, matching actual hardware capacity, the one CD memory that
survives every sweep since it's the only one with an observable path even with audio
outputs tied to `open`) is it: shrinking it to a 4Kbit stub (`generic map (10,4)`,
non-functional for real ADPCM playback, diagnostic only) dropped Console 60K's CD
build from `118/118` (routing collapse) to a **real, clean pass**: `108/118 (92%)
BSRAM, Logic 15%, CLS 19%, 0/0 violations`. CD's own SCSI/decode logic barely moved
Logic at all (14%->15% over Phase 1) — confirms it was specifically this one memory,
not CD's logic in general.

**This does not hand Phase 2 a free win — it reframes the decision.** Real ADPCM RAM
is genuinely 64KB per actual CD-ROM² hardware; the diagnostic stub breaks real ADPCM
playback (games writing anywhere past a few KB would corrupt/wrap). Restoring the full,
correct 64KB size would very likely reproduce the original failure, since that's
approximately the ~12-block gap this test measured. What's open, honestly, as a real
decision — not yet made, not resolved by more `gw_sh` runs on their own — is whether a
**smaller-than-real, larger-than-stub ADPCM RAM** (e.g. 8-16KB) is an acceptable
tradeoff for a first real CD-capable Console 60K build, especially since no BL616
firmware exists yet to drive real ADPCM playback at all (a separate, unstarted
software project per the "CD via CHD" section above) — meaning a reduced-ADPCM CD
build would not be shipping a regression relative to what's actually usable today, only
relative to a fully faithful future implementation.

**Real Phase 2 success on Console 60K (2026-08-26): `ADPCM_DRAM` at 16KB (half real
spec, `generic map (15,4)`, `cd.vhd:661`), `NO_CD=>0`.** Verified `ADPCM_DRAM` survives
the synthesis sweep (no `NL0002` line names it or `dpram(addr_width=15,data_width=4)`)
before committing to the full ~1h routing run — this is a real, elaborated memory in
the final netlist, not a dead-code artifact like the earlier stub test. Real `gw_sh`
result, `impl/pnr/pcetang_console60k.fs`:

```
Logic     8674/59904  (15%)
Register  3345/60780  (6%)
CLS       5663/29952  (19%)
BSRAM     115/118     (98%)   -- SP 9, SDPB 56, DPB 38, DPX9B 3, pROMX9 9
Setup violations: 0    Hold violations: 0
```

**Honest label for this result: Console 60K, CD/SCSI/ADPCM decode hardware elaborated
and routed, real clean bitstream, with ADPCM working RAM at 16KB instead of the real
64KB CD-ROM² spec — a documented capacity reduction, not full fidelity.** Real games
that write ADPCM data past the first 16KB of the window would wrap/corrupt; this is a
genuine, named limitation, not hidden inside the passing number. CD_COMM/CD_DATA/CD_STAT
(the SCSI-command host interface) are still tied to the same safe stubs as before —
real CD/CHD *function* (not just fit) still needs the BL616 firmware SCSI-target work
scoped earlier in this section, unstarted, and out of `gw_sh`'s reach regardless of
this result.

**This is a real Phase 2 result for at least one board** — the bar this project has
been measuring against throughout. Not attempted on Primer 25K or Nano 20K: both
failed at the synthesis-inference stage before reaching a BSRAM-capacity question at
all (`IF0008`/`RP0001`, register-fallback), and their starting BSRAM margins (Primer
25K 0% free, Nano 20K 19% free before *any* CD memory) are tighter than Console 60K's
±0-2% swing here — a 16KB ADPCM RAM alone is unlikely to be enough on either, and
confirming that would cost two more real `gw_sh` attempts this session did not spend.

## Phase 2 superseded (2026-08-26): full 64KB ADPCM fidelity, via a scandoubler, not a capacity reduction

The 16KB-ADPCM result above was real and shipped, but it was a compromise. Per the
user's explicit direction to research TangCore's actual overhead and pursue a more
correct fix rather than accept the reduction, this session found and built a real
alternative: **`pce2hdmi_sd.sv`**, a line-doubling scandoubler replacing
`pce2hdmi.sv`'s full-frame capture buffer for Console 60K's CD build specifically. Full
research and real measurement trail in `docs/OVERHEAD.md` (TangCore overhead
breakdown, MiSTer/MiSTle-Dev-FPGA-Companion ecosystem comparison, the real
`huc6260.vhd` timing analysis that de-risked PCE's variable dot clock, and the
Console 60K legal-stub A/B that measured the framebuffer's real cost at ~33 blocks,
not the ~28 estimated).

**Real result, `impl/pnr/pcetang_console60k_cd.fs` (rebuilt on this design,
2026-08-26):**

```
Logic     8692/59904  (15%)
Register  3338/60780  (6%)
CLS       5616/29952  (19%)
BSRAM     104/118     (89%)
clk_pixel: 27.000 MHz (exact, no PLL parameter substitution)
clk_5x_pixel: 135.000 MHz (exact)
Setup violations: 0    Hold violations: 0 (zero slack on every clock, not just zero
                                            violations)
```

**`ADPCM_DRAM` is back to its real, full 64KB spec (`generic map (17,4)`,
`cd.vhd:663`)** — this is not a reduced-capacity build. First real `gw_sh` attempt at
the new design succeeded outright: no PLL parameter rejection (the new
`pcetang_console60k_hdmi_pll_480p.vhd` uses `ODIV0_SEL=50`, untested anywhere else in
this repo — it was accepted as given), no port mismatches, no CDC issues surfacing at
synthesis/PnR (a 2-flop synchronizer was included by design for the cross-clock
`wr_line_toggle` signal, per standard practice, not discovered as a bug afterward).

**What changed, concretely:**
- `pce2hdmi_sd.sv` (new file): 2-line ping-pong buffer (~1 BSRAM block) indexed by
  `video_ce` pulses, not a `CAP_WIDTH*CAP_HEIGHT` full-frame array. Per-line real
  sample count is latched and used to drive a Bresenham-style horizontal stretch,
  handling PCE's three real dot-clock modes (and, per the `huc6260.vhd` analysis in
  `docs/OVERHEAD.md`, mid-frame mode switches) without per-mode reconfiguration, since
  real scanline duration is DOTCLOCK-invariant.
- `pcetang_console60k_hdmi_pll_480p.vhd` (new file): a third PLLA instance
  (Console 60K/GW5A has headroom) producing 27.000/135.000 MHz (CEA-861
  `VIDEO_ID_CODE=2`, the same code Nano 20K's Phase 1 already uses) instead of the
  720p pair.
- `pcetang_console60k_cd.sdc` (new file): same `clk`/`clk_pce` as Phase 1's shared sdc,
  new `clk_pixel`/`clk_5x_pixel` ratios matching the new PLL.
- `cd.vhd`'s `ADPCM_DRAM` restored to `(17,4)`.
- `hdmi2/*.sv` and the three tracked Phase 1 board tops: **untouched**, per the
  additive scope this was built under — `VIDEO_ID_CODE=2` already existed in the
  shared `hdmi` core, so no fork of that file was needed (the cheaper of the two paths
  identified during design, confirmed real by this result).

**Impact on nestang/mdtang/other TangCore cores: none.** No shared file was modified.
This is entirely new, additive RTL wired only into `pcetang_console60k_cd.vhd`.

**Not resolved by this result**: real CD/CHD *function* (BL616 firmware SCSI-target
work, scoped earlier in this section, unstarted) and the picture's actual correctness
(no video simulation environment exists in this project — `gw_sh` proves synthesis,
timing, and resource closure, not a correct image on a real screen, same caveat as
`pce2hdmi.sv`'s own first cut carried). Not attempted on Primer 25K or Nano 20K —
Primer 25K's Phase 1 has zero BSRAM headroom before any CD memory at all (a
scandoubler wouldn't create margin that doesn't exist elsewhere), and Nano 20K's CD
failure is a different, inference-eligibility class of problem (`RP0001`,
register-fallback), not a capacity problem this fix addresses.

**Correction (2026-08-26, later same day): the `104/118` figure above was measured with
no sound at all, on any voice, not just CD's own audio.** `pce2hdmi_sd.sv`'s audio
stub (`clk_audio`/`audio_sample_word` never assigned) leaves `PSG_SL`/`PSG_SR` — the
PC Engine's base sound chip output, tied to `open` and swept away exactly like CD's own
`CDDA`/`ADPCM` outputs — meaning the committed number describes a design with *no game
audio whatsoever*, not just no CD audio. This was true of every board top in this
project already (`pcetang_console60k.vhd`'s own header names it: "nothing wires
PSG/CDDA/ADPCM outputs to anything"), but the Phase 2 write-up above stated `104/118`
without repeating that caveat by name, reading more complete than it was.

Wired `PSG_SL`/`PSG_SR`/`CDDA_SL`/`CDDA_SR`/`ADPCM_S` (all `signed(15 downto 0)` from
`pce_top.vhd`, previously `open`) into new real input ports on `pce2hdmi_sd.sv`, summed
into `audio_sample_word` on `clk_audio <= clk_pixel` — an observability test, not a real
mixer: no resampling to 48 kHz, no clipping, and `psg_sl`/etc. cross from the `clk_pce`
domain to `clk_audio` with no synchronizer (the SDC declares `clk_pce`/`clk_pixel` an
asynchronous group, so this doesn't even get a real CDC timing check — `0/0` setup/hold
violations here means the check didn't run on this path, not that it passed one).
Real `gw_sh` result: full place-and-route to bitstream, exit 0 —

```
Logic     11374/59904  (19%)
Register   5430/60780  ( 9%)
CLS        8058/29952  (27%)
BSRAM       110/118    (94%)
```

`psg`, its `VT` dpram, and `audio_clock_regeneration_packet` all drop off the `NL0002`
sweep list (confirmed live now, not inferred) — real base-game audio genuinely costs
`110-104 = 6` BSRAM blocks and ~2700 more LUTs than the silent number. **The design
still closes, but headroom drops from 14 blocks to 8** (`8/118`, ~7%) once sound that
every game needs, CD or not, is counted.

**CD's own audio specifically (`CDDA_FIFO`, `CDSUBC_FIFO`, `ADPCM`'s decode path,
`PRAM`) stays on the `NL0002` sweep list even in this build** — still provably dead,
because `pce_top.vhd` internally gates `CD_SL`/`CD_SR` (which feed `CDDA_SL`/`CDDA_SR`)
to zero whenever `CD_EN => '0'`, which every CD build in this project ties permanently.
Making the port *reachable* didn't make the internal path *reachable*, since the
optimizer can still prove the gate. **This means the `110/118` number still does not
include the cost of an actual CD disc being active at runtime** — only base PSG sound.
Real `CD_EN` activation (whatever firmware would eventually drive, per item 3 above)
would very likely reintroduce all of `CDDA_FIFO`/`CDSUBC_FIFO`/`ADPCM`'s decode cost on
top of this, against only 8 blocks of remaining headroom. **The full picture is:
base sound fits (barely); CD's own audio has not been shown to fit and the margin left
to test it in is thin.**

**Phase 3 (Arcade Card) is separately, structurally blocked — not something this
session's FPGA work can unblock.** Per NECTang's own `docs/PORTING.md` ("Arcade Card
and backup RAM" section): `AC_RAM_A` is 21 bits wanting the *entire* reachable 2MB
SDRAM bank, `CD_RAM_A` is 22 bits against the existing controller's 21-bit ceiling, and
both collide with `vram0_cache`'s existing use of the same bank. Fitting either needs
`sdram32.sv`/`sdram.sv` widened to decode more than bank 0 — explicitly scoped in
NECTang's own docs as its own separate project, not started there, and NECTang is not
even a tracked git repo yet (a separate open dependency flagged earlier in this
document). No amount of correct work in `pcetang` this session changes that; Phase 3
real `gw_sh` results are not obtainable until NECTang's own SDRAM controller widening
lands.

## Correction (2026-08-26, later same day): a real functional bug in `pce2hdmi_sd.sv`, found before hardware

Before attempting Primer 25K, a second pair of eyes on the committed Console 60K CD
result caught a real bug in `pce2hdmi_sd.sv`, line 165:

```systemverilog
wire [LINE_ABITS-1:0] mem_rd_addr = {line_toggle_rd, sx};   // WRONG: 10-bit LHS, 11-bit RHS
```

`LINE_ABITS = $clog2(540) = 10`. The concatenation `{line_toggle_rd, sx}` is 11 bits.
Gowin's synthesizer flagged this at build time (`WARN (EX3791): Expression size 11
truncated to fit in target size 10`) but a warning, not an error, so the prior build
closed clean without anyone reading it. Verilog truncates from the **top**, silently
dropping `line_toggle_rd` — the read side always addressed buffer 0 regardless of which
buffer was being written. The ping-pong mechanism was dead: writes alternated correctly,
reads never followed. The design would have synthesized, met timing, and shown a
scrambled or frozen picture on real hardware.

This does **not** invalidate the measured resource/timing numbers already recorded
above (`dcee091`) — those describe real synthesis and timing closure, which the bug
doesn't affect. It does mean the "not verified on hardware" caveat already carried by
this file was covering a real, live defect, not just an untested-but-correct design.

**Fix**: widen the LHS to `[LINE_ABITS:0]` (11 bits, matching the RHS). Re-ran
`gw_sh build_console60k_cd.tcl` after the fix — real result, unchanged shape:
`Logic 8683/59904 (15%), Register 3339/60780 (6%), CLS 5628/29952 (19%),
BSRAM 104/118 (89%)`, full place-and-route to bitstream, exit 0. No new warnings at
line 165. The picture's actual correctness is still unverified (no video simulation
environment exists in this project, per the caveat above) — but the specific, real,
found-defect is fixed, not just previously-unnoticed.

**Lesson applied going forward**: `grep -i warn` the full synthesis log after every
`gw_sh` run in this file's family, not just the pass/fail exit code — a clean PnR close
does not mean the RTL is correct, only that it's routable and timing-clean.

## Item 1 (Primer 25K scandoubler CD attempt): real negative result, this time with evidence

Built `pcetang_primer25k_cd.vhd` following the exact Console 60K pattern (`pce2hdmi_sd`
+ `pcetang_console60k_hdmi_pll_480p` + matching `.sdc`), `NO_CD => 0`, `EXT_VRAM0 => 1`
(required on this board even in Phase 1). Real `gw_sh` result: synthesis aborted before
place-and-route with a resource error never seen before in this project:

```
ERROR (RP0006): The number(60649(60048 LUTs, 601 ALUs, 0 ROM16s, 0 SSRAMs)) of logic
in the design exceeds the resource limit(23040) of current device
```

Isolation build (`NO_CD => 1`, scandoubler still swapped in, CD excluded from
elaboration entirely — `NO_CD` gates a VHDL `generate` block, not a runtime enable):
clean full PnR close, `Logic 8786/23040 (39%), Register 3846/23280 (17%),
CLS 6134/11520 (54%), BSRAM 44/56 (79%)`. This much is solid: `pce2hdmi_sd` itself is
not the problem on this board.

**A previous version of this section claimed the root cause was "`EXT_VRAM0` prevents
Gowin's dead-code sweep from pruning CD's tied-off logic," based on `grep -c "NL0002"`
returning 0 against the failing build's log. That claim does not hold up and is
retracted.** Checking the *position* of `NL0002` lines in the passing Console 60K CD
log shows they are emitted right after `[90%] Tech-Mapping Phase 4 completed`, in the
same narrow window where the Primer 25K build's `ERROR (RP0006)` fired. The failing
build never reached the point in the pipeline where sweep results get reported — zero
`NL0002` lines is the expected shape of an early abort, not evidence that sweeping
failed to happen. The 60649-LUT count itself may be a pre-sweep figure; there is no
log evidence either way from the failing run alone, since it aborts at exactly the
ambiguous point. The candidate mechanism this section previously proposed (a Gowin
optimizer-thoroughness heuristic tied to netlist size) was never confirmed and should
not be treated as established — flagged by a second-pass review before further work
was built on top of it.

**First follow-up attempt (retargeting Primer 25K's identical build at a bigger virtual
device, `GW5AST-138B`) was invalid and its result was discarded**: `GW5AST-138B` has no
`PLLA` primitive (`ERROR (RP0008)`), and the quick fix — tying `clk_pixel`/`clk_5x_pixel`
straight to `clk` to route around the missing PLL — collapses `pce2hdmi_sd`'s two-clock-
domain CDC synchronizer into a same-clock constant path, handing the optimizer merge
opportunities the real design doesn't have. Any LUT count from that run would describe
a different, invalid design, not the one that matters. Caught before recording a number
from it; both files deleted, nothing from that run is used below.

**Real discriminating test**: instead of substituting Primer 25K's device, built
**Console 60K's own CD variant with `EXT_VRAM0 => 1`** (`pcetang_console60k_cd_extvram0.vhd`
— only the generic flipped, real GW5A device, real PLLA, no rewiring; the
`VRAM0_RAM_A_*` ports `pce_top.vhd`'s `EXT_VRAM0` path needs were already stubbed
`open`/`(others => '0')`/`'0'` in the existing CD variant, so `vram0_cache.vhd` just
needed adding to the file list). Real `gw_sh` result: full place-and-route to bitstream,
exit 0 —

```
Logic     8593/59904  (15%)
Register  3373/60780  ( 6%)
CLS       5671/29952  (19%)
BSRAM     77/118      (66%)
```

— essentially identical Logic to the non-`EXT_VRAM0` CD build (`8683/59904`, `ca02c07`),
with the full, expected `NL0002` sweep list intact (`ARCADE_CARD`, `psg`, `CDSUBC_FIFO`,
`CDDA_FIFO`, and the rest, all still pruned — checked directly in the log, not inferred).
**This settles it: `EXT_VRAM0` does not break dead-code pruning.** The hypothesis this
section originally proposed and then retracted is now affirmatively dead, not just
unconfirmed.

**Conclusion, now backed by evidence rather than a misread log**: the `EXT_VRAM0` test
clears the *mechanism* this section originally (wrongly) blamed — pruning is unaffected
by it, full stop. It does **not** independently establish which side of the sweep
Primer 25K's 60649-LUT count falls on: that number was still read at the same
`[90%] Tech-Mapping Phase 4` checkpoint established earlier to be ambiguous, and no
build has yet gotten a Primer-25K-equivalent netlist past that checkpoint to see a
confirmed post-sweep count. Comparing 60649 directly against Console 60K's post-sweep,
PnR-final 8593 (a ~7x gap) is not an apples-to-apples number and is not being asserted
as one — no DSP/ALU-primitive theory is being proposed to explain a gap that hasn't
been confirmed to exist.

What *is* established: `EXT_VRAM0` is cleared as a cause, and 60649 against a 23040
LUT ceiling is an overflow regardless of which side of the sweep it falls on — even a
generous post-sweep reduction on this design would need to be implausibly large to
close a 2.6x gap. **Item 1 is a real negative result**: Primer 25K cannot fit CD via
the scandoubler swap. No further work planned on this item this session; a clean
follow-up if it's ever revisited would be retargeting the identical Primer 25K build at
`GW5AT-60B` (59904 LUT, same GW5A family, has `PLLA`, no rewiring needed) to get a
confirmed post-sweep number, rather than guessing at what drives the gap. Diagnostic
build files (`pcetang_console60k_cd_extvram0.*`) removed after the finding was
recorded.

## Item 2 (Nano 20K scandoubler CD attempt): clean, unambiguous real negative result

Same swap as items above: `pce2hdmi` -> `pce2hdmi_sd` in `pcetang_nano20k.vhd`, no new
PLL needed (Nano 20K's Phase 1 already runs `clk_27`/`clk_135` — the same 27 MHz-class
pair `pce2hdmi_sd` wants — via its existing `nano20k_pll.vhd`, unchanged), `NO_CD => 0`.
Real `gw_sh` result:

```
ERROR (RP0001) : The number(227965) of DFF in the design exceeds the resource
limit(15915) of current device(GW2AR-LV18QN88C8/I7)
```

This fails during the **inference** stage (`Running inference ... ERROR`), before
`Tech-Mapping` even starts — a materially earlier and more clear-cut failure point than
Primer 25K's, with none of the sweep-timing ambiguity raised above: there is no
"maybe the count is pre-sweep" question when the abort happens two pipeline stages
before sweeping would occur.

**227965 is not directly comparable to the original pre-scandoubler attempt's 249280
DFF** (documented earlier in this file) — both numbers come from runs that aborted
mid-inference, at whatever point the pass happened to be when the checker fired, not
from two completed netlists measured the same way. Reading a ~9% drop as "the
scandoubler is doing something" would be the same mistake just retracted above for
Primer 25K (an aborted-run count treated as a measurement). What's real and comparable
is the ratio to the device limit: Nano 20K needs roughly **14x** its real DFF budget
either way, on both attempts. This is not a margin a video-path change can
close: Nano 20K's Phase 1 alone already runs at 81% BSRAM, and CD's own real memory
footprint (ADPCM_DRAM's 64KB alone, `cd.vhd:655`) needs BSRAM blocks nowhere near
available on GW2AR-18C's 46-block total regardless of what's freed elsewhere,
triggering the same register-fallback-cascade class of failure documented for the
pre-scandoubler attempt. **Real, settled negative result — no further work planned on
this specific approach for Nano 20K.** Diagnostic build files removed after the
finding was recorded.

## Item 3 (real CD/CHD function via BL616 firmware): scoped, not started — blocked on the RTL side, not the toolchain

Checked what this item actually needs before writing any code, rather than assuming
the toolchain doesn't exist:

- **Firmware source is real and present**: `~/pcetang-dev/bl616-fork`, a git fork
  (`rtissera/firmware-bl616`) with real commit history, not a stub.
- **SDK and cross-toolchain are real and present**: Bouffalo SDK (`~/tangcore-work/bouffalo_sdk`)
  and a T-Head RISC-V GCC toolchain (`~/tangcore-work/toolchain_gcc_t-head_linux`).
- **Confirmed buildable, unmodified, end to end**: `make BL_SDK_BASE=<sdk path>
  TANG_BOARD=console60k` from the fork root produces `tangcore_bl616.bin/.xz/.ota` —
  a real, clean build, not a guess. (Build output removed afterward — throwaway
  verification only, no source changes made to the fork.)
- **The disk interface this item would ride on already exists and is generic, not
  CD-specific**: `main.cpp`'s sector read/write path (`f_read`/`f_write` against a
  mounted FatFs image, dispatched via `mgmt_address`/`mgmt_writedata` — the same
  `0xf200`-series addresses `iosys_bl616.v` already implements) is what `pcxt.cpp` and
  the NES core use for floppy/disk images today. This matches the plan already
  recorded in this file's "CD via CHD" section: reuse this interface, don't invent a
  new one. `libchdr` (for CHD hunk decoding) also already has a local fork
  (`~/libchdr/contrib/tangcore-bl616`).

**Real blocker found, and it's on the RTL side, not firmware or toolchain**: every CD
board top in this project ties the RTL interface a SCSI-target handler would need to
talk to — `CD_COMM => open`, `CD_STAT => (others => '0')`, `CD_DATA => (others => '0')`,
`CD_STAT_GET => '0'` (`pcetang_console60k_cd.vhd`, current state) — to nothing. There is
no live RTL-side endpoint for firmware to drive yet. Writing a SCSI-target handler
against a dead interface can't be wired up or tested even at the most basic level.
**Correct sequence: wire `cd.vhd`'s real `CD_COMM`/`CD_STAT`/`CD_DATA` interface to
`iosys_bl616`'s `mgmt_*` path first (an RTL change with a real `gw_sh` result), then
write the firmware-side handler second.** Not attempted this session — the RTL wiring
alone is a nontrivial addition (needs its own real board-top change and resource
re-measurement, and interacts with everything already found about audio/BSRAM margin
above) and firmware correctness has no verification path in this environment regardless
(no real hardware here to test against). Toolchain readiness is no longer a question;
the RTL interface is the next real step, whenever this item is picked back up.

## Goal revised (2026-08-26): fit CD or SGX on Primer 25K with TangCore, undegraded — real root cause found, real fix path identified

The user set a new, narrower goal after reviewing the RP0006 finding above: fit CD or
SGX on Primer 25K *with* TangCore integration, not degraded relative to a bare-engine
build, explicitly authorizing surgery on shared TangCore-side files (`vram0_cache.vhd`,
`sdram.sv`, `pce_top.vhd`) if needed. This section documents what was found chasing
that goal — a real critical bug fix, a corrected root-cause understanding, and a
concrete, evidenced path forward, from both direct `gw_sh`/`GowinSynthesis` work and an
independent Opus research pass.

### Critical correctness bug found and fixed: `vram0_cache.vhd`'s SDRAM command polarity was inverted

While investigating whether Primer 25K's `EXT_VRAM0` SDRAM offload was somehow the
cause of RP0006 (a hypothesis, tested and cleared below), an Opus research pass reading
`vram0_cache.vhd` directly against its two real consumers found a genuine, severe bug,
independent of the RP0006 investigation:

```vhdl
ram_a_rd_n <= not seq_is_write;   -- WRONG, two call sites (SEQ_REQ_LO, SEQ_REQ_HI)
```

Both real SDRAM controllers this module drives agree independently on the opposite
convention — `RAM_A_RD_n`: 0 = read, 1 = write:
- `sdram.sv:166`: `we <= RAM_A_RD_n;` (Primer 25K's controller)
- `sdram32.sv:286`: `we <= a_rd_n_d;` (Nano 20K's controller)

Verified directly against the source (not taken on the research pass's word alone):
`sdram.sv:268/272` dispatch `CMD_WRITE` when `we=1` and `CMD_READ` when `we=0`. With the
inverted polarity, every real write-drain (`seq_is_write='1'`) drove `ram_a_rd_n='0'`,
telling the controller to issue a **read**; every real read-refill drove `ram_a_rd_n='1'`,
telling it to issue a **write**. On real hardware, VRAM0 external memory would never
have worked at all — writes silently no-op, reads silently corrupt memory with
whatever happened to be on the write-data bus. This affects both boards that use
`EXT_VRAM0`: Nano 20K (always) and Primer 25K (whenever `EXT_VRAM0=>1`, which is every
Primer 25K build so far, Phase 1 included).

**Why no `gw_sh` result ever caught this**: this is a logical/functional bug, not a
resource or timing one — `gw_sh` proves synthesis, timing, and resource closure, never
correctness, and this project has repeated that caveat since Phase 1. **Why simulation
didn't catch it either**: NECTang's `sim/tb_vram0_cache.vhd`'s mock SDRAM responder (line 118,
`if ram_a_rd_n = '0' then <write> else <read>`) encodes the *same inverted* polarity as
the bug, so the testbench agreed with the buggy RTL while both disagreed with the real
controllers. GHDL passed for the wrong reason. **Why no runtime signal exists either**:
`pce_top.vhd`'s `gen_vram0_ext` block ties `dbg_deadline_miss => open,
dbg_fifo_overflow => open` on every board — the module's own built-in instrumentation
for exactly this class of problem was never wired to anything observable.

**Fixed**: removed the `not` at both call sites (`ram_a_rd_n <= seq_is_write;`). This is
a pure polarity fix — same signal, same width, no resource change expected. Verified
resource-neutral by rebuilding Nano 20K's tracked Phase 1 (the only board with a
previously-committed `EXT_VRAM0` result): real `gw_sh` result unchanged,
`BSRAM 37/46 (81%)`, full PnR close — matching the pre-fix number exactly, confirming
the fix is functionally corrective without moving any resource count. **Every
previously-reported "clean" Nano 20K result in this project's history should be read as
"resource/timing-clean, VRAM0-broken until this fix"** — a real, retroactive correction
to this document's own prior claims, not just a new finding.

**Follow-up not done**: `sim/tb_vram0_cache.vhd` lives in NECTang (upstream), which has
its own uncommitted foreign changes this project has deliberately left untouched all
session — its mock's matching polarity bug is flagged here for whoever next touches
that repo, not fixed by this session.

### RP0006 root cause, corrected: BSRAM exhaustion cascading into LUT fallback, not a device-specific synthesis pathology

The previous entry in this document (Item 1, `EXT_VRAM0` cleared as a cause) left the
real driver of Primer 25K's `ERROR (RP0006)` (60649 LUTs vs 23040) unresolved, floating
an unconfirmed "GW5A-25A may lack hard ALU/DSP primitives" guess. That guess is now
**retracted, with real evidence against it**:

**The user's own observation broke it open**: NECTang's own bare-engine CD build (no
TangCore at all — no `iosys_bl616`, no `hdmi2` stack, no OSD, upstream `tg16-mister`
RTL directly) has a real, already-existing artifact on disk
(`impl/pnr/primer25k_cd_probe.rpt.txt`): `Logic 8066/23040 (35%), BSRAM 54/56 (97%)`.
Real, clean, nowhere near the LUT ceiling. **Same CD RTL, same GW5A-25A device, no LUT
overflow.** This alone kills the "device lacks primitives" theory — the device handles
this RTL fine; TangCore's own integration layer is the actual delta.

**Bisection, real `gw_sh`/`GowinSynthesis` numbers** (all direct `GowinSynthesis`
invocations bypassing `gw_sh`'s project-TCL layer — see the `ram_rw_check` section
below for why — same `ram_rw_check=0` setting throughout for a fair comparison):

| Build | Logic (combined) | BSRAM |
|---|---|---|
| Bare CD probe (no TangCore) | 8066/23040 (35%) | 54/56 (97%) |
| + `iosys_bl616` real ROM-loading path, no video/HDMI | 21761/23040 (95%) | 56/56 (100%) |
| + full `hdmi2`/`pce2hdmi_sd` video stack, no iosys | 13251/23040 (58%) | 56/56 (100%) |
| Full (iosys + video + CD), OSD stubbed to zero | 46078/23040 (over, RP0006) | n/a (aborted) |
| Full (iosys + video + CD), OSD live | 49449/23040 (over, RP0006) | n/a (aborted) |
| Full (iosys + video + CD), OSD live, default `ram_rw_check` | 60649/23040 (over, RP0006) | n/a (aborted) |

Two things this table establishes directly:

1. **Every sub-configuration independently drives BSRAM to 56/56 or 54/56** — Primer
   25K's 56-block ceiling is already at or one block from full in every piece tested
   separately. `iosys` alone needs 2 more blocks than bare CD; video alone needs the
   same 2, via presumably different real memories. Combined, real total BSRAM demand
   plausibly exceeds 56, and Gowin's inferencer — rather than throwing an explicit
   `IF0008`-style error the way it did for the earlier Nano 20K/Primer 25K CD attempts
   — appears to silently route some of the excess into LUT-based fallback (`SSRAM`/
   distributed-RAM primitives, visible in the RP0006 error's own breakdown: `0 SSRAMs`
   with `ram_rw_check` at its default vs `696 SSRAMs` with it disabled). No explicit
   `IF0008` line appears in this failing build's log before the Tech-Mapping-stage
   `RP0006` error — the fallback here is quieter than the Nano 20K/Primer 25K DFF-
   overflow cases already documented above, but the underlying mechanism (BSRAM
   exhaustion forcing memories into logic) is the same one this project has already
   diagnosed three separate times (this document's own Nano 20K/Primer 25K `IF0008`
   sections above; `vram0_cache.vhd`'s own header, a documented 58735-LUT/0-BSRAM
   failure from an earlier design iteration; and Console 60K's own real,
   already-measured 41000-LUT swing between its BSRAM-saturated full-framebuffer CD
   attempt (`49711` LUT at `118/118` BSRAM) and its non-saturated scandoubler CD build
   (`8674` LUT at `115/118`) — same CD RTL both times, the only structural difference
   being whether BSRAM was pinned at the ceiling).
2. **The combination cost is real and only partly explained by any one piece** —
   summing the isolated marginal costs (bare 8066 + iosys's own +13695 + video's own
   +5185 ≈ 26946) falls far short of the full build's 46078-49449. Stubbing the OSD
   renderer specifically (`overlay`/`overlay_color` tied to zero, isolating it from the
   confound that neither bisection test above exercised the OSD renderer at all) only
   accounts for a real but small ~3.4k-unit slice of that gap (49449 → 46078) — OSD is
   a contributor, not the story.
3. **Confirmed directly, not just by consistency argument**: shrinking the on-chip cart
   ROM buffer from `ROM_ABITS=15` (32KB, 16 real BSRAM blocks) to `ROM_ABITS=11` (2KB,
   ~1 block) in the full build — freeing roughly the same ~16 blocks a real port-B ROM
   offload (below) would free, with nothing else changed — dropped the result from
   `46078` straight through the 23040 ceiling to a clean, real
   `Logic 18230/23040 (80%), BSRAM 56/56 (100%)`, `ADPCM_DRAM` confirmed still live at
   its full 64KB spec (not swept). A single ~16-block memory-capacity change accounts
   for the entire remaining ~28000-unit gap by itself. This is the direct, measured
   confirmation of the BSRAM-exhaustion-cascade mechanism, not an inference from
   consistency with other cases — once combined real demand drops back under the
   56-block ceiling, the LUT-fallback cascade simply stops happening.

**A real, usable lever found along the way**: `-ram_rw_check 0` is a genuine Gowin
`GowinSynthesis` CLI flag (`GowinSynthesis --help`: "Automatic Read/Write Check
Insertion for RAM"), confirmed present in the underlying `libgwsyn.so`/`libFpgaPrj.so`
libraries and in the `.prj` XML schema (an old, undocumented artifact,
`primer25k_cd_probe.prj`, already had `ram_rw_check=0` set — likely why the user's own
memory of that build being clean didn't carry a LUT-overflow caveat). It reduces the
full build's LUT overflow by 18% (60649 → 49449) by favoring `SSRAM` distributed-RAM
inference over raw-LUT-plus-collision-check logic for memories that don't fit in
BSRAM. **Real build-flow limitation**: `gw_sh`'s `set_option` TCL command does not
expose this flag — both `-ram_rw_check` and `-syn_ram_rw_check` are rejected as
"unknown option." Using it for real requires invoking `GowinSynthesis` directly (as
done for all the bisection numbers above) and handing its `.vg` netlist to PnR as a
separate step — NECTang's own `impl/` tree already has `gwsynthesis/`+`pnr/` artifacts
for `primer25k_cd_probe` in exactly this split shape, so the flow has real precedent,
but `build_primer25k_cd.tcl`'s single-script `gw_sh` convention would need restructuring
to use it for a real board build. Not attempted this session — a real but partial
lever (18%, not closing the ~2x overflow alone), lower priority than the BSRAM-offload
path below which addresses the actual bottleneck this table identifies.

### Real fix path found: extend `sdram.sv`'s already-built second port, don't build a new arbiter yet

An Opus research pass (dispatched per the user's request to check MiSTle-Dev/FPGA-
Companion and other real Tang-FPGA ecosystems for a multi-client SDRAM technique)
returned findings that reframe the whole problem, verified independently against the
real source before being trusted:

**NECTang's own SGX-alone and CD-alone builds already fit Primer 25K, without
TangCore** (NECTang's own `docs/PORTING.md:996-1030` — that sibling project's doc, not
a path in this repo — real committed numbers, not this session's work): SGX alone (`LITE=>0, SGX=>'1', EXT_VRAM0=>1, NO_CD=>1`) closes at
`Logic 18859/23040 (82%), CLS 11137/11520 (97%), BSRAM 56/56 (100%)` — though with
`psg` (and `backup_ram`/`test_rom`) swept dead in that build too, so real PSG's +6
BSRAM/+2700 LUT (measured on Console 60K, this document's own Phase 2 section) is not
included, meaning real SGX is worse than this number, not better. CD alone (this
document's own numbers, `8066/23040`) has real headroom.

**`sdram.sv` is already a 2-client controller, and the second port is tied off on
every board.** `sdram.sv:74-77` declares a real, complete `RAM_B_ADDR/RAM_B_REQ/
RAM_B_DO/RAM_B_WAIT` port with a real fixed-priority launch chain (A → B → refresh,
lines 156-186) already implemented — and the file's own header (lines 24-27) already
documents its intended purpose: "Port B carries cartridge ROM (read-only, latency-
tolerant via `pce_top.vhd`'s existing `ROM_RDY -> WAIT_N` path)." That `WAIT_N` path is
real and already exists (`pce_top.vhd:313`, `WAIT_N => ROM_RDY and not CPU_PAUSE_EN`) —
every board simply ties `ROM_RDY => '1'` and `RAM_B_REQ => '0'`, never using it.
**Wiring the cartridge ROM through this already-built port frees 16 BSRAM blocks**
(the on-chip `rom_mem` `dpram(15,8)` measures 16 blocks in Console 60K's own real
synthesis resource report) **and fixes a real, separate correctness gap**: pcetang's
current on-chip ROM buffer is sized `ROM_ABITS=15` (32KB) everywhere, while
`pce_top.vhd` itself decodes HuCard sizes up to 1MB+ — the current builds cannot load
essentially any real game regardless of CD/SGX. Port B's one real limitation: it has no
`RAM_B_DI`/`RAM_B_RD_n` (read-only), fine for ROM, not usable for `ADPCM_DRAM`.

**`ADPCM_DRAM` is a realistic second SDRAM client, with real bandwidth margin
checked.** `cd.vhd:630-652`: `DRAM_CLKEN` fires every 18 CLK cycles (2.381 MHz), worst
case ≤1.79M accesses/s — a 420ns budget per access. `sdram.sv`'s real transaction cost
(`RASCAS_DELAY=3, CAS_LATENCY=3`, 10 cycles at the port's clock) is roughly 250ns —
comfortable margin, and `cd.vhd`'s own existing `DRAM_SLOT_CNT` 4-phase ring already
absorbs variable latency by design (it wasn't built assuming zero-latency BSRAM). This
needs a genuinely new third port (write-capable, unlike port B) added to `sdram.sv`'s
existing fixed-priority chain — real, scoped, additive work, not attempted this
session.

**SGX is a real dead end on Primer 25K, and SDRAM offload targets the wrong resource
for it.** SGX alone is already at `CLS 11137/11520 (97%)` *before* real PSG audio or
any TangCore integration cost is added — this is a Logic-cell-fabric ceiling, not a
BSRAM one, and moving VRAM1 to external SDRAM would need *more* on-chip logic (a second
cache client), not less, making an already-97%-full CLS budget worse. Separately, at
PCE's fastest real dot clock (10.7 MHz) VRAM1 would need bandwidth matching VRAM0's own
already-tight budget on the exact same SDRAM chip — two clients each needing ~100% of
one channel's real throughput, zero margin, before even reaching the CLS ceiling above.
**Not a promising path; not pursued further.**

**Real, checkable multi-client SDRAM precedent exists on this exact device, for later
if CD's single-additional-client extension isn't enough**: `nand2mario/snestang`'s
`src/sdram_cl2_3ch.v` is a genuine 6-client, bank-interleaved arbiter confirmed (via
its own `build.tcl`) targeting `GW5A-LV25MG121NC1/I0` — the same real part — in
production, at 85.9375 MHz. Not needed for the CD path above (a simple 3rd fixed-
priority port suffices there), but real evidence this class of design scales further
on this hardware if a future SGX attempt or additional client is ever revisited.

### Capacity path confirmed; mechanism (how to actually free the blocks) still open

**The capacity thesis is now directly confirmed, not inferred**: freeing ~16 BSRAM
blocks (simulated by shrinking the on-chip ROM buffer, not yet by a real port-B bridge)
takes the full build from a 46078-LUT `RP0006` failure to a clean, real
`Logic 18230/23040 (80%), BSRAM 56/56 (100%)`, `ADPCM_DRAM` confirmed live at full
64KB spec. **CD fits on Primer 25K with full TangCore integration once ~16 BSRAM
blocks move off-chip** — this is now a measured fact, not a plan.

**What's still open is the mechanism, and it's more constrained than it first
looked.** Reading `sdram.sv`'s own address path (`{bank,a} <= RAM_A_ADDR` /
`RAM_B_ADDR`, both only 21 bits wide) shows `bank` is hardwired to `2'b00` for both
existing ports — the controller only ever reaches bank 0 of the physical SDRAM chip,
a 2MB window, regardless of the chip's real total capacity. **This is the same
21-bit/bank-0 ceiling this document's own Phase 3 section already identifies as the
reason Arcade Card is separately, structurally blocked** — arrived at independently
here, not assumed. Offset-partitioning cart ROM into the same bank-0 window (e.g. base
VRAM0 at 0, ROM at some higher offset) is arithmetically possible and was the original
plan, but it means CD's fix and Phase 3's eventual fix would compete for the exact same
scarce 2MB, and a layout chosen now would need undoing if bank-widening work ever
lands. Not decided; flagged as a real design choice, not defaulted into.

**Second open question, checked and resolved positively**: `sdram.sv`'s port B (and its
`RAM_B_WAIT` signal specifically) is real but **untested infrastructure** — the file's
own header calls it a PCE-specific addition absent from the donor ZX Next design, and
no board in this project has ever driven it. Before building a CDC bridge from
`pce_top.vhd`'s `ROM_RD`/`ROM_A`/`ROM_DO`/`ROM_RDY` interface to port B, the real
question was whether the HuC6280 CPU can tolerate the wait-state duration a real SDRAM
round trip would assert on `WAIT_N` — unlike the VDC, which has *no* wait input at all
and is why `vram0_cache.vhd`'s whole cache-based design exists in the first place.
Checked directly in `HUC6280.vhd:88-119`: when `CPU_CS='1'` (cartridge access selected)
and the internal cycle counter reaches its check point, the logic is
`if WAIT_N = '1' then <advance the counter, pulse CPU_CE> end if` — with no `else`
branch. If `WAIT_N='0'`, the counter simply holds at that value and re-checks every
clock, indefinitely, with no timeout and no corruption risk. This is a real,
clean, arbitrary-duration wait-state mechanism, already built into the CPU
specifically for external/cartridge memory access (`pce_top.vhd`'s existing
`WAIT_N => ROM_RDY and not CPU_PAUSE_EN` wiring already routes through it) — the CPU
path has no hidden constraint analogous to the VDC's. **A port-B bridge asserting
`ROM_RDY='0'` for a real SDRAM round trip is architecturally sound from the CPU side.**
This resolves one of the two open questions; the bank-0/Phase-3 address-space
collision above remains the real open design decision.

**Net position (superseded below)**: CD on Primer 25K with TangCore, undegraded —
capacity-confirmed, real, not yet built. One design question resolved (CPU wait-state
tolerance, real and adequate); one real open design question (bank-0/Phase-3 collision)
remains before writing the port-B bridge.

**SGX on Primer 25K with TangCore: a real dead end**, blocked on Logic-cell-fabric
capacity (97% before TangCore or real audio) and SDRAM bandwidth, not BSRAM — no
version of the SDRAM-offload work above is expected to change this conclusion.

### Port-B bridge built (2026-08-26): clean synthesis-stage fit, full PnR in progress

The bank-0/Phase-3 collision was resolved pragmatically rather than left blocking: a
provisional 1MB base offset (`ROM_SDRAM_BASE` in `pcetang_primer25k_cd.vhd`) puts cart/
syscard ROM in the upper half of bank 0's 2MB window, VRAM0 (port A, needs at most 128KB)
in the lower half. This is explicitly documented at its declaration as not meant to
survive Phase 3's eventual bank-widening work — that work supersedes this layout
entirely, so committing to it now costs nothing real later beyond changing one constant.

`sdram.sv` port B, previously read-only and unused by any board, was given a write side
(`RAM_B_WE`/`RAM_B_DI`) — surgery on shared TangCore RTL, authorized by the active goal.
A write always forces a real bus cycle (excluded from the line-cache hit path, since the
cache's `last_data` shadow copy is never updated by a write) and invalidates the cached
line afterward (`last_a[1] <= '1` on completion when `we` was set), since a stale hit
would otherwise hand back pre-write data on the next read. Verified by reading the
existing hit/miss/launch logic directly (`sdram.sv:139-229`), not assumed.

Port B's request line is genuinely different from port A's: A is rising-edge detected
(`~old_a_req & RAM_A_REQ`) and can be held high through a whole wait; B is edge-detected
either direction (`old_b_req ^ RAM_B_REQ`), so it must actually toggle per request. The
bridge (`pcetang_primer25k_cd.vhd`) is a small settle-then-wait FSM, one instance for
reads (pce_top's `ROM_RD`/`ROM_A`/`ROM_DO`/`ROM_RDY`) and one for writes (iosys_bl616's
`rom_do`/`rom_do_valid`), muxed onto the single shared port since load and gameplay never
overlap in time (the core sits in reset for the whole load — checked in
`iosys_bl616.v`, `rom_do_valid` fires once per received UART byte, far slower than the
bridge's few-cycle turnaround, so no backpressure/overrun risk either). Same relaxed-CDC
style already used for port A in this codebase (a request is toggled and then held
address-stable until the response is seen; no formal 2-flop synchronizer, matching the
existing, already-`gw_sh`-proven port-A convention rather than inventing a new one) — a
4-clk_pce settle window (clk_sdram is 120 MHz vs. clk_pce's 42.857 MHz, ~2.8x) gives over
10x margin for `sdram.sv` to either latch a cache hit or start asserting `RAM_B_WAIT`.

This replaces the on-chip `dpram` cart ROM buffer entirely — one of the two BSRAM-heavy
pieces that pushed the combined build to 56/56 BSRAM and cascaded into `RP0006`.

**Direct GowinSynthesis check (resource-fit only, no .sdc/PnR)**: `Logic 13210/23040
(58%), BSRAM 56/56 (100%)`, no `RP0006` — a real, clean fit, down from `60649/23040`
(over) before this change.

### Real `gw_sh` PnR result (2026-08-26): CD fits on Primer 25K with full TangCore integration, timing closes clean

Full `gw_sh build_primer25k_cd.tcl` run to completion (placement, routing, timing
analysis, bitstream generation, power analysis all completed — a real `.fs` bitstream
was produced, 5.8MB). This is the actual PnR result, not the synthesis-only pre-check
above.

- **Resources**: `Logic 14031/23040 (61%)`, `Register 9081/23280 (39%)`,
  `BSRAM 56/56 (100%)`, `CLS 10659/11520 (93%)`.
- **Timing**: `pcetang_primer25k_cd_tr_content.html`'s STA summary —
  **0 Setup Violated Endpoints, 0 Hold Violated Endpoints** out of 28953 endpoints
  analyzed across 49215 paths. Max-frequency summary, constraint vs. actual Fmax:
  `clk_pce` 42.857 MHz constraint / 44.327 MHz actual, `clk_sdram` 120.000 MHz / 139.506
  MHz actual, `clk_pixel` 27.000 MHz / 78.243 MHz actual — every clock closes with real
  margin, not just barely. Total Negative Slack is `0.000` on every analyzed clock.
- This also resolves, with a real number instead of a synthesis-stage artifact, the
  `-6.340` slack the standalone `GowinSynthesis` pre-check reported on the
  `VRAM0/ram_a_addr -> sdram_inst/last_a[0]` clk_pce→clk_sdram path: that check had no
  `.sdc` loaded, so it had no timing exceptions to apply to a path this design's own
  port-A convention already treats as tolerant (see the relaxed-CDC note above). The
  real PnR run, with the project's actual constraints, shows this path closes fine.

**This is the real, gw_sh-confirmed answer for the active goal**: CD fits on Tang
Primer 25K with full TangCore integration (iosys_bl616 ROM load/joypad/OSD, full video
stack, full CD engine including `ADPCM_DRAM` at its real 64KB) — not degraded, not
stripped down to close the build. Not yet hardware-verified (no board test performed),
but the synthesis/PnR/timing closure itself is real and complete, not simulated or
inferred.

**SGX on Primer 25K remains the confirmed dead end** described above — this work was
scoped to CD only, per the capacity/bandwidth ceiling already established for SGX.

**Two things this result does not claim**, so the next reader doesn't over-read it:
- `pcetang_primer25k_cd.vhd` still hardcodes `ROM_SZ => x"008"` (32KB HuCard) at the
  `pce_top` port map — `pce_top.vhd:646`'s address decode picks the cart-ROM mapper by
  this value, not by how much SDRAM space is behind it. "Syscard ROM lives in SDRAM
  now" is a real statement about where the bytes are stored and fetched from; it is not
  a statement that a real syscard (typically 128-256KB) would boot — `ROM_SZ` would need
  to be wired to whatever real size iosys_bl616 loads before that's true. Not fixed here
  (out of scope for the fit/timing question this section answers).
- The CD build uses `pcetang_primer25k.cst` — the same pin file as Phase 1, not a CD-
  specific one — despite this file's own header talking about HDMI/UART pins as if it
  had its own. That's accurate (nand2mario's primer25k pin assignments are board-wide,
  not build-specific), just worth naming so it isn't mistaken for an oversight.

## Real syscard boot (2026-08-27): ROM path fixed, real work; SCSI target stub scoped, not started

Follow-up to the section above, prompted directly by a user request: "make real syscard
boot (for pcecd) on 25k." This split into two pieces of very different size once
investigated — the first is done and real, the second is scoped but deliberately not
started this session.

### Part 1 (done): `ROM_SZ` and a real 3-way SDRAM address map

The `ROM_SZ => x"008"` left over from the port-B bridge work above was still the 32KB
HuCard decode noted as a real caveat in that section — `pce_top.vhd:646`'s address mux
picks the cart-ROM mirror pattern by this value regardless of how much SDRAM sits behind
it, so the CPU could only ever reach a 32KB mirror of whatever was loaded, real syscard
bytes or not. Changed to `ROM_SZ => x"040"` (256K, straight `CPU_A(17:0)` mapping — the
real size of `syscard3.pce`, no mirroring needed since it matches exactly).

This also meant the provisional 1MB-ROM address layout from the section above no longer
made sense — a 256KB ROM doesn't need 1MB, and `pce_top.vhd`'s `CD_RAM_A` window (a
separate 256KB region CD-RAM will eventually need real backing for) was about to be
designed into a corner if ROM kept claiming everything above VRAM0. Re-split bank 0's
2MB window three ways instead of two:
- **VRAM0** at `0x000000`, 64KB — traced to `vram0_cache.vhd`'s own `seq_addr` (a 15-bit
  word address; +1 bit for byte select = 16 address bits = 64KB), not the 128KB guess
  the prior section used. Real PCE VRAM0 is 32K words × 16-bit = 64KB, matching exactly.
- **CD-RAM** at `0x010000`, 256KB — reserved by a named constant
  (`CDRAM_SDRAM_BASE`) but not yet wired to anything; see Part 2 below for why.
- **ROM** at `0x050000`, 256KB — the constant this section's fix actually uses.

Checked, not assumed, before treating the ROM load path as fine at 256KB:
`iosys_bl616.v`'s frame protocol caps a single `0x07 <data>` frame at 2047 bytes
(`RECV_LEN1`'s `rx_data < 8` check), but `rom_do`/`rom_do_valid` in this RTL don't care
about frame boundaries — they just stream bytes for as long as `rom_loading(0)` stays
asserted, across as many frames as the sender chunks it into. The existing HuCard path
already loads ROMs larger than one frame this way, so 256KB across ~128 frames is more
of the same, not a new mechanism. Also checked `ROM_POP`/`CPU_PRAM_SEL_N`
(`pce_top.vhd:686`) — that gates a HuCard-specific "Populous" cart RAM window, unrelated
to CD/syscard; `ROM_POP => '0'` (unchanged) is correct.

**Direct GowinSynthesis check**: `Logic 13180/23040, BSRAM 56/56`, no `RP0006` —
essentially unchanged from the prior section's result, as expected (a decode/address
change, not new resource demand).

**Real `gw_sh` PnR, confirmed**: `Logic 14002/23040 (61%)`, `BSRAM 56/56 (100%)`, **0
Setup Violated Endpoints, 0 Hold Violated Endpoints** across 28935 endpoints / 49200
paths. `clk_pce` 42.857 MHz constraint / 44.923 MHz actual Fmax, `clk_sdram` 120.000 MHz
/ 130.638 MHz actual — both close with real margin, essentially matching the port-B
bridge section's numbers above (the `ROM_SZ`/address-map change is a decode/constant
change, not new logic, so no material resource or timing shift is expected or seen).
**Part 1 is gw_sh-confirmed real: the CPU can now correctly address a full 256KB
syscard through the port-B bridge.** Part 2 (the SCSI target stub below) is what
actually determines whether a real syscard *boots* — Part 1 alone does not claim that.

**Known, not yet addressed**: the read bridge's fixed 4-cycle settle window (see the
port-B bridge section above) runs on *every* `ROM_RD`, and a syscard executes directly
from ROM continuously (unlike a HuCard game that copies to work RAM) rather than fetching
occasionally. Port B's own line cache should still hit on sequential code fetches most of
the time, but this hasn't been measured — it's a real open question for "does it run at
a normal speed," separate from "does it fit and does it boot," which is what this section
and the one above answer.

### Part 2 (done, see subsections below): syscard boot needed a real SCSI target stub, not just a bigger ROM

Tracing what happens after the CPU can actually fetch the full syscard found a second,
larger gap (at the time of writing, `CD_EN => '0'` and `CD_RAM_A/CD_RAM_DO/CD_RAM_RD/
CD_RAM_WR` were all still `open` — since resolved, see the subsection below):
`CD_STAT`/`CD_MSG`/`CD_STAT_GET`/`CD_COMM`/`CD_DOUT_*` are still stubbed constants — the
same gap this document's Item 3 already named ("CD_COMM/CD_STAT stubbed everywhere,"
scoped as BL616-firmware work, not started). Real syscard BIOS code issues
SCSI commands (at minimum TEST UNIT READY, then REQUEST SENSE once that reports not-ready)
essentially immediately during boot, per how every real PCE-CD/TurboGrafx-CD unit behaves
with no disc inserted — it doesn't hang, it shows a "please insert a CD-ROM" screen. That
behavior requires *something* to answer those SCSI commands; right now nothing does.

**Traced the real protocol directly from `SCSI.vhd` and `cd.vhd`, not inferred from the
SCSI spec**: `SCSI.vhd` implements a complete, self-paced SCSI bus phase timing model in
RTL (`SP_FREE` → `SP_COMM_*` → `SP_STAT_*` → `SP_MSGIN_*` → back to `SP_FREE`, all gated
by real microsecond-scale internal counters, e.g. a ~1.05ms `STAT_COUNT` delay before the
STATUS phase — the code comments this was tuned against a real game, "Sailor Moon," that
hung without it). The board-level `CD_STAT`/`CD_MSG`/`CD_STAT_GET`/`CD_COMM`/`CD_COMM_SEND`
boundary is the real seam: `CD_COMM_SEND` pulses once the CPU has assembled a full SCSI
command; `CD_STAT_GET` is a board-driven pulse telling `SCSI.vhd` "the response is ready,
transition to STATUS phase now," reading whatever is currently on `CD_STAT`/`CD_MSG` at
that moment. This part is genuinely simple to stub — the bus doesn't strictly need real
firmware, just a board-side responder driving `CD_STAT`/`CD_MSG` and pulsing
`CD_STAT_GET`.

**What makes it real work, not a quick constant tie**: REQUEST SENSE's response isn't a
status byte, it's data — real sense bytes (sense key `0x02` NOT READY, ASC `0x3A` MEDIUM
NOT PRESENT, for the honest "no disc" case) delivered through `cd.vhd`'s own DATA-IN
phase, which reads from an internal FIFO (`CDDA_FIFO`, `cd.vhd:739`) fed by the board's
`CD_DATA`/`CD_DATA_WR` ports 4 bytes at a time (`cd.vhd:713-731`) — currently tied to
`(others => '0')`/`'0'`, so that FIFO is permanently empty and the DATA-IN phase never
triggers. A responder that only answers TEST UNIT READY would leave a syscard that
politely asks "why not ready?" via REQUEST SENSE stuck with no answer — worse than not
implementing REQUEST SENSE at all, since the syscard would reasonably expect *a* response
to a command it's allowed to issue.

**Also unresolved, and deliberately not guessed at**: whether the *current* stubbed state
(nothing ever pulses `CD_STAT_GET`) hangs the CPU outright, or whether the syscard's own
BIOS polling has a timeout and falls through to some degraded state. `SCSI.vhd:187-212`
shows the bus simply parks in `SP_FREE` forever if `STAT_PEND` never sets — that's
inertness, not a corruption risk, but whether *the CPU* hangs depends on syscard's own
polling loop, which lives in BIOS code this project doesn't control or have source for.
Not yet determined empirically (no build with `CD_EN => '1'` and everything else still
stubbed has been tried, which would answer this directly and cheaply before writing any
responder logic at all).

**Recommended next step, not yet done**: before writing a SCSI target stub against an
inferred command set, either (a) find the MiSTer TG16 core's own HPS-side CD handler —
same donor lineage, same `CD_STAT`/`CD_COMM` boundary, and a known-working reference for
the real minimum command set and real sense byte values, rather than reconstructing them
from the SCSI-3 spec; or (b) instrument `CD_COMM`'s first byte to somewhere observable
(OSD, UART) and read back what a real syscard boot actually sends, in what order, turning
the question into a measurement instead of an inference — this project's standing
discipline elsewhere in this document. Ordering matters: `CD_EN => '1'` and CD-RAM real
backing come before a SCSI stub is even reachable, so the sequence is ROM path (done) →

#### CD-RAM real backing + `CD_EN => '1'`: done, `gw_sh`-confirmed (2026-08-27)

The blocking prerequisite named above is now real. `CD_EN => '1'`, and `CD_RAM_A/DO/DI/
RD/WR` bridged through a genuine new third SDRAM client (`sdram.sv`'s port C) instead of
the on-chip dpram the donor assumes — CD-RAM's decode window is 256KB (`cd.vhd`'s own
`RAM_SEL`: `EXT_A(20:13)` in `[0x68,0x87]`, 32 × 8KB = 256KB, confirmed from source, not
assumed from real-hardware CD-ROM² spec knowledge). Unlike ROM, this couldn't reuse a
static mux: CD-RAM has no wait-state path in the donor (`CD_RAM_DI` muxes into the CPU
read path combinationally) and genuinely overlaps VRAM0/ROM traffic in time (accessed
live during gameplay, not once at load). Two real pieces of surgery this needed:

- `pce_top.vhd`: a new `CD_RAM_RDY` input (default `'1'`, existing callers unaffected),
  ANDed into `WAIT_N` alongside `ROM_RDY` — the same CPU-stall mechanism ROM already has.
- `sdram.sv`: a real arbitrated third client (priority `A > B > C > refresh`), mirroring
  port A's read+write/line-cache convention rather than port B's toggle/write-invalidates
  one. **Flagged, not measured**: a third continuously-active client increases (doesn't
  newly introduce) refresh-starvation risk — the same class of bug `sdram32.sv`'s own
  history already documents being found and fixed once, with only two clients.

**Real `gw_sh` PnR, confirmed**: `Logic 14183/23040 (62%)`, `BSRAM 56/56 (100%)`, **0
Setup Violated Endpoints, 0 Hold Violated Endpoints** across 29259 endpoints / 49722
paths. `clk_pce` 42.857 MHz constraint / 43.914 MHz actual — comfortable margin. `clk_sdram`
120.000 MHz constraint / **120.964 MHz actual — real but thin (0.8%)**, worth naming
plainly rather than glossing over: the arbiter's critical-path logic level jumped from 4
to 11 with the third client added, and this margin has less room to absorb a future
fourth client or a faster `clk_sdram` retune than the two-client design had. Timing
closes today; it's a real result, not a comfortable one.

As with the ROM path, this only proves the CPU can now correctly reach CD-RAM without
corrupting it or stalling forever — it says nothing about whether syscard *boots*. That's
entirely gated on the SCSI target stub below, still not started.

#### On hosting SCSI: checked the MiSTer donor's actual split, chose differently, on purpose

Investigated per a direct user request. Checked against the real MiSTer donor source
(`TurboGrafx16.sv`, `sys/hps_io.sv`, `rtl/hps_ext.v`) -- NOT vendored into this repo at
`upstream/tg16-mister/` as an earlier version of this note implied; `TurboGrafx16.sv`
and `hps_io.sv` exist only in NECTang's own `upstream/tg16-mister/` checkout (read
there for this investigation, not copied here), and `hps_ext.v` IS vendored here, but
at `src/pce/tg16-mister-rtl/hps_ext.v`, not the `upstream/tg16-mister/rtl/` path named
above. This confirms MiSTer's real split: `cd.vhd`/
`SCSI.vhd` (identical to this project's, unmodified) own only the bus phase timing; ALL
SCSI command semantics (decode, sense codes, CHD/BIN-CUE file reads) run as C code on the
HPS side (a full Linux ARM SoC), exchanged over a generic register bus (`hps_ext.v`'s
`CD_GET`/`CD_SET`, 112 bits each way, polled continuously). That C-side handler lives in
MiSTer's separate `Main_MiSTer` firmware repo, not vendored here — not available locally
to copy sense-byte values or command-decode logic from.

**Chose not to mirror that split.** BL616 is not HPS — no Linux, far less RAM, and this
project's own prior research (`## CD via CHD` section above, written before this Part 2
work) had already independently converged on a different, more BL616-appropriate
architecture: keep SCSI command decode *in RTL* (the target-stub responder this section
is about), and use BL616 only as a sector-data server over the interface that already
exists and works — `iosys_bl616.v`'s `mgmt_*`/`fdd_request` LBA protocol, extended for
2048-byte CD sectors — backed by `rtissera/libchdr`'s `contrib/tangcore-bl616/
chd_fatfs.c`, which **already compiles and links against the real BL616 toolchain**
(`LOWRAM_TARGET=1`, measured +142.5KB flash out of a 4MB budget — a checked fact, not a
guess). This means BL616 needs file I/O + a CHD codec (bounded, already proven size), not
a from-scratch SCSI interpreter — a smaller, more tractable ask than replicating MiSTer's
HPS role would have been.

Real, still open from that investigation: `chd_open()`/`chd_read()` have never actually
run on real BL616 hardware (only link-probed against a nonexistent path), and no one has
built the FPGA-side bridge from `mgmt_*`/`fdd_request` into `cd.vhd`'s DATA-IN FIFO —
green-field, same as the SCSI stub itself. Firmware work is explicitly out of scope for
this session (per the sequencing below); this section exists so the next session doesn't
re-litigate the HPS-vs-BL616 question from scratch.

#### Minimal SCSI target stub: built, spec-verified, `gw_sh`-confirmed (2026-08-27)

Wired a small responder to `CD_STAT`/`CD_MSG`/`CD_STAT_GET`/`CD_COMM`/`CD_COMM_SEND`/
`CD_DATA`/`CD_DATA_WR`/`CD_DATA_END` (all previously stubbed constants) —
`cd.vhd`/`SCSI.vhd`'s own bus phase timing is untouched, this only answers commands.
`CD_COMM`'s lowest byte is the opcode (traced from `SCSI.vhd`'s own `COMM_POS`/
concatenation logic). Any command other than REQUEST SENSE (`0x03`) gets CHECK
CONDITION; REQUEST SENSE gets fixed-format sense data pushed one byte at a time through
`CD_DATA`/`CD_DATA_WR` into `SCSI.vhd`'s own byte-wide DATA-IN FIFO (not `cd.vhd`'s
separate 4-byte-packed `CDDA_FIFO`, which is audio-only and irrelevant here), followed
by a GOOD status once `CD_DATA_END` confirms the drain.

**Real, measured surprise this uncovered**: making `CD_STAT_GET` a genuine signal
un-swept a large amount of previously dead-code-eliminated logic inside `cd.vhd`/
`SCSI.vhd`. With `CD_STAT_GET` tied `'0'` (every build in this project until now,
including Console 60K's CD build, confirmed identical), `STAT_PEND` was provably always
0, so the whole STATUS/DATA-IN state machine and `SCSI_FIFO`'s real write/read enables
were dead everywhere. The instant it became real, `SCSI_FIFO` (4096×8, matching the
donor's `LPM_NUMWORDS`, 32768 bits) needed real backing with 0 free BSRAM blocks left —
`13313/23040` clean → `24061/23040`, `RP0006`. The same BSRAM-exhaustion-cascades-into-
LUT-fallback mechanism this project already found and fixed twice before (ROM buffer,
then CD-RAM). Fixed by shrinking `cd_fifos.vhd`'s `SCSI_FIFO` from 4096 to 64 entries —
real headroom for this stub's actual use (18 sense bytes at a time), small enough to
synthesize as `RAM16` primitives instead of a scarce BSRAM block. Confirmed safe
project-wide (Console 60K's CD build still sweeps this FIFO away entirely, so nothing
depends on the old depth anywhere) and documented as a scope-driven shrink to revisit
once real CD sector streaming (2048 bytes/sector) needs deeper buffering.

**Checked against real PCE-CD/SCSI specs, per a direct request not to trust generic
SCSI-2 assumptions**: fetched and read Mednafen's `pce_fast/pcecd_drive.cpp` (a real,
hardware-accurate PCE-CD emulator). Two findings:
- **Structure confirmed correct, not a simplification**: Mednafen's own `PCECommandDefs`
  table flags every real PCE-CD command except REQUEST SENSE (TEST UNIT READY, READ(6),
  and the PCE-specific `0xD8`/`0xD9`/`0xDA`/`0xDD`/`0xDE` audio/subcode commands) as
  requiring a disc, and returns the identical NOT_READY response for all of them when
  none is present. This stub's "any command but REQUEST SENSE gets the same response"
  matches that real command set exactly, rather than approximating it.
- **One real bug found and fixed**: every other sense-data byte already matched
  Mednafen's `MakeSense()` exactly (`0x70` current error, sense key `0x02` NOT READY,
  `0x0A` additional sense length, `0x00` ASCQ/FRU) — but the ASC byte was `0x3A`, the
  generic SCSI-2 MEDIUM NOT PRESENT code. Real PCE-CD hardware/firmware uses NEC's own
  `0x0B` ("no disc, tray closed", that source's `NSE_NO_DISC`) instead. Fixed.
- **Named residual gap, not hidden**: a genuinely unrecognized opcode (outside that real
  7-command table) gets `ILLEGAL_REQUEST`/`NSE_INVALID_COMMAND` (`0x20`) on real
  hardware — this stub can't distinguish that case and would answer NOT_READY instead.
  Not fixed, since real syscard boot isn't known to issue anything outside that table
  (Mednafen itself doesn't implement more, including INQUIRY, and is a mature,
  compatibility-tested emulator across many real games/BIOS).

**Real `gw_sh` PnR, confirmed** (after the ASC fix): `Logic 14494/23040 (63%)`,
`BSRAM 56/56 (100%)`, **0 Setup Violated Endpoints, 0 Hold Violated Endpoints** across
30207 endpoints. `clk_pce` 42.857 MHz constraint / 43.388 MHz actual — thin but real
margin. `clk_sdram` 120.000 MHz constraint / **120.364 MHz actual — very thin (0.3%)**,
worth naming plainly: this margin has been trending down across iterations of this same
build (130.6 → 124.4 → 120.4 MHz) as more logic loads the SDRAM arbiter's critical
path, and PnR run-to-run variance alone could plausibly erase it. Timing closes today;
treat it as fragile, not comfortable, and re-check after any further change that adds
logic near the arbiter.

**Status**: ROM path (done, §Part 1) → CD-RAM backing + `CD_EN` (done, above) → minimal
SCSI target stub (done, spec-verified, `gw_sh`-confirmed, above). What remains unknown:
whether this specific command coverage (TEST UNIT READY / REQUEST SENSE / CHECK
CONDITION on everything else) is actually enough for a real syscard BIOS to reach a
visible "insert a CD-ROM" boot screen, as opposed to some other real command sequence
this project hasn't observed. No hardware test and no simulation testbench exist for
this responder — the structural/byte-level correctness is now checked against a real,
independent, hardware-accurate reference, which is the strongest verification available
without hardware, but it is not the same as watching a real syscard actually boot.

## ADPCM RAM offload to SDRAM (2026-08-27): 27 BSRAM blocks freed, both clock margins improved, `gw_sh`-confirmed

Follow-up to the BSRAM-exhaustion discussion this project has hit three times now (ROM
buffer, `CD_STAT_GET`/`SCSI_FIFO`, and the section above). `cd.vhd`'s internal
`ADPCM_DRAM` (`dpram(17,4)`, 128Kx4 = 64KB) was the single largest BSRAM consumer on
Primer 25K — 32 of 56 blocks, 57% of the entire budget — dispatched to a model agent
for independent verification of which BSRAM-freeing lever would actually help given
`clk_sdram`'s thin, trending-down margin (130.6 → 124.4 → 120.964 → 120.364 MHz across
this session's builds). Recommended design, followed here: share SDRAM's existing
port C (already used by CD-RAM's own offload, above) via a bridge-level arbiter in the
`clk_pce`-domain board file, not inside `sdram.sv`'s own arbiter — keeps zero new logic
on `clk_sdram`'s timing-critical `STATE_IDLE` priority chain.

**Real interface, confirmed by reading `cd.vhd` directly before changing anything**:
`ADRAM_A` (single time-multiplexed address bus, muxed WRADDR/RDADDR by `DRAM_SLOT`),
4-bit data in/out, one write enable, timed by `DRAM_CLKEN` (pulses once per 18 CLK
cycles = 420ns) and a 4-slot round-robin (`DRAM_SLOT_CNT`: REFRESH, WRITE, WRITE,
READ) that replicates the real original PCE hardware's DRAM refresh timing, not
anything about this FPGA's SDRAM. Critical fact: `cd.vhd` samples `ADRAM_DO` the SAME
cycle `DRAM_CLKEN` pulses — a hard 1-cycle synchronous-memory latency baked into the
state machine, confirmed by checking every `ADRAM_DO` read site (all three inside one
`DRAM_CLKEN='1' and DRAM_SLOT=SLOT_READ` block, no latched copy read elsewhere).

**Design chosen over speculative prefetch**: `ADPCM_RDADDR` is not purely sequential
(seeks/resets happen on control writes), so a predictive prefetch risks serving stale
data on an address jump — silent audio corruption, hard to catch without hardware.
Instead, extended `cd.vhd`'s own `DRAM_CLKEN` generator with a real wait-gate: holds
`DRAM_CLK_CNT` at 17 (does not pulse `DRAM_CLKEN`) whenever the current slot has a real
pending access (new `ADPCM_RAM_REQ` output) and a new `ADPCM_RAM_READY` input hasn't
confirmed it's done. Not speculative — the address/pend flags are already computed
combinationally well before the gate is checked, so a bridge has up to ~420ns of lead
time before this gate needs it, comfortably more than one SDRAM round trip (~83ns).
`ADPCM_RAM_READY` defaults to `'1'`, so any board that doesn't connect it keeps the
original never-stall behavior exactly.

New pass-through ports added on `cd.vhd` and `pce_top.vhd` (same pattern as `CD_RAM_*`
above): `ADPCM_RAM_A`(17)/`ADPCM_RAM_DO`(4, write data)/`ADPCM_RAM_WE`/`ADPCM_RAM_REQ`/
`ADPCM_RAM_SLOT_CNT`(2, see bug below)/`ADPCM_RAM_DI`(4, read data, in)/
`ADPCM_RAM_READY`(in). `pcetang_primer25k_cd.vhd`'s existing CD-RAM bridge FSM
(`cdr_state`) was extended into a real two-owner arbiter (`cdr_owner`: NONE/CDRAM/
ADPCM) sharing port C — CD-RAM wins ties (it stalls the CPU directly; ADPCM tolerates
real slack), a request arriving while the other owner is mid-transaction latches into
a `cd_pend`/`adpcm_pend` flag and is served once the FSM returns to idle, with the
matching `..._rdy_i`/`..._ready_i` output dropping in the same state-independent cycle
the request is first seen, not only once the FSM gets around to launching it. One
nibble packed per SDRAM byte at a new `ADPCM_SDRAM_BASE = 0x090000` (128KB region,
avoids read-modify-write, which would double port C's transaction count).

**Real bug found by a second model review before committing, not caught by either
`GowinSynthesis` or `gw_sh`** (both check timing/resources, neither checks protocol
correctness): a byte write to ADPCM RAM spans two consecutive WRITE slots
(`DRAM_SLOT_CNT` "01" then "10") at **two different addresses** — this DRAM is
natively nibble-addressed (`ADPCM_WRADDR` increments on every WRITE-slot `DRAM_CLKEN`
pulse), not one address holding both nibbles of a byte. The decoded slot *type*
(`DRAM_SLOT`) stays `SLOT_WRITE` across both, and the pend flag doesn't clear until
the second nibble, so `ADPCM_RAM_REQ` (a level) never drops between them. The original
bridge edge-detected `ADPCM_RAM_REQ`'s rising edge directly — this fires once, launches
the first nibble's write, and silently drops the second on **every single ADPCM byte
written**. Fixed by exposing `ADPCM_RAM_SLOT_CNT` (the raw 2-bit slot counter, which
changes on every slot boundary regardless of decoded type) and re-basing the bridge's
edge detection on slot-count changes qualified by `ADPCM_RAM_REQ`, instead of on
`ADPCM_RAM_REQ`'s own edge. Read path confirmed unaffected by the same trace: the READ
slot occurs once per 4-slot rotation, so `ADPCM_RAM_REQ`'s rising edge already worked
correctly there, and `ADPCM_RDADDR` only increments after the second read nibble (same
address reused for both, matching the original dpram's behavior exactly).

**Console 60K regression caught and fixed before committing**: `cd.vhd`'s internal
`ADPCM_DRAM` was removed entirely (not made conditional), but Console 60K's CD build
has *real*, audio-wired ADPCM playback (`pcetang_console60k_cd.vhd`'s own header:
`BSRAM 110/118`, `PSG_SL/SR`/`CDDA_SL/SR`/`ADPCM_S` all wired real) — unlike Primer
25K's, which is fully inert (`CD_EN='0'` there too, but the whole SCSI/status path is
stubbed and unverified). Confirmed via the resource-report hierarchy that
`ADPCM_CLK_GEN` is still live logic on Console 60K (not dead code), so the removal
would have silently zeroed out real ADPCM audio there. Fixed with a direct
`dpram(17,4)` shim in `pcetang_console60k_cd.vhd` itself — the exact same memory
`cd.vhd` used to instantiate internally, wired straight through the new ports,
`ADPCM_RAM_READY` tied `'1'` (safe: it's a real on-chip dpram again, reproducing the
original same-cycle-latency assumption exactly). Confirmed via the resource report:
the shim shows 32 BSRAM blocks, restoring Console 60K's original cost/behavior
unchanged. **Lesson generalized**: `cd.vhd` is shared across every CD-capable board —
a change to its internal *behavior* (not just its port list) must be checked against
every board's real configuration, not just the one being actively worked on.

**Real `gw_sh` PnR, confirmed** (Primer 25K CD, with the slot-count bug fix in):
`Logic 10705/23040 (47%)`, down from `14494/23040 (63%)`. **`BSRAM 29/56 (52%)`, down
from `56/56 (100%)`** — 27 blocks freed, close to the full 32-block `ADPCM_DRAM` cost
(the remaining ~5 likely already-freed by other changes this session). `clk_pce`
42.857 MHz constraint / **43.341 MHz actual** (margin 1.24% → 1.13%, a small dip from
the extra edge-detect logic, still clean). `clk_sdram` 120.000 MHz constraint /
**121.904 MHz actual** (margin 0.3% → 1.6%, improved). **0 Setup Violated Endpoints,
0 Hold Violated Endpoints.** Both margins ended up *better* than the pre-offload
baseline, not just neutral as designed for — plausible reading, not confirmed by
further measurement: removing `ADPCM_DRAM`'s 32-block/64KB footprint relieved real
placement congestion at ~93% CLS utilization, the same congestion independently
identified as ~50% of the critical path's routing delay. This also makes the
previously-identified `sdram.sv` `last_valid[]` fix (predicted ~+4% `clk_sdram`
margin, not yet applied) considerably less urgent now that real headroom exists.

Console 60K's CD build re-confirmed `GowinSynthesis`-clean after both the offload and
the shim; full `gw_sh` PnR not re-run there this session (the shim is a bit-identical
replacement of the prior design, so regression risk is low, but end-to-end numbers
are not re-measured). Primer 25K Phase 1 (non-CD) re-confirmed `GowinSynthesis`-clean.
Console 60K Phase 1 and Nano 20K are unaffected (`NO_CD=>1`, `cd.vhd` never
elaborated) and were not re-run.

**Not done**: `sdram.sv`'s `last_valid[]`/refresh-ordering fixes (unstarted, see below
for why this is now the clear next lever). No real hardware or simulation test of
ADPCM playback exists on any board — this result is `gw_sh`-confirmed for
resource/timing closure and protocol-traced against `cd.vhd`'s own source for
correctness, not verified against real audio output.

### Follow-up: `vram0_cache.vhd`'s `tag_mem` landed in BSRAM for free; traced the new `clk_pce` critical path

The model agent's next-biggest predicted win (forcing `tag_mem`, a tiny `dpram(9,4)`
previously stuck in fabric at ~2681 LUTs + 2056 registers, into a real BSRAM block)
turned out to need no RTL change at all: with 27 blocks now free, Gowin's own
inference simply placed it in BSRAM on its own. Confirmed via the resource report —
`tag_mem` now shows 1 BSRAM block. No action needed; this line item is resolved as a
side effect of the ADPCM offload, not a separate task.

Traced the real setup-timing report (`report_timing -setup -max_paths 25`) to see
where the critical path moved:
- **Global worst path (both clocks), slack 0.130ns**: `clk_sdram`,
  `sdram_inst/last_a[0]_6_s0` → `sdram_inst/last_a[2]_19_s0/SET`. This is exactly the
  already-identified `sdram.sv` bug (port C's cache-invalidate write storing all-ones
  on a write, driving the tag comparator straight into a register's synchronous SET
  pin — see the BSRAM-levers discussion above). Now confirmed as the literal worst
  path in the entire design, not just a theoretical concern — the clearest, most
  concrete next lever if `clk_sdram`'s margin ever needs to grow further, though it
  currently closes clean.
- **`clk_pce` worst path, slack 0.261ns**: `core/VDC0/SPR_TILE_X_0_s0` →
  `core/VDC0/SPR_TILE_SPR0_SET_134_s1/CE`, 12 logic levels. This is inside HuC6270
  (`VDC0`)'s own sprite-tile pixel/attribute computation — unrelated to
  `vram0_cache`, SDRAM, or anything touched this session. `tag_mem` no longer appears
  near the top of the setup report at all. Untouched, pre-existing logic; not
  something this session's work created or can take credit/blame for.

VRAM0's own real-time refill deadline (`dbg_deadline_miss`, a runtime counter
separate from static timing closure) is unaffected by any of this session's changes:
sdram.sv's arbitration priority (port A > B > C > refresh) is unchanged, so the new
ADPCM traffic on port C cannot delay a VRAM0 fetch on port A.

### Follow-up: `sdram.sv`'s `last_valid[]` fix, isolated, `gw_sh`-confirmed

Applied as its own scoped change (not bundled with anything else, so its effect could
be measured in isolation): replaced the "stuff `last_a` with all-ones on a miss/write"
sentinel with a real per-channel `last_valid[]` bit, for all three ports (A, B, C) --
same fix `sdram32.sv` (the Nano 20K sibling) already carries, ported here rather than
re-derived. Mechanical change: every `last_a[N] <= <write?> ? '1 : <addr>` site became
a plain `last_a[N] <= <addr>` write plus a matching `last_valid[N] <= ~<write?>`, and
every `fetch_req`/hit-check comparison against `last_a` gained a `last_valid[N]` term.
Port B's existing completion-time invalidate-on-write (a second, separate site from
its launch-time write, pre-existing and unrelated to this fix) became
`last_valid[1] <= 1'b0` instead of restoring the sentinel.

**Real `gw_sh` PnR, confirmed, isolated from the ADPCM offload above**: `clk_sdram`
120.000 MHz constraint / **127.969 MHz actual** (margin 1.6% → 6.6%). `clk_pce`
42.857 MHz constraint / **46.739 MHz actual** (margin 1.13% → 9.06%). `BSRAM 29/56
(52%)` and `Logic 10772/23040 (47%)` both unchanged, as expected (no memory or logic
added, just a register-write shape change). 0 setup/hold violations. Re-checked the
setup-timing report's worst path directly: it is no longer a `.../SET` pin at all --
the global worst path moved to an ordinary `last_a[2]→data` data path, slack risen
from 0.130ns to 0.519ns. The specific pathology this fix targeted is confirmed gone,
not just improved by placement noise.

**Not done**: `sdram32.sv`'s second, larger fix (registering the cache-hit compare,
delaying `addr`/`req`/`rd_n`/`di` by one cycle) -- a bigger, riskier change with a
documented hardware-measured partial-fix failure mode ("252 of 256 bytes wrong" on
real Nano 20K when only one side was delayed), not requested and not applied here.

### Follow-up: refresh-first arbitration reordering in `sdram.sv`, `gw_sh`-confirmed

The other real, previously-fixed-elsewhere bug class this design was still exposed
to: refresh was the LAST `else if` in the `STATE_IDLE` priority chain, so any client
only had to stay busy to starve it indefinitely -- with three continuously-active
clients now (A/B/C), this design's own header had already flagged the risk as real
but unmeasured. `sdram32.sv`'s header documents the identical bug already found and
fixed on the Nano 20K variant of this donor, with a real field symptom (every ROM
loaded and verified, then a grey screen with random bars once real traffic kept the
controller busy enough that `STATE_IDLE` was never reached with every client quiet).
Fixed the same way: moved the `if(&rfsh_cnt)` refresh check to the FRONT of the
`STATE_IDLE` chain, ahead of A/B/C, converting the old trailing `else if` into a dead
branch removed. No change to any client's own launch condition.

**Real `gw_sh` PnR, confirmed**: `clk_sdram` **130.772 MHz actual** (margin 6.6% →
9.0%, logic level 8 → 7). `clk_pce` **45.556 MHz actual** (margin 9.06% → 6.30%, a
real but modest dip -- moving one comparison earlier in a priority chain shifted
placement, as expected; still comfortably passing). `BSRAM 29/56 (52%)` and
`Logic 10770/23040 (47%)` unchanged. **0 setup/hold violations.** Net: a correctness
fix for a real (if unmeasured) starvation bug, not purely a timing-margin play --
worth keeping even though it cost a little of `clk_pce`'s margin, since both clocks
still close with real headroom (6.3%+ on the tighter one) after three consecutive
scoped fixes this session moved both clocks from "thin" (0.3%/1.24%) to healthy.

**Not done**: no hardware or simulation test exists to confirm the starvation bug was
ever actually hit in practice on this design (three clients is new this session, from
the ADPCM offload) -- this fix removes a documented bug class pre-emptively, the same
way `last_valid[]` did, not in response to an observed failure on this specific board.

### Follow-up: real port-A (VRAM0) deadlock found and fixed, `gw_sh`-confirmed -- and the VRAM0 deadline-miss problem this exposes is now known to be worse than previously stated

Dispatched a deeper review of `sdram.sv`'s port A / `vram0_cache.vhd`'s refill
interaction, prompted by a direct question about whether the refresh-first reorder
above (which now lets refresh preempt port A too) made VRAM0's own real-time deadline
worse. The refresh-collision question turned out to be minor -- the review found
something much bigger, **confirmed by real Verilator simulation of `sdram.sv`, not
just static analysis**:

**A real deadlock, pre-existing (not introduced by anything this session did), on
every board using `EXT_VRAM0=1` (Primer 25K, Nano 20K).** Port A's zero-wait
cache-hit optimization -- `if(rfsh_cnt[8] || fetch_req) RAM_A_WAIT <= 1; else
RAM_A_DO <= ...` -- means `RAM_A_WAIT` never rises on a genuine cache hit while
`rfsh_cnt[8]` is clear (the common case, since `rfsh_cnt` resets during init and
takes 256 `clk_sdram` cycles to reach that bit). A 16-bit VRAM0 refill's second byte
is **always** a hit on the tag the first byte's fetch just set (same `[20:2]`
address, differing only in bit 0) -- so the very first refill after reset hits this
path. `vram0_cache.vhd`'s refill sequencer (`SEQ_WAIT_LO_HI`/`SEQ_WAIT_HI_HI`) blocks
unconditionally on `ram_a_wait='1'` while holding `ram_a_req` high, with no other way
to advance. **Permanent hang, no recovery path.** Verified in a real Verilator sim of
the unmodified file driving the exact byte sequence `vram0_cache.vhd` issues: the low
byte's WAIT rose correctly, the high byte's WAIT never rose. `vram0_cache.vhd:20-23`'s
own header already admitted the tightest real-time case "may not always make it" --
this is a different, worse problem than that: not a missed deadline, a total hang.
Ports B and C are unaffected (their board-level bridges in `pcetang_primer25k_cd.vhd`
use a settle-then-check-WAIT pattern that tolerates a no-WAIT hit; only
`vram0_cache.vhd`'s bridge blocks unconditionally). `sdram32.sv` (Nano 20K) has the
identical structure and is exposed to the same bug.

**Fixed**: `sdram.sv` now asserts `RAM_A_WAIT` unconditionally on every port-A REQ
edge, removing the free/no-WAIT hit path entirely. The existing `|| RAM_A_WAIT` term
in the `STATE_IDLE` launch condition then runs the real state machine even on a hit
(with `ram_req=0`, so no actual SDRAM command is issued -- just the handshake round
trip `vram0_cache.vhd` already expects). Deliberately did NOT also strip the
now-partially-redundant `rfsh_cnt[8]` term from the launch condition, despite it
looking vestigial: it still does real work, launching the state machine with
`ram_req=0` on a hit issues `CMD_AUTO_REFRESH` (see the command-generation
`casex` -- `{2'b0X, MODE_NORMAL, STATE_START}`), which is the real "opportunistic
refresh piggybacked on port-A hits" mechanism found separately this session as the
reason the hard `&rfsh_cnt` refresh deadline is rarely actually reached in practice.
Removing it would likely make the refresh-first reorder above fire its hard deadline
branch more often, an unwanted interaction -- left alone, not "cleaned up."

**Real, honest cost**: a hit that was free is now a full ~75ns transaction, so a
16-bit VRAM0 refill goes from 1 real SDRAM transaction to 2. **This makes the
already-real, already-admitted VRAM0 deadline-miss problem measurably worse, not
better** -- deliberate, since a permanent hang is worse than a late or wrong pixel,
and the deadline-miss problem needs a real redesign regardless of this fix (a
separate investigation into that is in flight as of this writing, not yet complete).

**Real `gw_sh` PnR, confirmed**: `clk_sdram` **130.155 MHz actual** (margin 9.0% →
8.46%, logic level 7 → 4 -- the removed `else` branch and comparison simplified the
critical path some). `clk_pce` **44.937 MHz actual** (margin 6.30% → 4.85%, a real
but modest further dip). `BSRAM 29/56 (52%)` and `Logic 10777/23040 (47%)`
unchanged, as expected -- a protocol/handshake fix, no new memory. **0 setup/hold
violations.** Both clocks still close with real, comfortable headroom.

**Not done**: the VRAM0 deadline-miss problem itself (refill latency measured at
~300-375ns against a real 93.3-186.7ns per-dot-clock budget, i.e. 1.6x-3.8x over
budget on every miss even before this fix, worse after it) -- this fix only removes
the hang, it does not make VRAM0 correct under real-time load. No hardware or
simulation test has ever run the full EXT_VRAM0 path end-to-end against real video
timing; nothing here contradicts the possibility that VRAM0 is currently producing
wrong pixels on real hardware whenever a miss occurs, on every board using
`EXT_VRAM0=1`.

## Port-A width fix (2026-08-27): `sdram.sv`/`sdram32.sv` widened 8->16 bits, `gw_sh`-confirmed on all three boards -- biggest lever the VRAM0 deadline investigation found

Follow-up to the VRAM0 deadlock/deadline investigation above (the full prior-art
research this grew out of, including the corrected finding that fpgapce's
`TwoWayCache.v` doesn't apply here and
the real one -- `sdram.sv` port A being only 8 bits wide -- does). A 16-bit VRAM0 word
needed two full sequential REQ/WAIT handshakes (`vram0_cache.vhd`'s old 7-state
`byte_seq`: `SEQ_REQ_LO/SEQ_WAIT_LO_HI/SEQ_WAIT_LO_LO/SEQ_REQ_HI/SEQ_WAIT_HI_HI/
SEQ_WAIT_HI_LO/SEQ_DONE`), ~163 ns of pure protocol overhead per word before any real
SDRAM timing even starts -- independent of, and bigger than, any cache-shape decision.

**Changed**: `RAM_A_DI`/`RAM_A_DO` on both `sdram.sv` (Primer 25K) and `sdram32.sv`
(Nano 20K) widened from 8 to 16 bits. `vram0_cache.vhd` is genuinely shared between
both boards (`EXT_VRAM0=>1` is required on both, not just Nano 20K -- the file's own
header said "Nano 20K only," which was already stale; corrected), so both controllers
had to move in lockstep or Nano 20K's build would stop compiling.

- **`sdram.sv`**: added a `wide_acc` register, set on port A's launch, cleared on B's
  and C's. It overrides the shared `STATE_CONT` DQM-mask expression
  (`SDRAM_A <= {(we & ~a[0]) & ~wide_acc, (we & a[0]) & ~wide_acc, 2'b10, a[9:1]}`) so
  a port-A write enables both SDRAM_DQ byte lanes instead of masking one -- ports B/C
  keep their original byte-select behavior untouched. `data <= RAM_A_DI` (no more
  8-bit replication into both halves); reads drop the `a[0]` byte mux entirely
  (`RAM_A_DO <= data_reg`).
- **`sdram32.sv`**: simpler -- port A there has no write-sharing with port B (port B
  is read-only), so no flag needed. `dqm_w <= a_addr_d[1] ? 4'b0011 : 4'b1100`
  selects which half of the 4-byte SDRAM line to enable; `data <= {2{a_di_d}}`
  replicates the 16-bit value across both halves, DQM picks the right one, mirroring
  the existing single-byte trick. **Also ported this session's `sdram.sv` deadlock
  fix here** (`RAM_A_WAIT` now asserts unconditionally on every port-A REQ edge,
  removing the free-hit path) -- required, not optional: re-derivation showed this
  controller's own cache-line granularity (4-byte-aligned) means two consecutive
  16-bit words alias to the same internal line just as often as two consecutive bytes
  did before, so leaving the old free-hit path in would have made Nano 20K hang on
  every refill's second word, not just the first-after-reset case `sdram.sv` had.
- **`vram0_cache.vhd`**: `byte_seq` collapsed from 7 states to 5
  (`SEQ_IDLE/SEQ_REQ/SEQ_WAIT_RISE/SEQ_WAIT_FALL/SEQ_DONE`) -- one REQ/WAIT round trip
  moves the whole word now. All 3 documented correctness invariants (write-clears-
  other-3-words-on-tag-change, refill-checked-via-dedicated-port-B-read, write-FIFO-
  priority-over-refills) are untouched -- this edit only touches the handshake width,
  not the cache storage/install logic (Bug 2, the tag-never-written-on-refill
  correctness bug, is a separate, still-unfixed issue -- see the investigation memo).
- Port-width plumbing updated at every declaration site: `pce_top.vhd`'s
  `VRAM0_RAM_A_DI`/`_DO`, both `component sdram`/`component sdram32` declarations and
  `vram0_ram_a_di`/`_do` signals in `pcetang_primer25k.vhd`, `pcetang_primer25k_cd.vhd`,
  `pcetang_nano20k.vhd`. Console 60K's `pcetang_console60k*.vhd` needed no change --
  its `VRAM0_RAM_A_DI => open, VRAM0_RAM_A_DO => (others => '0')` wiring is
  width-agnostic (`EXT_VRAM0=>0` there, on-chip path, unaffected either way).

**Real `gw_sh` PnR, all three affected boards, all clean, 0 setup/hold violations
(`Total Negative Slack` = 0 on every clock, every board):**

| Board | Logic | BSRAM | clk_sdram (constraint -> actual) | clk_pce (constraint -> actual) |
|---|---|---|---|---|
| Primer 25K + CD | 10641/23040 (47%) | 29/56 (52%) | 120.000 -> 134.312 MHz (+11.9%) | 42.857 -> 47.870 MHz (+11.7%) |
| Primer 25K Phase 1 (no CD) | 12402/23040 (54%) | 56/56 (100%) | 120.000 -> 152.167 MHz (+26.8%) | 42.857 -> 42.893 MHz (**+0.08%**) |
| Nano 20K | 8008/20736 (39%) | 37/46 (81%) | 135.000 -> 171.922 MHz (+27.4%) | 43.200 -> 45.680 MHz (+5.7%) |

BSRAM/Logic unchanged from before this fix on all three, as expected (a protocol
width change moves no memory). The CD build's clock margins *improved* versus the
pre-widening numbers above (`clk_sdram` 8.46%->11.9%, `clk_pce` 4.85%->11.7%) --
removing the double-handshake state machine shortened the real critical path, a real
bonus on top of the throughput win, not just a neutral protocol change.

**Real, named risk, not glossed over**: Primer 25K Phase 1 (non-CD) closes `clk_pce`
at only **+0.08% margin** (42.893 MHz actual against a 42.857 MHz requirement, 0.036
MHz of slack) -- passes this specific build with 0 violating endpoints, but is close
enough to zero that a different PnR seed, a small unrelated future change, or a
different toolchain version could tip it into a real violation. This is the
non-CD/Phase-1 build specifically (100% BSRAM, the tightest of the three) -- the CD
build (52% BSRAM) has real headroom. Flagged, not fixed here; worth a real look before
relying on Phase 1 specifically.

## Port-A throughput measurement (2026-08-27): step 2 of the validation plan, real Verilator sim -- widening alone does NOT close the deadline

Step 2 of the two-step plan above: does port A, in its new 16-bit form, sustain the
~93.33ns/word throughput a 4-word back-to-back sprite fetch (SG0-3, `SM="00"`, zero
idle slots) needs? Answered by a real Verilator simulation of `sdram.sv` as it stands
at HEAD, driven by a testbench reproducing `vram0_cache.vhd`'s actual new `byte_seq`
REQ/WAIT protocol exactly (not an idealized/static model). No RTL was touched for
this measurement.

**Correction to this document's own earlier framing, found by the sim, not assumed**:
port A's REQ/WAIT wires cross the `clk_pce`<->`clk_sdram` boundary with NO
synchronizer at all -- `vram0_cache.vhd` is clocked from `clk_pce` (42.857MHz,
23.33ns), `sdram.sv` from `clk_sdram` (120MHz, 8.33ns), directly wired. `byte_seq`
therefore runs at `clk_pce`'s rate, not `clk_sdram`'s -- the launch-to-next-launch
turnaround is dominated by `clk_pce` cycles, not `clk_sdram` ones.

**Verdict: NO.** Real, realistic clean-burst measurement: **186.67ns/word — exactly
2.0x the 93.33ns budget.** This is a **throughput deficit, not a latency deficit**:
per-word REQ-to-data latency is a healthy, on-budget 93.33ns; the problem is ~93.33ns
of dead turnaround between the end of one word's transaction and the launch of the
next, because `byte_seq` cannot re-raise `RAM_A_REQ` until it has fully observed
`RAM_A_WAIT` fall (`SEQ_WAIT_FALL -> SEQ_DONE -> SEQ_IDLE -> SEQ_REQ`, all serial,
all in the `clk_pce` domain) -- **port A cannot be pipelined at all in its current
form.** A directed probe (re-raising `RAM_A_REQ` at every possible cycle offset after
the first transaction) confirms this as a hard protocol property, not a
simulation artifact: re-raising REQ during cycles L+1 through L+9 after a launch
silently LOSES the request (no `ACTIVE` command issued, `RAM_A_WAIT` never rises) --
correct today only because the real `byte_seq` never attempts an early re-raise, but
a hard ceiling on any future attempt to shave this window down further.

**Refresh collision, swept across the whole 4-word burst window**: costs a full
transaction slot at the point of collision (worst case measured: word 4's launch
delayed from t=490.00ns to t=573.33ns, +83.33ns = 10 `clk_sdram` cycles) -- **this
document's own header comment on `sdram.sv`'s refresh-first fix was wrong** ("costs...
one refresh cycle, a handful of clk_sdram cycles, not a whole transaction" --
corrected in `sdram.sv`'s header directly). The refresh branch's `state <=
STATE_START` runs the identical `STATE_START..STATE_LAST` counter as any other
access, full transaction length, no discount. Real rate in the simulated burst: ~1
word in 47 pays this extra 83.33ns -- a real input for any future prefetch-queue
depth sizing, not a rounding error.

**What WOULD close the gap (identified, NOT implemented)**: an idealized port-A
client living entirely inside the `clk_sdram` domain (eliminating the CDC-driven
turnaround entirely) using a smarter handshake shape -- drop `REQ` the instant `WAIT`
rises, re-raise the instant `WAIT`'s fall is observed (not `byte_seq`'s current
fully-serial shape) -- measures **91.67ns/word clean, 93.17ns/word averaged with real
refreshes over 400 words (0.16ns of margin)**. This requires relocating the port-A
CLIENT logic (not just the controller, which is already in `clk_sdram`) across the
domain boundary -- real, nontrivial surgery to how `vram0_cache.vhd`/`huc6270.vhd`'s
interface to port A works, not a parameter tweak. **0.16ns of average margin over a
theoretically zero-idle-slot burst is not real engineering margin** -- this closes
the gap only on paper; a single-cycle PnR/routing variance would erase it. Max single
observed stall in that 400-word run: 166.67ns against the 93.33ns budget (≈0.79 word
of deficit), meaning even this best-case path needs a real prefetch buffer of depth
2-3 words to survive its own worst case, not depth 0.

**Honest branch-point reached, decision NOT made here**: the two-step plan's own
stated fallback now applies -- "if NO: real VDC surgery (buffering, fpgapce-style) or
different memory is genuinely required." Port-A width alone (this session's fix) does
NOT close the VRAM0 deadline gap by itself; it was a necessary, real, gw_sh-confirmed
improvement (see the table above) but not sufficient. A SLOT-driven prefetcher bolted
onto the EXISTING `clk_pce`-domain `byte_seq` handshake, at ANY queue depth, cannot
work -- depth only helps a throughput deficit that is already below the deadline
rate, and 186.67ns/word never is. Closing this for real needs either (a) the
clk_sdram-domain relocation above, accepted as razor-margin, plus a real depth-2/3
buffer, or (b) VDC-side surgery (buffering the fetch path, `fpgapce`-style, as
already ruled less-preferred earlier in this investigation since it costs the
real-time-shifter accuracy this project's donor was chosen for), or (c) a different
memory strategy entirely. Not decided; presented for a real choice, not resolved by
default.

Also still open, untouched by anything in this session: Bug 2 (refill-never-installs
correctness bug) and Bug 3 (miss-detection-one-dot-late), both documented earlier in
this section's history.

## Bug 2 fixed (2026-08-27): refills now actually install on a genuine eviction, real GHDL-verified

Root cause (see the earlier "Bug 2" section above for the original discovery): `tag_mem`
was written only by live CPU writes; `refill_can_install` additionally required the
tag to ALREADY match before allowing an install. A genuine conflict miss -- the ONLY
case a refill exists for in the first place -- by definition never has a matching tag,
so no real eviction could ever install. GHDL-confirmed at the time: a never-CPU-written
word read back wrong 40/40 times, the refill re-issuing forever without ever
succeeding. This was silent data corruption on real hardware, not a timing problem --
the whole point of this cache (BAT/CG/sprite line reuse across consecutive scanlines)
never actually worked for anything except CPU-write-then-immediate-read.

**Fixed**: `refill_can_install`'s tag term changed from an AND to an OR --
`refill_tag_changed` (a genuine eviction) is now always allowed to install; a same-tag
compulsory miss still requires the target word not already valid (unchanged, protects
a live write racing in mid-refill from being clobbered by stale fetched data -- the
original, still-real reason for that term). `tag_addr_a`/`tag_data_a`/`tag_wren_a` now
mux between the live-write path and a new refill-install path (mirroring the existing
`way_addr_a`/`way_data_a` mux exactly) -- tag_mem gets a real writer for refills for the
first time. On a genuine eviction, `way_wren_a` also now touches all 4 ways at that
index, not just the target one: the target way gets the fetched word + valid=1, the
other 3 get invalidated -- mirroring invariant 1's existing "clear other 3 on tag
change" behavior for live writes, now applied to refills too. Without this second
half of the fix, a later read of one of those other words would falsely HIT against
the PREVIOUS line's stale data -- a new, different, and arguably worse bug than the
one being fixed (silent wrong data instead of an infinite miss).

**Real GHDL verification** (dispatched agent, fresh testbench -- this file's own header
had referenced `sim/tb_vram0_cache.vhd` as prior art; confirmed via `git log --all`
that file never existed in this repo, corrected as stale): 4 positive tests (genuine
conflict eviction installs and stays installed over 24+ re-reads; the other 3 ways at
that index correctly invalidate, not stale-hit; the same-tag compulsory-miss path
(pre-fix's one working case) regresses clean, siblings untouched; a live write racing
in mid-refill still wins, confirmed by 0 installs committing that dot) plus 3 negative
controls, each reverting one piece of the fix and reproducing the corresponding
failure signature exactly (full revert reproduces the original 40/40-wrong signature
verbatim; removing the other-3-ways invalidation alone reproduces stale hits on the
siblings; removing the valid-bit guard alone reproduces the race-clobber). Swept
across 6 dwell lengths (24-96 cycles), all pass, `dbg_fifo_overflow`/`dbg_deadline_miss`
clear throughout.

**Real, disclosed, PRE-EXISTING race found by the same verification, NOT introduced by
this fix, NOT fixed here**: sweeping the live-write-vs-refill race's timing offset
found exactly one bad cycle (out of the whole refill window) where an install commits
one cycle before the write's effect would have blocked it, clobbering the live write
with stale fetched data. Confirmed present in the PRE-FIX baseline too, at the
identical offset -- not a regression this fix introduced, just newly *reachable* on
the eviction path specifically (pre-fix, that path never installed at all, so nothing
there could clobber anything -- non-functionality accidentally looked like protection).
Real mechanism: `not wren_a` covers only the exact SEQ_DONE cycle, `not
way_q_b(seq_way)(16)` only covers offsets port B has already observed by then -- one
cycle in between is covered by neither. Verification agent's own assessment: the
window is plausibly 2 cycles on real Gowin BSRAM, not the 1 GHDL's `bram_gowin.vhd`
behavioral model shows (port-order in a shared-variable model happens to resolve one
way in simulation; Gowin's real WRITE_MODE guarantee is documented as covering the
writing port's own read-back, not a same-cycle read from the opposite port -- the same
caveat `bram_gowin.vhd`'s own header already flags elsewhere, e.g. `SPR_LINE_BUF`).
Reachability needs a CPU-write dot landing adjacent to a read-miss dot with the SDRAM
round trip's completion landing on that exact boundary -- plausible under real SDRAM
latency variance (refresh collision, bank state) but not a wide window. Flagged for a
future fix, not blocking; tracked here so it isn't rediscovered from scratch.

**Not exercised by this verification**: the header's "case 5" scenario (a write to an
UNRELATED address contending for port A on the same cycle as an install) -- the
existing `not wren_a` deferral is architecturally unconditional (any `wren_a`, not just
a same-address one) so this should already be covered by construction, but wasn't
independently re-confirmed this session.

**Real `gw_sh` PnR, all three affected boards, all still 0 setup/hold violations:**

| Board | Logic (before -> after) | BSRAM | clk_sdram (before -> after) | clk_pce (before -> after) |
|---|---|---|---|---|
| Primer 25K + CD | 10641 -> 10677 (+36) | 29/56 (52%, unchanged) | 134.312 -> 139.701 MHz (+11.9% -> +16.4%) | 47.870 -> 46.814 MHz (+11.7% -> +9.24%) |
| Primer 25K Phase 1 (no CD) | 12402 -> 12581 (+179) | 56/56 (100%, unchanged) | 152.167 -> 154.589 MHz (+26.8% -> +28.8%) | 42.893 -> 43.027 MHz (**+0.08% -> +0.40%**) |
| Nano 20K | 8008 -> 8032 (+24) | 37/46 (81%, unchanged) | 171.922 -> 161.321 MHz (+27.4% -> +19.5%) | 45.680 -> 43.880 MHz (+5.7% -> +1.57%) |

BSRAM unchanged everywhere, as expected (the fix adds a handful of LUTs for the
tag/way mux extension, no new memory). Primer 25K Phase 1's previously-flagged
razor-thin `clk_pce` margin actually improved slightly (+0.08% -> +0.40%, real PnR
seed variance, still razor-thin -- the earlier flagged risk stands, not resolved).
Nano 20K's `clk_pce` margin dropped from +5.7% to +1.57% -- still passes with 0
violations but is now noticeably tighter than before this fix; worth a real look
before relying on more margin there in the future, same spirit as Phase 1's flag.

**Net effect on the deadline-miss problem**: this fix does NOT change the throughput
numbers measured in the section above (186.67ns/word, 2x over budget) -- that
measurement was against `sdram.sv`'s protocol directly, independent of whether
`vram0_cache.vhd`'s cache actually caches correctly. What it DOES change is how OFTEN
that expensive path needs to fire at all: with reuse now actually working, most
scanlines within a 4-scanline BAT/CG group (or however many a sprite's pattern spans)
should hit for free instead of re-missing every single scanline. This does not close
the worst-case burst (all-cold sprites on one scanline still needs the real fix
discussed above), but it should substantially reduce how often real gameplay even
approaches that worst case -- not measured/quantified this session, a real next step
if a game-content-driven measurement is ever wanted.

## Bug 3 diagnosed for real (2026-08-27): confirmed exactly as originally claimed, no cheap fix exists, one separate real bug found and fixed instead

User asked to fix Bug 3 next (miss detection allegedly "one dot late"). A static
re-read of the current RTL (post Bug 1/2/width fixes) produced a DIFFERENT, more
benign timing picture than the original claim -- disagreeing with a real, previously
GHDL-verified finding is exactly the situation this project's own standing practice
says to re-verify via simulation, not resolve by more reading. Dispatched a
diagnosis-only agent (not authorized to edit the file) to settle it with a fresh GHDL
sim before writing any fix.

**Verdict: the original claim was exactly right; the static re-read's error was a
wrong assumption about `dck_ce`/`address_a` phase.** Confirmed by reading
`huc6270.vhd` directly: `DOT_CNT` is registered (advances the cycle AFTER `DCK_CE`),
`SLOT`/`RAM_A` are combinational from `DOT_CNT`, and `RAM_WE <= DCK_CE`. Net effect:
`address_a` becomes the NEW dot's target the cycle AFTER `dck_ce` pulses, not the same
cycle. `req_valid_d` (`dck_ce` delayed by exactly one register stage) therefore always
checks `hit` against `req_addr_d` while it still holds the ENDING dot's address, not
the new one -- structurally, at every dot, regardless of SDRAM speed. Real GHDL
measurement: miss-check lands 93.3ns (exactly one whole dot) after the dot that needed
the data already ended -- reproducing the original claim's number exactly, dwell-sweep
confirmed at DWELL = 4/6/8/9/12/16/20 (every case fails identically).

**Real severity, measured for the first time**: even a 12-line working set with ZERO
cache conflicts (the single best case this cache can ever see -- every miss is a
first-touch compulsory miss, no eviction, no thrashing) returns **wrong data on
17-34% of read dots** over 16 passes. `dbg_deadline_miss` fires at a comparable rate.
Neither is wired to anything observable on any board (`open` in `pce_top.vhd`'s
`gen_vram0_ext`) -- this would be silently, routinely wrong on real hardware today.
This number is independent of, and does not overlap with, the earlier "cache never
installs" Bug 2 -- Bug 2 was about whether a miss ever resolves at all; Bug 3 is about
whether the FIRST access after any miss (resolved or not) ever arrives in time.

**No cheap fix exists -- tried the obvious one, it makes things worse.** The
"obvious" fix (delay the check one more register stage so it aligns with the correct,
new dot) does land the CHECK on time -- but `huc6270.vhd`'s `RAM_WE` only pulses on a
dwell's LAST cycle, so a check running earlier in the dwell cannot yet distinguish a
read dot from a write dot. Real GHDL measurement: this alone is a NET REGRESSION in 5
of 6 realistic dwell/refresh configurations (e.g. dwell=4/wait=3: 53 wrong dots at
HEAD vs 76 with the "fix"; read_reqs 30 vs 42) -- spurious refill launches on
what turn out to be write dots contend with genuine misses for `refill_pending`'s
single-entry queue (force-cleared every `dck_ce`, so more launches do not mean more
completions, just more genuine misses silently dropped). `dbg_deadline_miss` roughly
doubles. Even WITH the phase corrected, the real minimum round trip measured is ~13
cycles (BRAM read, `refill_pending` set, `SEQ_IDLE`->`SEQ_REQ`, REQ on bus, WAIT rise,
WAIT high, WAIT fall, `SEQ_DONE`+install, `way_q_a` updated, `q_a_i` loaded) against 8
cycles even at the most generous real dot clock -- and worse with a refresh collision
(`sdram.sv` checks refresh first, preempting port A). This is THE SAME hard
architectural gap as the port-A throughput problem above, not a separate, smaller
bug -- correcting the phase is a real prerequisite for a future prefetch redesign, but
only as part of that redesign, never as a standalone fix. Not applied.

**Real, separate, genuinely free bug found instead -- FIXED, `gw_sh`-confirmed on all
3 boards**: `q_a_i`'s hold during a refill-install's one-cycle steal of port A was one
cycle too short. `way_k`'s dpram has 1-cycle read latency: the install diverts
`way_addr_a` to `seq_idx` during cycle N (`refill_can_install='1'`), but `way_q_a`
doesn't actually reflect that diverted read until cycle N+1 -- by which point
`refill_can_install` has already dropped back to '0' (a one-cycle pulse), so the OLD
code's `elsif`/`else` branch at N+1 loaded `q_a_i` believing it was a fresh read of
`req_addr_d`, when it was still the stolen cycle's `seq_idx` read -- **another cache
line's data reaching the VDC**, confirmed via GHDL at the exact predicted +1 offset
across multiple dwell/refresh-collision configurations. Fixed with one new
register (`install_d`, a 1-cycle-delayed copy of `refill_can_install`) extending the
hold to 2 cycles. Verified safe: doesn't touch any of the 3 documented invariants,
doesn't suppress the write-forward branch (`refill_can_install` already implies `not
wren_a`), identical behavior to HEAD in 4 of 6 dense-traffic configs and strictly
better in the other 2 (dwell=6/wait=3: 33 vs 37 wrong dots; dwell=6/wait=4: 38 vs 48),
zero cost in read_reqs or deadline_miss anywhere.

**Real `gw_sh` PnR, all three boards, still 0 setup/hold violations, BSRAM unchanged
everywhere:**

| Board | Logic (before -> after) | clk_sdram (before -> after) | clk_pce (before -> after) |
|---|---|---|---|
| Primer 25K + CD | 10677 -> 10711 (+34) | 139.701 -> 128.653 MHz (+16.4% -> +7.2%) | 46.814 -> 48.927 MHz (+9.24% -> +14.2%) |
| Primer 25K Phase 1 (no CD) | 12581 -> 12516 (-65) | 154.589 -> 179.918 MHz (+28.8% -> +49.9%) | 43.027 -> 43.166 MHz (+0.40% -> +0.72%) |
| Nano 20K | 8032 -> 8079 (+47) | 161.321 -> 151.013 MHz (+19.5% -> +11.9%) | 43.880 -> 43.318 MHz (**+1.57% -> +0.27%**) |

**Real, named trend, not glossed over**: Nano 20K's `clk_pce` margin has now eroded
across three consecutive fixes this session -- +5.7% (post-width-fix) -> +1.57%
(post-Bug-2-fix) -> **+0.27%** (post-Bug-3-Fix-B) -- each individually a real, correct,
necessary fix, but the cumulative logic growth is pushing this board's tightest clock
close to the same razor-thin territory Primer 25K Phase 1 has been flagged at since
the width fix. Both are still 0-violation PASSES at this writing, not failures --
but Nano 20K specifically has now crossed from "healthy margin" to "same risk class
as Phase 1." Any further logic growth in this file's `clk_pce`-domain path should
budget for this -- worth a real look (a timing-driven re-run, or accepting the risk
explicitly) before adding anything else here.

**Not implemented, not decided**: the underlying deadline-miss problem itself (the
same one the port-A throughput section above already reached as an open branch
point -- clk_sdram-domain relocation vs. VDC surgery vs. different memory). Bug 3's
diagnosis reinforces that this IS the same problem, not a second one needing its own
separate solution -- there is now one real, well-characterized architectural gap, not
several unrelated small ones.
