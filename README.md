# pcetang

PC Engine / TurboGrafx-16 core for Sipeed Tang FPGA boards, integrated with
[TangCore](https://github.com/nand2mario/tangcore) (BL616-based ROM loading, joypad and
on-screen display).

**HuCard and CD-ROM² games boot and play on Tang Console 60K** — 720p60 HDMI with a
correct 4:3 aspect, PSG audio, two controllers and an in-game OSD. CD games run from real
CHD images served over UART, with CD-DA music and ADPCM voices: R-Type Complete CD,
Prince of Persia, Rondo of Blood and Bonk III are playable. SuperGrafx games load and
three of four boot, with rendering defects. Arcade Card titles do not run yet.

Primer 25K and Nano 20K build clean but have **never run a game** — don't buy hardware on
the strength of this table.

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
| **HuCard game runs on real hardware** | **yes** | not tested | not tested |
| Video / audio / controllers on real hardware | yes | not tested | not tested |
| CD-ROM²: system card boots off a CHD | **yes** | not tested | not tested |
| **CD game playable, with CD-DA and ADPCM** | **yes** | not tested | not tested |
| SuperGrafx | **3 of 4 boot**, rendering defects | compiled out | no room |
| Arcade Card | compiled in, **games stall** | no room | no room |

"Not tested" on Primer 25K and Nano 20K means exactly that: those bitstreams have never
been loaded onto a board with a game. Neither board has an SD path in this design — their
SD pins carry the FPGA↔BL616 UART link — so storage has to come over USB, which is
untested.

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

### What does not

**Arcade Card games do not run.** Sapphire reaches "NOW LOADING" and stops; Garou Densetsu
2 and World Heroes 2 black-screen after the system card. None of the three looks like an
Arcade Card RAM or register fault — all three sit waiting on the CD unit, which points at
the CD interrupt path.

**SuperGrafx renders incorrectly.** Battle Ace plays but loses sprites; Aldynes and
Daimakaimura show graphic corruption; 1941 Counter Attack stays black. Six candidate
mechanisms have been eliminated with measurements — the VDC RTL is donor code, it
simulates correctly, it synthesises with both VDCs fully intact, and the design closes
timing with the critical path nowhere near the video logic. The cause is not yet known.

**Video is not perfect.** The scandoubler carries about 2.7% residual line tearing (down
from 17.2%) and a low-level shimmer that is inherent to the 755.16-output-lines-per-frame
ratio; the servo dithers between 755 and 756.

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

The MCU-side firmware lives in a separate repo (a fork of nand2mario's
`firmware-bl616`); the CD sector server is `core/pcecd.cpp` there. That fork also carries
the `.sgx` loader support and a HID descriptor-parser fix, so the current feature set
needs it — a build against stock TangCore firmware will not load SuperGrafx ROMs.

## How this was built

Development was AI-assisted (Claude, under my direction) — the commit trailers record it
per commit, and they are staying there.

What matters more than that is how claims in this repo are checked, because "it should
work" has been wrong here repeatedly. The working rule is that nothing is claimed until
it has run: changes are reproduced in simulation before they are fixed, diffed against
golden traces captured from instrumented reference emulators (beetle-pce-fast and MAME),
verified with negative controls, built through real `gw_sh` synthesis with timing
reports, and finally gated on running on real hardware. Several sections of this README
exist specifically to record claims that turned out to be wrong and how they were caught
— see the byte-for-byte episode above, and `docs/STATUS.md`.
