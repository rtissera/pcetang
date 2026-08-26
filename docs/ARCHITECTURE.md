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
54/56 blocks by itself, `docs/PORTING.md`). With no BSRAM primitives left to allocate,
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
