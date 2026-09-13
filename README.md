# pcetang

PC Engine / TurboGrafx-16 core for Sipeed Tang FPGA boards, integrated with
[TangCore](https://github.com/nand2mario/tangcore) (BL616-based ROM loading, joypad and
on-screen display).

**HuCard games boot and play on Tang Console 60K** — 720p60 HDMI with a correct 4:3
aspect, PSG audio, two controllers and an in-game OSD. CD-ROM² loads real CHD images and
boots the system card, but **no CD game is playable yet**.

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
| **CD game playable** | **no** | no | no |
| Arcade Card | compiled out | compiled out | compiled out |
| SuperGrafx | off | off | off |

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

### What does not

**No CD game boots on real hardware yet.** The simulation result above is a strong claim
about the RTL and a weak one about the board: it does not model SDRAM, the BL616 companion,
or real UART timing.

An earlier version of this section claimed the CD data path was "verified byte-for-byte on
four discs". That claim was wrong. It rested on a probe that captured the first eight bytes
of each sector; when the whole sector was finally compared against the reference, sectors
were corrupt from byte 91 onward. Two real faults were behind it, both in `SCSI.vhd`'s DATA
IN path — a burst that ran across sector boundaries, and `CD_DATA_END` being asserted early
so `cd_bridge` completed a multi-sector read while data was still streaming. Both are fixed;
the byte-for-byte claim is only made for simulation, because that is the only place it has
actually been checked end to end.

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
`firmware-bl616`); the CD sector server is `core/pcecd.cpp` there.
