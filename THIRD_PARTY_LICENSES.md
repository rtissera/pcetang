# Third-party code and provenance

This repo combines RTL from two GPL-3.0 projects:

- **PC Engine / SuperGrafx / TurboGrafx-CD core** — from
  NECTang, itself a port of
  [TurboGrafx16_MiSTer](https://github.com/MiSTer-devel/TurboGrafx16_MiSTer) — see that
  repo's own `THIRD_PARTY_LICENSES.md` for the full donor-by-donor licensing survey
  (includes one documented, risk-accepted gap: the MiSTer chip cores trace to a codebase
  with no explicit license grant).
- **TangCore integration layer** (`src/iosys/`, `src/hdmi2/`) — copied from
  [nand2mario/nestang](https://github.com/nand2mario/nestang) (GPL-3.0, see that repo's
  `COPYING`), TangCore's own documented template for a new core
  (`nand2mario/tangcore`'s `doc/dev.md`). Imported 2026-08-26. Two of these files have
  since been **modified** here, and carry a "Modifications copyright" header saying so:
  - `src/iosys/iosys_bl616.v` — modified (UART command set for the CD sector protocol and
    the RTL debug-trace channel).
  - `src/hdmi2/hdmi.sv` — modified (`vtotal_extra` input, so the vertical total can be
    adjusted per frame for genlock).
  - `src/hdmi2/packet_picker.sv`, `src/hdmi2/auxiliary_video_information_info_frame.sv` —
    modified (separate advertised VIC and picture-aspect parameters for the exact-lock
    custom video mode; VIC > 127 advertised as 0).
  - `src/iosys/textdisp.v`, `uart_fixed.v`, `gowin_dpb_menu.{v,mod,ipc}` and the rest of
    `src/hdmi2/*.sv` — unmodified. `uart_fixed.v` carries its own upstream attribution
    (fpga4fun.com & KNJN LLC), `gowin_dpb_menu.v` is Gowin IP-generator output, and
    `src/hdmi2/` is Sameer Puri's HDMI implementation.
- **DualShock 2 controller input** (`src/input/`) — copied unmodified from the same
  nestang tree. `controller_ds2.sv` is nand2mario's. `dualshock_controller.v` is
  "Copyright(c) 2003 - 2004 Katsumi Degawa, All rights reserved", rewritten in 2023 by
  nand2mario, and its own header says "This program is freeware for non-commercial use";
  it carries no GPL grant of its own. That notice is kept intact and is flagged here as an
  open licensing question inherited from nestang.
- **SDRAM controllers** (`src/pce/common/mem/sdram.sv`, `sdram32.sv`) — derived from
  ZXNext_MISTer `rtl/mister/sdram.sv`, Copyright (C) 2021 Alexey Melnikov (GPL-2.0-or-later),
  via this author's own Tang port of that core. Both carry a "Modifications copyright"
  header; the original notice is kept.
- **Test/reference tooling only, not in any bitstream** — `tools/golden/*.patch` are
  instrumentation patches against beetle-pce-fast (Mednafen, GPL-2.0-or-later), and
  `sim/cd/adpcm_wav.py` reimplements Mednafen's OKI ADPCM decode as a reference model.

## Pristine and modified donor copies

`src/pce/tg16-mister-rtl/` holds the TurboGrafx16_MiSTer donor files. Those still
byte-identical to upstream carry no header from this project. The ones changed here —
`HUC6280/HUC6280.vhd`, `HUC6280/HUC6280_CPU.vhd`, `HUC6280/HUC6280_MC.vhd`, `huc6260.vhd`,
`cd/cd.vhd`, `cd/SCSI.vhd`, `cd/MSM5205.vhd` — and the forked copies under
`src/pce/common/core/` (`arcade.sv`, `cheatcodes.sv`, `huc6270.vhd`, `pce_top.vhd`,
`psg.vhd`) carry the "Modifications copyright" header. The generated tables in
`src/pce/common/mem/init/*_pkg.vhd` are the donor's `.mif` data converted to VHDL and
claim no copyright from this project.

## What in this repo is its own work

Everything outside the imported trees above: the three board top levels, the SCSI/CD bridge
(`src/pce/common/core/cd_bridge.vhd`) and its FIFOs, the VRAM0 external-memory cache, the
Gowin BSRAM/PLL glue, the video-to-HDMI path, and everything under `sim/` and `scripts/`.
Those files carry `Copyright (c) 2026 Romain Tisserand`.

Files forked from a donor and changed here carry a "Modifications copyright" header instead,
which claims only the changes — not the file. Files imported and left alone carry no
copyright line from this project at all.

## Known licensing gap

The MiSTer PC Engine chip cores trace back to a codebase with **no explicit license grant**.
This is inherited from upstream, it is not resolved here, and anyone redistributing this
work should be aware of it. See the NECTang `THIRD_PARTY_LICENSES.md` for the donor-by-donor
survey.

See `docs/ARCHITECTURE.md` for the integration design.
