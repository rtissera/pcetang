# Where this core actually stands

Last updated 2026-09-18. Written to be blunt about what is *verified on hardware*
versus what merely *builds*, because those are very different claims and this file
exists so git history records which is which.

## Headline

**PC Engine CD games boot and run on Tang Console 60K.** Confirmed on real hardware
2026-09-16 with *Akumajou Dracula X - Chi no Rondo* and *R-Type Complete CD*. This is the
first time any CD game has run on this core.

The single defect that had blocked every CD game was the CD-RAM bridge handing the CPU
byte N-1: `CD_RAM_RD` is a level held across consecutive memory cycles, the arbiter
detected a new access on a rising edge alone, and so the second of two back-to-back
fetches launched nothing while the ready stayed high. Multi-byte code could not execute
from CD-RAM at all. See `MEMORY_BRIDGE_CONTRACT.md` for the contract this violated, why
the donor is immune by construction, and the audit of every other ported memory client.

**CD-DA playback is complete, not just streaming (2026-09-17).** The drive now honours the
audio END position: SAPEP's end LBA and play mode are stored and acted on, so playback loops,
stops, or reports completion the way Mednafen and MAME both do. The completion status is what
raises the game's transfer-done interrupt. Two further real bugs went with it: SAPSP/SAPEP
address decoding (mode is `cdb[9] & 0xC0`; raw LBA comes from cdb[3..5]) and an audio fetch that
went out one sector late on every playback and every loop wrap. Hardware result: **R-Type
Complete CD and Prince of Persia went from black screen to fully playable, Rondo plays through**,
Bonk III unchanged. Tag `pcecd-cdda-endpos-2026-09-17`.

**CD audio (CD-DA) plays at full rate.** Measured 2026-09-17 on Rondo and Bonk III:
74.8 audio sectors/s against the 75/s CD-DA needs (99.8 % of realtime), up from 66 %. Two
fixes: CD-DA samples are byte-swapped (CHD stores them big-endian), and the MCU now sends
sectors by DMA while decoding the next libchdr hunk, with the FPGA prefetching one sector
ahead. See `CD_AUDIO_TIMING.md`.

**ADPCM voices work (2026-09-18).** The earlier "voices missing" entry here is resolved:
DD2 plays its in-game ADPCM samples and Rondo plays through. One known residual: DD2's
title-screen voice is cut short. A separate real bug was found and fixed the same day --
`cd.vhd` cleared the ADPCM DMA run bit once per 2048-byte sector, where both beetle and
MAME keep DMA asserted for the whole transfer and clear it at the STATUS phase. That is
why Sapphire used to reboot; it now reaches "NOW LOADING" and holds.

**HuCard works on Tang Console 60K.** `1943 Kai (Japan).pce` and `Raiden` boot and play,
with sound and both controllers, at 720p60 over HDMI with a correct 4:3 aspect. That is
the only board any real game has ever run on.

**CD-ROM² is playable.** The data path was verified byte-for-byte against an
instrumented beetle-pce-fast back on 2026-09-11 — on four discs every sector the board
serves matches the reference in both LBA and data, and the boot command sequence matches
command-for-command — but games still died with a dark screen until the CD-RAM bridge fix
landed on 2026-09-16. They now boot and play.

**A 1 MB HuCard's top 192 KB used to read as blank (FIXED 2026-09-19).** CD-RAM claimed
banks `$68-$87` with no disc mounted and outranked ROM in the CPU data mux, so ~21 plain
PC Engine titles over 832 KB -- Street Fighter II', Bomberman '94, Parodius, Salamander,
PC Genjin 3 -- plus the 1 MB SuperGrafx cards executed blank memory. Inherited from MiSTer.
See the root-cause section below. **Fixed in simulation and in a clean build; not yet
confirmed on hardware.**

