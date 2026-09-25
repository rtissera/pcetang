# pcetang

PC Engine / TurboGrafx-16 core for Sipeed Tang FPGA boards, integrated with
[TangCore](https://github.com/nand2mario/tangcore) (BL616-based ROM loading, joypad and
on-screen display).

**▶ Video: [pcetang on the Tang Console 60K](https://youtu.be/lsY_g2JAl80)** ·
**Download: [latest release](https://github.com/rtissera/pcetang/releases/latest)** (needs the
[firmware v0.2.0+](https://github.com/rtissera/firmware-bl616/releases/latest)) ·
**Support: [Ko-fi](https://ko-fi.com/rtissera)**

**HuCard and CD-ROM² games boot and play on Tang Console 60K** — exact-locked HDMI
(720x480, CEA 480p timing) needs monitor set up to correct 4:3 aspect, PSG audio, a
DS 2 controller and an in-game OSD. 
CD games run from real CHD images served over UART, with CD-DA music and ADPCM voices.
Most CD games are already full playable.
**backup-RAM saves persist on the SD card**.
**SuperGrafx works** (some titles may still be imperfect). 
**Arcade Card games boot and play, not perfect yet** — tested games reach
gameplay; some glitches to fix.

Primer 25K and Nano 20K build clean but have **never run a game** yet — support is on the
way through an external MCU to give them the storage path they lack; wiring in progress). 
Don't buy those boards for this core today except if you are developer !!!

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

### What does not work or is incomplete yet

**Arcade Card games are not perfect yet.** Garou Densetsu 2 and World Heroes 2 have minor
graphic glitches in gameplay, undiagnosed. Sapphire plays but its audio does not reach HDMI
capture devices, and it freezes at the level-1 boss (the CD music keeps playing).

**Load one game per power-up.** Loading a second game from the menu without switching the
board off might garble the picture; power-cycle between games. A fix is in progress.

**Two players / multitap are not available yet.** Multi-player needs the multitap option, and
the firmware's OSD Options menu is not implemented yet, so it cannot be switched on.

**Use DualShock 2 pads.** The USB gamepads tested so far are not recognised. I need to do
more testing.

**Cheap HDMI capture devices (UVC) can have issues with timing**
Testing on several PC monitors through HDMI (Iiyama PC monitor + cheap HDMI portable monitor)
works okay. Tested also on real Sony Bravia 4K TV, no issue at all.
Some HDMI fixes are under investigation.

**Primer 25K and Nano 20K still play nothing**, for want of a storage path — see above.

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

## Support

This is a one-person project with real costs: FPGA boards, capture and test gear, and a
lot of engineering time. **Ko-fi donations and hardware donations are both welcome** and go
straight into the next round of work — the Arcade Card fixes, Primer 25K / Nano 20K via the
external MCU, and more.

- Ko-fi: [ko-fi.com/rtissera](https://ko-fi.com/rtissera)
- Hardware (Tang boards, dev kits, test equipment): get in touch through a GitHub issue or Ko-fi.

## How this was built (honest disclosure)

Development was partly AI-assisted (Claude, under my direction). Saying so here rather than
burying it: the interesting question about a project like this is not whether a model was
involved, it is whether the claims hold up.

This is NOT a purely vibe-coded project and the methodology from start to this first release
has been real hardware testing, hardware simulation and exercizing against both reference HDL
implementation and software emulators.
