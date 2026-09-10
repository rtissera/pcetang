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
| Video on real hardware | **locked, stable** | not tested | not tested |
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

## Rolling picture (Console 60K): FIXED and confirmed stable

Real hardware, 2026-09-10. `pce2hdmi_sd.sv` is a 2-line ping-pong buffer whose read side
shows whichever source line just finished, so it already absorbs phase error line by
line — the roll WAS that slip, i.e. a pure frame-rate mismatch.

The rate is a fixed rational, not a drift. Both PLLs divide the same 50 MHz crystal
(`clk_pce` = 1200/28 MHz, `clk_pixel` = 743.75/10 MHz), and `huc6260.vhd` runs
`LINE_CLOCKS`=2730 with `END_LINE`=263 for this title. Measured three independent ways:

| method | frame_height needed |
| --- | --- |
| closed form | 755.1587 |
| `vs_cy` creep on a free-running 750-line raster | 755.131 |
| `vs_cy` creep on a static 755-line raster | 755.160 |

A constant cannot lock it — the fraction is real, and the pixel clock cannot absorb it
either (exact lock at 755 lines wants 74.35937 MHz; MDIV quantises to eighths and the
nearest value is 74.375, where we already are). So `pce2hdmi_sd.sv` now runs a PI loop on
the phase error with the fractional part sigma-delta dithered into VTOTAL: 755 lines with
~0.16 of frames at 756, plus a phase target so the picture stops rather than freezing
wherever it lands. Slew limited to one line per frame; anti-windup on the integral.

**Confirmed working:** the loop acquires rate AND phase and holds `vs_cy` exactly on
`VT_PHASE_TARGET`. Traced heartbeat, last three samples `vs_cy = 9, 9, 9` with
`vtotal_extra` dithering 5/6.

**Bounded authority was the second half of the fix, and it mattered more than the gains.**
With the clamp at its original [0,12] the loop locked correctly — traced `vs_cy` sat
exactly on `VT_PHASE_TARGET` — but the display went black for ~2 s a few seconds after
boot, then recovered and stayed good. Signal was never lost, so that was the sink
RE-ACQUIRING, not a link drop. The trace says why: during pull-in the loop parks
`vtotal_extra` at its low clamp (heartbeat samples 1..11, `vtotal_extra` = 0) for over a
second, the sink locks to that 750-line timing, and the loop then settles at 755. A
5-line move is a 0.66% frame-rate change — enough for a PC monitor, which is stricter
than a TV, to re-acquire.

The steady-state 755/756 dither runs continuously and never blanks anything, which proves
a 1-line change sits below the sink's re-acquire threshold and only the large excursion
crosses it. So the applied value is clamped to an ABSOLUTE band, `[752,758]` (±3 lines,
0.4%), with the integral's anti-windup clamped to the same band so it cannot charge past
what the output can express. Simulated across every starting phase in 25-line steps:
worst acquisition 213 frames (3.5 s), steady state exactly {5,6}, and a source switching
to huc6260's 262-line branch still re-locks in 74 frames.

Gains were deliberately left alone. Raising Kp speeds acquisition but widens the steady
state to three values, which is the one property worth protecting. Two ideas that
simulation killed before they cost a hardware round trip: a proportional deadband
(destabilises the loop outright) and clamping relative to the integral rather than
absolutely (the integral itself wanders, so it bounds nothing).

**CONFIRMED on real hardware, 2026-09-10:** stable on 1943 Kai, HDMI signal and audio
100% stable, no black period, no roll. Remaining glitches on that title are game/core
rendering issues, unrelated to video timing.

The loop measures rather than assuming, so a title selecting huc6260's 262-line branch
retunes on its own — simulation converges to mean `vtotal_extra` 2.287 for that case,
against 5.160 here. Narrowing the band to ±2 would keep {5,6} but could no longer reach a
262-line source at all; that is the knob if a stricter sink ever needs it.

**Two dead ends, both confirmed on hardware, recorded so nobody retries them:**

* **Raster-reset genlock.** Rewinding hdmi.sv's cx/cy desynchronises every other
  per-frame sequencer (guard/preamble key off `frame_height-1`; the packet picker and
  audio clock regeneration pace off the same raster). In blanking the sink tolerated one
  malformed island per frame (lock/drop cycling); in active video it dropped the link
  outright (no signal).
* **A framebuffer, for this defect.** Not needed. It stays the answer only if a future
  sink refuses the 755/756 dither; headroom is confirmed at 51 free BSRAM blocks.

**Retracted:** an earlier revision of this file called VTOTAL modulation itself dead,
on the evidence that the sink locked and stayed permanently black. What had actually been
tested was a saturating controller bang-banging 750<->760 every frame — the trace shows
it — which is simply unstable timing. A steady 755 was never tried until now, and it
works. The verdict was drawn from one bad control law, not from the approach.

## What "not tested" means here

Primer 25K and Nano 20K carry faithful ports of every Console 60K fix (ROM bridge,
joypad polarity and d-pad bits, DS2 readers, 48 kHz audio strobe). They synthesise and
close timing. **No HuCard has booted on either, and no pad has been plugged into
either.** A clean gw_sh run proves synthesis and timing. It does not prove a picture.