**SuperGrafx runs for the first time (2026-09-18).** With `LITE => 0` the Console 60K
build gains the second VDC and the HuC6202 priority mixer, and the BL616 firmware now
accepts `.sgx` ROMs. Three of four titles boot -- Battle Ace, Aldynes and Daimakaimura --
all with rendering defects (missing sprites, graphic corruption); 1941 Counter Attack
stays black. See the SuperGrafx section below for the six mechanisms already ruled out.

**The Arcade Card is compiled in but its games do not run (2026-09-18).** Sapphire,
Garou Densetsu 2 and World Heroes 2 all stall waiting on the CD unit rather than on
Arcade Card RAM or registers.

## Per-board matrix

| | Console 60K | Primer 25K | Nano 20K |
|---|---|---|---|
| Builds clean (gw_sh, 0 errors, 0 setup/hold) | yes | yes | yes (at a reduced clock, see below) |
| Core clock | 42.857 MHz | 42.857 MHz | **42.4286 MHz** (was 43.2; games run 1.22% slow) |
| BSRAM | 78/118 | 36/56 | 40/46 |
| **HuCard runs on real hardware** | **YES** | not tested | not tested |
| Video on real hardware | **locked, stable, 4:3** | not tested | not tested |
| Audio on real hardware | works (PSG) | not tested | not tested |
| Controllers on real hardware | works (DS2 P1) | not tested | not tested |
| **CD game runs on real hardware** | **YES** — Rondo, R-Type Complete CD, Prince of Persia, Bonk III, DD2 all playable | not tested | not tested |
| CD-DA music on real hardware | **YES, full rate** | not tested | not tested |
| ADPCM voices on real hardware | **YES** (DD2 title voice cut short) | not tested | not tested |
| CD-ROM² | compiled in, **runs games** | compiled in, **never tested** | compiled in, **never tested** |
| Arcade Card | compiled in, **games stall** | compiled out (no room) | compiled out (no room) |
| SuperGrafx | **on — 3 of 4 boot**, 2 still render wrong | off (`LITE => 1`) | off (no room) |
| **HuCard > 832 KB** | **FIXED 2026-09-19** (was: top 192 KB read as FF) | same fix | same fix |

Exact generic maps, so this cannot drift from the source:

    Console 60K  LITE => 0, EXT_VRAM0 => 0, NO_CD => 0, AC_BUILD => 1, DBG_PROBES => 0,
                 CDDA_DEPTH_LOG2 => 12, SGX => '1'
    Primer 25K   LITE => 1, EXT_VRAM0 => 1, NO_CD => 0, AC_BUILD => 0, SGX => '0'
    Nano 20K     LITE => 1, EXT_VRAM0 => 1, NO_CD => 0, AC_BUILD => 0, VT_PATH_A => 0, SGX => '0'

All three boards compile the CD subsystem (Console 60K runs games; the other two have
never had it exercised). Console 60K now also builds SuperGrafx and the Arcade Card;
neither fits on Primer 25K or Nano 20K. SF2' mapper and backup RAM are in on all three.
Console 60K resources with everything on: logic 27153/59904 (46%), BSRAM 110/118 (94%),
0 setup / 0 hold violations, clk_pce 42.887 MHz actual against a 42.857 requirement.

`SGX => '1'` on Console 60K is now correct rather than an inconsistency: this board
builds with `LITE => 0`, so the second VDC, the HuC6202 priority mixer and the VDC/VPC
chip-select decode inside `generate_SGX` all exist. On Primer 25K and Nano 20K, `LITE`
stays 1 and `SGX` stays '0'.

(Historical note, kept because it explains older bitstreams: when those boards ran
`LITE => 1` with `SGX => '1'`, the only surviving effect was `pce_top.vhd`'s work-RAM
address decode -- pages $F9-$FB were separate RAM instead of mirroring $F8. Low risk, but
it is why some earlier builds differed subtly.)

## ROOT CAUSE FOUND: CD-RAM shadowed every HuCard over 832 KB (2026-09-19)

