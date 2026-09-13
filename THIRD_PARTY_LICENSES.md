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
  - `src/iosys/textdisp.v`, `uart_fixed.v`, `gowin_dpb_menu.{v,mod,ipc}` and the rest of
    `src/hdmi2/*.sv` — unmodified. `uart_fixed.v` carries its own upstream attribution
    (fpga4fun.com & KNJN LLC) and `src/hdmi2/` is Sameer Puri's HDMI implementation.

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
