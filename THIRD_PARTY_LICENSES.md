# Third-party code and provenance

This repo combines RTL from two GPL-3.0 projects, same author (rtissera):

- **PC Engine / SuperGrafx / TurboGrafx-CD core** — from
  NECTang (local-only so far — not a git repo yet, see docs/ARCHITECTURE.md status note), itself a port of
  [TurboGrafx16_MiSTer](https://github.com/MiSTer-devel/TurboGrafx16_MiSTer) — see that
  repo's own `THIRD_PARTY_LICENSES.md` for the full donor-by-donor licensing survey
  (includes one documented, risk-accepted gap: the MiSTer chip cores trace to a codebase
  with no explicit license grant).
- **TangCore integration layer** (`src/iosys/`, `src/hdmi2/`) — copied from
  [nand2mario/nestang](https://github.com/nand2mario/nestang) (GPL-3.0, see that repo's
  `COPYING`), TangCore's own documented template for a new core
  (`nand2mario/tangcore`'s `doc/dev.md`). Specifically:
  - `src/iosys/iosys_bl616.v`, `textdisp.v`, `uart_fixed.v`, `gowin_dpb_menu.{v,mod,ipc}`
    — unmodified at import (2026-08-26). Any changes made here going forward will be
    marked at the change site, same convention as NECTang uses for its own forked files.
  - `src/hdmi2/*.sv` — unmodified at import (2026-08-26), TangCore's shared HDMI/TMDS
    output core.

See `docs/ARCHITECTURE.md` for the integration plan and exactly which interfaces this
repo's own new code (not yet written) will need to implement against the above.