This section previously read "SuperGrafx: what is ruled out" and framed these as
SuperGrafx defects. **That framing was wrong.** The SuperGrafx titles were simply the ones
being tested, and they happen to be 1 MB.

`cd.vhd` decodes physical banks `$68-$87` as Super CD-ROM RAM:

    RAM_SEL  <= '1' when EXT_A(20 downto 13) >= x"68" and <= x"87"
    RAM_CS_N <= not (RAM_SEL and EN)

and `pce_top` instantiated that CD with `EN => '1'`, **unconditionally** -- so CD-RAM
claimed those banks whether or not a disc was mounted, and CD-RAM outranks ROM in the
`CPU_DI` mux. A 1 MB HuCard spans banks `$00-$7F`, so its **top 192 KB was read from
uninitialised CD-RAM instead of the cartridge**.

Measured at the failing instruction, 59 of 59 reads in `$68-$7F`:

    BUS 1378913 RD 0F6000 = FF  rom_a=0F6000 rom_do=4C romseln='0'

address correct, data correct (`4C B1 43` = `JMP $43B1`), ROM selected -- and the CPU still
got `FF`. 1941 then executed `FF` as opcodes, wrote `0x7F` to the VDC address register,
abandoned VDC1 and never uploaded its palette: a black screen.

**Scope: ~21 plain PC Engine HuCards, not just SuperGrafx** -- Street Fighter II' (2560K),
Bomberman '94, Parodius Da!, Salamander, PC Genjin 3, Fire Pro Wrestling 3 and more.
Anything over 832 KB. 512 K cards never reach bank `$68`, which is why they always worked.

**Inherited from the donor.** Upstream TurboGrafx16_MiSTer's `rtl/pce_top.vhd` has the same
`EN => '1'` with the same mux. Real hardware cannot hit it because the two mappings are
mutually exclusive: with a disc running, the "HuCard" is the 256 KB System Card at
`$00-$3F`.

**Fix** (branch `fix/cdram-shadows-hucard`, commit `e3152fd`): one gated signal,
`CD_RAM_CS_N_G <= CD_RAM_CS_N or not CD_EN`, feeding the `CPU_DI` mux, `CD_RAM_RD` and
`CD_RAM_WR`. When `CD_EN='1'` it reduces to `CD_RAM_CS_N` exactly, so a mounted-disc build
cannot regress by construction. Verified: 1941's palette writes go 1 -> 1029 (exactly the
reference), blank-bank reads 59/59 -> 0/66, CD boot regression byte-identical, all 18
`cd_bridge` checks pass, and the build gains margin (+0.105% vs +0.07%) while shrinking by
148 LUTs. **NOT YET TESTED ON HARDWARE.**

### Still open, and NOT explained by the above
- **Battle Ace: missing sprites.** 512 K, never reaches bank `$68`, so the fix changes
  nothing -- its traces before and after are byte-identical. Against an instrumented
  beetle-supergrafx reference it diverges for real at write #135995 (the reference makes
  one more VWR write that we skip) and never realigns at any constant offset. Best next
  target. Caveat: that point is beyond MAME's reach, so it rests on one reference.
- **Aldynes: graphic corruption.** The core is **correct in simulation** -- our trace equals
  the reference plus 18 writes inserted once (a known one-frame startup phase offset), then
  matches for all 18059 remaining writes, 100%. Not reproduced in sim at all; needs hardware.
- **Daimakaimura: untested.**

Six mechanisms were eliminated with measurements before the real cause was found -- VRAM1
on SDRAM, ROM size/mapping/headers, the RTL itself (donor-identical and it simulates
correctly), cross-instance BSRAM merge (VDC0/VDC1 synthesize as twins), the unsupported
cross-port RAM collision (counted: broken game 0, working game 2), and timing (0 setup /
0 hold, worst paths nowhere near the video logic). Kept here because they are all still
true and stop the next person re-walking them.

