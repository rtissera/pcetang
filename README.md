# pcetang

PC Engine / TurboGrafx-16 core for Sipeed Tang FPGA boards, integrated with
[TangCore](https://github.com/nand2mario/tangcore) (BL616-based ROM loading, joypad and
on-screen display).

**HuCard and CD-ROM² games boot and play on Tang Console 60K** — exact-locked HDMI
(720x480, CEA 480p, no shimmer or tremor) with a correct 4:3 aspect, PSG audio, two
controllers and an in-game OSD. CD games run from real
CHD images served over UART, with CD-DA music and ADPCM voices: R-Type Complete CD,
Prince of Persia, Rondo of Blood and Bonk III are playable, and **backup-RAM saves persist
on the SD card**. **SuperGrafx works** (some titles may still be imperfect). **Arcade Card
games boot and play, not perfect yet** — Sapphire, Garou Densetsu 2 and World Heroes 2 reach
gameplay; known issues are listed below.

Primer 25K and Nano 20K build clean but have **never run a game** yet — support is on the
way (an external MCU gives them the storage path they lack; wiring in progress). Don't buy
those boards for this core today.

## Credits

This is a port, and the interesting parts were written by other people:

- The PC Engine RTL is srg320's
  [TurboGrafx16_MiSTer](https://github.com/MiSTer-devel/TurboGrafx16_MiSTer).
- The ROM-loading / joypad / OSD layer is nand2mario's
  [TangCore](https://github.com/nand2mario/tangcore) and
  [nestang](https://github.com/nand2mario/nestang).

The work here is the port itself: Gowin BSRAM/SDRAM mapping, the HDMI output path, the
BL616 companion protocol, and a from-scratch SCSI/CD bridge that serves CHD images over
UART. GPL-3.0 throughout — see
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for file-by-file provenance.

## Status

| | Console 60K | Primer 25K | Nano 20K |
|---|---|---|---|
| Builds clean (gw_sh, 0 errors, 0 timing violations) | yes | yes | yes |
| Bitstream loads, core runs on real hardware | yes | **yes** (HDMI sync locked) | never loaded |
| **HuCard game runs on real hardware** | **yes** | no — no storage path | no — no storage path |
| Video / audio / controllers on real hardware | yes | no | no |
| CD-ROM²: system card boots off a CHD | **yes** | no | no |
| **CD game playable, with CD-DA and ADPCM** | **yes** | no | no |
| SuperGrafx | **works** (some titles may be imperfect) | compiled out | no room |
| Arcade Card | **boots and plays, not perfect yet** | no room | no room |
| Backup-RAM saves (persist on SD) | **yes** | no | no |

### Why only one board plays games

This is not "untested" — it was measured, and the cause is the boards' hardware, not this
core. **Console 60K has two USB-C ports; Primer 25K and Nano 20K have one, and the onboard
debugger firmware owns it.** That leaves the BL616 MCU with no USB controller free to host
storage on, and TangCore's model is "cores and ROMs live on storage attached to the BL616".

- **Console 60K** — microSD wired to the BL616. This is the architecture everything assumes,
  and it works.
- **Primer 25K** — no microSD connector at all, and its single USB-C is the debugger port.
  An instrumented USB mass-storage device presented to it recorded **zero USB configurations
  and zero sector reads**, against a control of 4413 transactions on a PC. Nothing ever
  enumerates. The core itself is fine: loaded over JTAG, it runs and HDMI locks.
- **Nano 20K** — a microSD slot exists, but it is wired to **FPGA pins 80-85**, and the
  BL616's SD-host pins are consumed by JTAG and by the UART link to the FPGA. The MCU has no
  electrical path to the card.

The fix for both is a small external MCU on the UART link the core already speaks
(`iosys_bl616` takes ROMs over UART, so it costs no FPGA logic). That work is scoped but
deliberately out of scope for this release, which is about the board that actually plays
games.

[docs/STATUS.md](docs/STATUS.md) is the honest long form — it is deliberately blunt about
what is *verified on real hardware* versus what merely *compiles*, because those are very
different claims.

### What works on the CD path

**In simulation, the system card completes a full boot.** `sim/cd/tb_cd_boot.vhd` runs the
real system card against the real `cd_bridge` and a real disc's sectors, and it issues all
eleven SCSI commands an instrumented mednafen boot of Dungeon Explorer II issues, in the
same order, then a twelfth the reference capture never recorded — the game loading itself.
All 31 boot sectors, 63488 bytes, compare **byte-identical** to that reference, with zero
FIFO drops and zero DATA IN underruns.

The reference and the tooling to diff against it are in the repo: `sim/cd/golden/` holds
the decoded boot (the 680 register accesses that remain once the busy-poll and the sector
payload are filtered out, plus the per-command reply bytes), and `scripts/cd_golden_diff.py`
normalises a mednafen trace, a GHDL log or a hardware trace to one token stream and reports
the first divergence.

**On real hardware, CD games play.** R-Type Complete CD, Prince of Persia, Rondo of Blood
and Bonk III run with CD-DA music and ADPCM voices. Double Dragon II plays with its title
voice cut short. Sectors are served from a CHD by the BL616 companion over UART at 99.8%
of realtime.

### Also working

**SuperGrafx works.** All four titles tested — 1941 Counter Attack, Aldynes, Daimakaimura
and Battle Ace — boot and play on real hardware; some titles may still be imperfect. Every one of them was broken until
2026-09-19, and every one was the same bug: CD-RAM shadowing the top of a large HuCard (see
below). 1941 was a black screen, Aldynes and Daimakaimura showed graphic corruption, and
Battle Ace was missing its sprites.

**Video is exact-locked.** Every PC Engine line becomes exactly two HDMI lines, so there is
no shimmer, no tremor and no roll: the output and the core share one VCO on integer
dividers, and the frame carries a real CEA 480p active area (720x480, VIC 2) so displays
accept it. The earlier "inherent" shimmer was not inherent. See `docs/STATUS.md`.

**The Arcade Card plays its games.** Sapphire, Garou Densetsu 2 and World Heroes 2 all reach
gameplay on hardware (2026-09-22). They had never run before: every Arcade Card port access
launched a phantom second SDRAM access at the next address, which released the CPU early and
let an instruction fetch take the byte just written to the card as its opcode. The games
stream CD sectors into the card byte by byte, so the CPU derailed within a few sectors and
the game re-issued the same read forever — which looked like a CD fault for two rounds of
debugging, and was not one.

### What does not

**Arcade Card games are not perfect yet.** Garou Densetsu 2 and World Heroes 2 have minor
graphic glitches in gameplay, undiagnosed. Sapphire plays but its audio does not reach HDMI
capture devices, and it locks up at the end of level 1.

**An HDMI capture device can lose the audio after a game load** (seen with Sapphire, Bonk III
and Skweek) while a monitor on the same signal still plays it; rebooting the board brings it
back. Under investigation.

**Primer 25K and Nano 20K still play nothing**, for want of a storage path — see above.

### Fixed 2026-09-19: CD-RAM shadowed every HuCard over 832 KB

`cd.vhd` decodes physical banks `$68-$87` as Super CD-ROM RAM, and `pce_top` enabled that
decode unconditionally — so with no disc mounted, CD-RAM still claimed those banks and
outranked the cartridge in the CPU data mux. **Any HuCard larger than 832 KB read its top
192 KB as blank**, executed it, and crashed. That is roughly 21 plain PC Engine titles —
Street Fighter II', Bomberman '94, Parodius Da!, Salamander, PC Genjin 3, Fire Pro
Wrestling 3 — plus the 1 MB SuperGrafx cards. Smaller cards never reach bank `$68`, which
is why they always worked.

The bug is inherited from the MiSTer core this is ported from, and real hardware cannot hit
it: with a disc running, the "HuCard" is the 256 KB System Card, so a big cartridge and
CD-RAM are never live at the same time. Fixed here by gating the CD-RAM claim on whether a
disc is actually mounted.

**Confirmed on hardware 2026-09-19.** Bomberman '94, Parodius Da! and PC Genjin 3 — all
1 MB plain PC Engine cards — boot and play. So do all four SuperGrafx titles. CD games
(Rondo, R-Type Complete CD) are unaffected, still playing with CD-DA and ADPCM.

### A claim that was wrong, kept here on purpose

An earlier version of this file claimed the CD data path was "verified byte-for-byte on
four discs". That was wrong. It rested on a probe that captured the first eight bytes of
each sector; when whole sectors were finally compared, they were corrupt from byte 91
onward. Two real faults were behind it, both in `SCSI.vhd`'s DATA IN path — a burst
running across sector boundaries, and `CD_DATA_END` asserting early so `cd_bridge`
completed a multi-sector read while data was still streaming. Both are fixed. The episode
is why this file separates "verified on hardware" from "compiles" so pedantically.

## Building

Requires the Gowin toolchain (`gowin-edu`, **not** `gowin-pro` — the latter segfaults
inside its own `libgwsyn.so` on these designs):

    gw_sh build_console60k_cd.tcl      # also build_primer25k_cd.tcl, build_nano20k_cd.tcl

Simulation (GHDL). The unit suites take seconds and need no ROM or disc image:

    sim/cd/run_cd_bridge.sh      # 18 cd_bridge checks, incl. the 11 real boot commands
    sim/cd/run_scsi_phase.sh     # SCSI phase lines + a 2048-byte burst at real MCU pace

The full-system boot simulation needs a system card and a sector slice, and is much faster
on GHDL's LLVM backend than on mcode (about 3.5 s versus 30 s of wall clock per simulated
millisecond):

    scripts/cd_toc.py game.chd > toc.txt
    chdman extractcd -i game.chd -o g.cue -ob g.bin
    scripts/cd_slice.py g.bin --lbas 3588-3600,3620-3632,11940-11975,12070-12078 > sec.hex
    TOC_FILE=toc.txt SECTOR_CNT=80 sim/cd/run_cd_boot_llvm.sh syscard3.pce sec.hex

See the header of `run_cd_boot_llvm.sh` for the three things ghdl-llvm needs before it will
start at all.

### The companion firmware is required, not optional

The BL616 MCU firmware lives in a separate repo,
[rtissera/firmware-bl616](https://github.com/rtissera/firmware-bl616) — a fork of nand2mario's
`firmware-bl616`. **Use v0.2.0 or later** (see its releases). **Stock TangCore firmware has no PC Engine support of any kind** — its
cores are NES, SNES, GBA, Mega Drive, Master System and PC/XT. The fork adds:

- `core/pce.cpp` — HuCard (`.pce`, `.sgx`) loading
- `core/pcecd.cpp` / `.h` — the whole CD-ROM² side: TOC upload, the sector server that
  streams CHD sectors over UART, CD-DA delivery by DMA and the ADPCM feed
- a HID descriptor-parser fix for controllers that use extended (4-byte) usage items

So a bitstream from this repo running against stock firmware loads nothing at all — no
HuCard, no disc. The two repositories are one system and have to be built together.

## How this was built

Development was AI-assisted (Claude, under my direction). Saying so here rather than
burying it: the interesting question about a project like this is not whether a model was
involved, it is whether the claims hold up.

What matters more than that is how claims in this repo are checked, because "it should
work" has been wrong here repeatedly. The working rule is that nothing is claimed until
it has run: changes are reproduced in simulation before they are fixed, diffed against
golden traces captured from instrumented reference emulators (beetle-pce-fast and MAME),
verified with negative controls, built through real `gw_sh` synthesis with timing
reports, and finally gated on running on real hardware. Several sections of this README
exist specifically to record claims that turned out to be wrong and how they were caught
— see the byte-for-byte episode above, and `docs/STATUS.md`.
