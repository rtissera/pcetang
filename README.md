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

The CD data path is verified **byte-for-byte against a reference implementation**. An
instrumented build of beetle-pce-fast produces a golden trace of every SCSI command and
every sector it reads; the board's own served-sector log is diffed against it. On four
discs (Dungeon Explorer II, Prince of Persia, Bonk III, Double Dragon II) every sector
matches in both LBA and data, and the system card's boot command sequence matches
command-for-command. See [docs/ANNOUNCEMENT.md](docs/ANNOUNCEMENT.md) §0 for how that
trace is captured.

### What does not

Games load, hand control to game code, and then fail with a dark screen. The CPU runs at
full speed with VBlank interrupts firing and no bad-bank trap, but stops programming the
video chip — which is what a game waiting on something that never arrives looks like.
CD-RAM has been ruled out (a full 256KB address-derived read-back sweep passes). The
current suspect is the CD interrupt path.

## Building

Requires the Gowin toolchain (`gowin-edu`, **not** `gowin-pro` — the latter segfaults
inside its own `libgwsyn.so` on these designs):

    gw_sh build_console60k_cd.tcl      # also build_primer25k_cd.tcl, build_nano20k_cd.tcl

Simulation (GHDL) for the CD bridge and the FIFOs:

    cd sim/cd && ghdl -a --std=08 --workdir=work ../../src/pce/common/core/cd_bridge.vhd tb_cd_bridge.vhd
    ghdl -e --std=08 --workdir=work tb_cd_bridge && ghdl -r --std=08 --workdir=work tb_cd_bridge

The MCU-side firmware lives in a separate repo (a fork of nand2mario's
`firmware-bl616`); the CD sector server is `core/pcecd.cpp` there.