## Known debt: Nano 20K core clock (2026-09-17)

The CD-DA end-position work added ~307 LUTs, and Nano 20K was already at 90% logic. It went to 183
setup violations; a four-way place/route sweep only reached 42.431 MHz against a 43.2 MHz
constraint. The exact PC Engine rate (42.9545 MHz) is unreachable from that board's 27 MHz crystal
— it needs a phase detector at 1.23 MHz, below the PLL's floor — so the clock was moved to
`27 x 11/7` = 42.4286 MHz, which closes at 0/0 with +0.09% margin.

The cost is real: **games and audio run 1.22% slow on Nano 20K**, and the margin is thin enough
that any future logic addition can break it again. The fix is to pipeline the HuC6280 microcode
decode (`HUC6280_MC.vhd`'s `MI` register) — every failing path on every board starts there, and it
is also what stands between all three boards and the Arcade Card.

## Why each thing was dropped

**Arcade Card — all three boards.** Not free, and measurably so. It hangs off the CPU
physical address bus and loads the MCODE fan-out that also feeds the PSG write path,
which is the MPR critical path `8dc83df` first identified. With it in, Primer 25K had
**428** setup violations and Nano 20K **4** (all four endpoints literally
`core/gen_ac.AC/port[N].base_22`). With `AC_BUILD => 0` both go to **0**. Direct user
decision, 2026-09-09: not a priority until HuCard is right everywhere.

**CD-ROM² — Console 60K. RESTORED.** Was dropped while hunting the black screen
(`HUCARD_ONLY`, now `false`; `NO_CD => 0`). CD games run on hardware since 2026-09-16.

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

## 4:3 aspect ratio (Console 60K): DONE

The picture used to be stretched to the full 1280, i.e. roughly 16:9. The PC Engine is
4:3 whatever dot clock it is in — 256, 341 and 512 wide all map to the same 4:3 screen —
and the Bresenham stretch already handled that correctly by mapping whatever width was
captured into a fixed rectangle. Only the rectangle was wrong.

The height is MEASURED, not assumed, for the same reason the VTOTAL loop measures:
huc6260's `DISP_LINES` is 242 or 231 depending on `RVBL`, so any hardcoded width is 5%
wrong in the other mode. Counting output lines while `video_vbl` is low gives the height
directly and the width follows as `height * 4/3` (21845/16384, rounded — under a tenth of
a pixel of error). 242 source lines occupy 694.9 output lines, so the window comes out
927x695 with ~176px pillars.

Also fixed here: the bars are true black. `rgb <= 24'h101010` was invisible while it only
filled blanking, but those columns are DISPLAYED once pillarboxed and would have shown as
grey pillars. And the bottom ~25 lines used to be the last active source line smeared to
the bottom of the frame — the read side always shows the newest COMPLETED line — so the
vertical extent is now gated on a synchronised `video_vbl`, delayed 3 output lines so the
stale strip at the top goes too.

**Fail-safe, and it is not optional.** If `video_vbl` never toggles the measured height is
0, the width collapses and the vertical gate never opens: a black screen with no way to
reach the OSD, which is how ROMs get loaded. So the window only narrows once a plausible
height (300..780 lines) has been measured, and until then the previous full-width
behaviour stands. `ASPECT_4_3 = 0` reverts entirely.

This changes only WHERE pixels are drawn — the RGB mux, the Bresenham denominator, and a
per-frame window calculation. cx/cy, frame_height, the VTOTAL servo, the packet sequencers
and audio are untouched, so HDMI lock cannot regress from it.

**Confirmed on hardware 2026-09-10:** 4:3 correct, OSD reachable in-game with
SELECT + D-pad RIGHT (`OSD_KEY_CODE`, firmware default `OPTION_OSD_KEY_SELECT_RIGHT`).

## Open items on Console 60K, in priority order

Added 2026-09-18, ahead of the older list below:

0a. **Arcade Card games stall on the CD interrupt path.** Sapphire holds at "NOW LOADING"
    while toggling `$1802` (the CD IRQ mask) with only 16 sector requests and zero ADPCM
    accesses; Garou Densetsu 2 parks in the SCSI COMMAND phase; World Heroes 2 sticks in
    DATA IN with bytes offered and never consumed. None is an Arcade Card RAM or register
    fault. Next: compare `$1802` masking, the transfer-done flag (`cd.vhd` sets `CD_DTD`
    at the status phase) and the ADPCM end/half interrupts against Mednafen's `pcecd.c`.
0b. **SuperGrafx rendering defects** — Battle Ace's missing sprites (a real divergence from the
    reference at write #135995) and Aldynes' corruption (core is correct in sim, so this
    needs hardware). 1941's black screen is FIXED — it was the CD-RAM shadow, not an SGX
    bug. See the root-cause section above.
