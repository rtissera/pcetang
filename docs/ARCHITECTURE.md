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
