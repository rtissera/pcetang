# Where this core actually stands

Last updated 2026-09-09. Written to be blunt about what is *verified on hardware*
versus what merely *builds*, because those are very different claims and this file
exists so git history records which is which.

## Headline

**HuCard works on Tang Console 60K.** `1943 Kai (Japan).pce` boots and plays, with
sound and both controllers. That is the only board any real game has ever run on.

**To get there the targets were deliberately degraded to plain HuCard.** CD-ROM²,
the Arcade Card and SuperGrafx are all compiled out or untested. This was a
deliberate trade, not an oversight — see below.

## Per-board matrix

| | Console 60K | Primer 25K | Nano 20K |
|---|---|---|---|
| Builds clean (gw_sh, 0 errors, 0 setup/hold) | yes | yes | yes |
| BSRAM | 67/118 | 35/56 | 39/46 |
| **HuCard runs on real hardware** | **YES** | not tested | not tested |
| Video on real hardware | works, **rolls** | not tested | not tested |
| Audio on real hardware | works (PSG) | not tested | not tested |
| Controllers on real hardware | works (DS2 P1) | not tested | not tested |
| CD-ROM² | **compiled out** (`NO_CD => 1`) | compiled in, **never tested** | compiled in, **never tested** |
| Arcade Card | **compiled out** (`AC_BUILD => 0`) | **compiled out** | **compiled out** |
| SuperGrafx | off (`LITE => 1`) | off (`LITE => 1`) | off (`LITE => 1`) |

Exact generic maps, so this cannot drift from the source:

    Console 60K  LITE => 1, EXT_VRAM0 => 0, NO_CD => 1, AC_BUILD => 0, DBG_PROBES => 1
    Primer 25K   LITE => 1, EXT_VRAM0 => 1, NO_CD => 0, AC_BUILD => 0
    Nano 20K     LITE => 1, EXT_VRAM0 => 1, NO_CD => 0, AC_BUILD => 0

Note the asymmetry, because "we degraded everything to HuCard" is only literally true
of Console 60K: the other two boards still COMPILE the CD subsystem, they have simply
never had it exercised. Only the Arcade Card is out on all three.

## Why each thing was dropped

**Arcade Card — all three boards.** Not free, and measurably so. It hangs off the CPU
physical address bus and loads the MCODE fan-out that also feeds the PSG write path,
which is the MPR critical path `8dc83df` first identified. With it in, Primer 25K had
**428** setup violations and Nano 20K **4** (all four endpoints literally
`core/gen_ac.AC/port[N].base_22`). With `AC_BUILD => 0` both go to **0**. Direct user
decision, 2026-09-09: not a priority until HuCard is right everywhere.

**CD-ROM² — Console 60K.** `HUCARD_ONLY` at `pcetang_console60k_cd.vhd:710`. Dropped
while hunting the black screen, to take the whole CD subsystem out of the timing and
BSRAM picture. The SCSI/TOC/CDDA work is all still in the tree and gw_sh-clean; it has
just never been run against a real disc image on hardware.

**SuperGrafx.** `LITE => 1` everywhere. Fits, but razor-thin (96% BSRAM, ~0.2% clock
margin) — scratch work only, never shipped.

## Known defect: the picture rolls (Console 60K)

Understood, not mysterious. `pce2hdmi_sd.sv` is a 2-line ping-pong buffer whose read
side shows whichever source line just finished, so it already absorbs phase error
line-by-line — the roll IS that slip. Measured 5.5 s period matches +2.28 lines/frame
at 74.375 MHz exactly.

Two dead ends, both confirmed on hardware, recorded so nobody retries them:

* **Raster-reset genlock.** Rewinding hdmi.sv's cx/cy desynchronises every other
  per-frame sequencer (guard/preamble key off `frame_height-1`; the packet picker and
  audio clock regeneration pace off the same raster). In blanking the sink tolerated one
  malformed island per frame (lock/drop cycling); in active video it dropped the link
  outright (no signal).
* **VTOTAL modulation.** Standard-looking and reset-free, but this sink locks and then
  stays **permanently black**. The servo is still in the tree, computing and reporting,
  but gated off (`VT_SERVO_ACTS = 0`).

The real fix is a full framebuffer: standard free-running raster, vertical position set
by read address, roll replaced by a slow-moving tear. Headroom is confirmed — 51 free
BSRAM blocks on Console 60K, and `pce2hdmi.sv`'s full-frame path measured ~19-33.

## What "not tested" means here

Primer 25K and Nano 20K carry faithful ports of every Console 60K fix (ROM bridge,
joypad polarity and d-pad bits, DS2 readers, 48 kHz audio strobe). They synthesise and
close timing. **No HuCard has booted on either, and no pad has been plugged into
either.** A clean gw_sh run proves synthesis and timing. It does not prove a picture.