0c. **HDMI residual tearing ~2.7%** (down from 17.2% via three line buffers) plus a
    low-level shimmer that is inherent: the exact lock needs 755.16 output lines per
    frame, so the servo dithers 755/756. PLL search for an exact ratio was exhausted.

None of the items below block HuCard play. All observed on real hardware 2026-09-10.

1. **Core speed fluctuates** — audible/visible slowdown then speed-up during play. Not
   the video path: the VTOTAL loop tracks the source rather than forcing it, and the
   trace shows source and output frame counts advancing together. Suspect the SDRAM
   arbiter or the ROM bridge's wait path stalling the CPU under load. The heartbeat's VDC
   write counter is the instrument — a real stall shows up as a dip in writes per sample.
2. **Suspected VDC sprite-collision bugs** — wrong behaviour in some titles. Core logic,
   unrelated to video output.
3. **OSD is glitchy in-game** — readable and navigable, but visibly imperfect. Likely the
   overlay path assuming TangCore's standard raster; ours is 1280x720 at a non-standard
   755-line vertical total with a pillarboxed window. Deferred by choice.
4. **Brief roll at title on some titles** (seen on Raiden, then stable). Expected: the
   servo re-acquires when the source changes mode. Worth confirming it is only that.
5. **Uneven scanline thickness.** The read side updates only on even `cy`, so with a true
   ratio of 2.871 each source line occupies 2 or 4 output rows — a 100% variation.
   Dropping that gate gives 2 or 3 rows, much more uniform; `out_line_pair` must stay on
   the /2 cadence or the OSD's vertical scale halves. Deliberately NOT bundled with the
   aspect change, to keep one variable per build.

## What "not tested" means here

Primer 25K and Nano 20K carry faithful ports of every Console 60K fix (ROM bridge,
joypad polarity and d-pad bits, DS2 readers, 48 kHz audio strobe). They synthesise and
close timing. **No HuCard has booted on either, and no pad has been plugged into
either.** A clean gw_sh run proves synthesis and timing. It does not prove a picture.

There is also a practical blocker, found 2026-09-18: **neither board has an SD path in
this design.** `board_sdh_gpio_init()` needs GPIO 10-15, and on Primer 25K the FPGA↔BL616
UART1 link uses 10/11 (Nano 20K uses 11/13) -- the same pins. Storage has to arrive over
USB, and the Console 60K USB-A ports are wired to the FPGA's low-speed soft host rather
than the BL616, so bring-up on those two boards is waiting on a USB-C OTG adapter.


## CD-ROM² — detail (2026-09-11)

### Verified

- System card boots off an emulated drive fed from a CHD over UART.
- Boot SCSI sequence matches beetle-pce-fast command-for-command: TEST UNIT READY, four
  GETDIRINFOs (modes 0/1/2/2), then the READ(6)s.
- Every served sector is byte-identical to the reference in LBA and data, on Dungeon
  Explorer II, Prince of Persia, Bonk III and Double Dragon II.
- CD-RAM: a full 256KB address-derived write/read-back sweep through the real SDRAM
  arbiter passes (256 KiB verified, 0 bad). No corruption, no aliasing.

### Fixed getting here, each with a regression test verified to fail without it

1. **SCSI FIFO show-ahead** — the donor's FIFOs are `LPM_SHOWAHEAD`; this port reads
   through a registered-output block RAM, so `empty` deasserted a cycle before `q` was
   valid. Invisible under the donor's burst fills, hit on *every* byte under our
   byte-at-a-time feed. Wrote `0x01`, CPU read `0xf2`.
2. **Lead-out MSF overflow** — `conv_total` 17 bits where 19 are needed; returned
   `12:00:17` for `70:15:36`.
3. **FIFO depths** restored to donor values (SCSI 2048 -> 4096).
4. **Sector back-pressure** — the bridge paced on MCU arrival, not CPU drain, and the
   FIFO silently discarded the overflow.
5. **Lost-request watchdog** — an unacknowledged request frame could strand the FSM.
6. **MCU: sector serving moved off the UART RX task** — it blocked the only RX consumer
   for tens of ms, truncating request frames so the MCU served valid sectors from the
   *wrong* LBA.

### Open

- **Games do not run.** CPU at full speed, VBlank firing, no bad-bank trap, but VDC
  writes stop. Current suspect: the CD interrupt path (IRQ2 from `CD_DTR`/`CD_DTD`).
- **SCSI bus reset is ignored** — `CD_RESET => open`. Real defect; the obvious
  level-sensitive fix regressed hardware and was reverted ($1804 bit 1 is a latch).
- **UART RX margin is thin** — FIFO high-water 25 of 32 bytes.
- Trace counters are 16-bit and have been misread via wraparound three times. Widen
  before trusting them again.

## CD on real hardware — measured 2026-09-13

The CD data path now delivers sectors **cleanly on real hardware**. This is the first time
that has been true, and it is measured from the board's own counters, not inferred:

| disc | commands | bytes from MCU | underruns | FIFO drops |
|---|---|---|---|---|
| Dungeon Explorer II | 8 | 12288 = exactly 6.00 sectors | 0 | 0 |
| Prince of Persia | 7 | 36864 = exactly 18.00 sectors | 0 | 0 |
| Bonk III | 6 | 0 | 0 | 0 |

Prince of Persia sustaining eighteen consecutive sectors with zero underruns is the
strongest evidence that the two DATA IN fixes in `SCSI.vhd` hold at real UART timing, not
only in simulation.

**No CD game boots yet.** Three different failures remain, and they are not the same bug:

* **Dungeon Explorer II** loads its first 6 sectors correctly and then stops at command 8 --
  it never issues the `de 02 34` that the reference shows next. Black screen. In simulation
  the identical RTL issues commands 9, 10 and 11 and completes the boot, so the board
  diverges *after* correct data has arrived. Leading suspect is CD-RAM: the system card
  writes loaded sectors there and executes from them, simulation models CD-RAM as an ideal
  array, and the board uses the SDRAM window. CD-RAM has only ever been tested by a
  standalone sweep, never under concurrent CPU-and-bridge load.
* **Prince of Persia** takes 18 sectors and then returns to the RUN prompt.
* **Bonk III** never receives a byte. Its CHD has `hunkbytes=2448, sectors_per_hunk=1`
  where Dungeon Explorer II has `19584, 8`; `DECODE-START` is logged and no `SERVED` ever
  follows, so `chd_read` does not complete for that layout. That is a firmware/libchdr
  issue, entirely separate from the SCSI work.

### What the counters do and do not prove

They prove the right NUMBER of bytes arrived and that the FIFO never ran dry or overflowed.
They do not prove the byte VALUES are right, and they say nothing about what reached CD-RAM.
Closing that gap is the next step: dump CD-RAM on hardware after the 6-sector load and
compare it against the same region in simulation and against the reference bytes in
`sim/cd/golden/`.
