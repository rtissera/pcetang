# Golden CD boot reference — Dungeon Explorer II (USA)

Captured from an instrumented **mednafen pce_fast** run that reaches the game's title
screen, by logging every CD-register access and every SCSI CDB. The raw capture is
158,645 accesses (~3.5 MB) and is deliberately NOT in the repo; what is here is the part
the tests and the diff actually use.

Two files, both derived from that capture:

* `de2_boot_filtered.txt` — the whole boot with the two high-volume accesses removed:
  `RD $1800` (the busy poll, 94,477 accesses) and every `$1808` (the sector payload,
  63,488 = 31 sectors x 2048 bytes). **680 lines.** That is the entire decision-making
  traffic of a working CD boot, and it is small enough to reproduce in full from either
  the simulation (`sim/cd/tb_cd_boot.vhd` logs `[cdreg]` lines) or from hardware (the
  0xDB trace stream in `src/pcetang_console60k_cd.vhd`). Diff with
  `scripts/cd_golden_diff.py`.

* `de2_boot_commands.txt` — the same capture reduced to the 11 SCSI commands and the
  exact reply bytes the CPU read for each. This is what `tb_cd_bridge.vhd`'s test 18
  asserts against, byte for byte.

## What a working boot is

Eleven commands, thirty-one sectors:

| # | CDB | meaning | reply |
|---|-----|---------|-------|
| 1 | `00 00 00 00 00 00` | TEST UNIT READY | GOOD |
| 2 | `de 00 ca` | GETDIRINFO mode 0, first/last track | `01 34` |
| 3 | `de 01 ca` | GETDIRINFO mode 1, lead-out AMSF | `70 15 36` |
| 4 | `de 02 01` | GETDIRINFO mode 2, track 1 | `00 02 00 00` |
| 5 | `de 02 02` | GETDIRINFO mode 2, track 2 | `00 49 65 04` |
| 6 | `08 00 0e 06 02 00` | READ(6) LBA 3590, 2 sectors | 4096 bytes |
| 7 | `08 00 0e 08 01 00` | READ(6) LBA 3592, 1 sector | 2048 bytes |
| 8 | `08 00 0e 28 03 00` | READ(6) LBA 3624, 3 sectors | 6144 bytes |
| 9 | `de 02 34` | GETDIRINFO mode 2, **track 34** | `66 29 52 04` |
| 10 | `08 00 2f 28 01 00` | READ(6) LBA 12072, 1 sector | 2048 bytes |
| 11 | `08 00 2e a8 18 00` | READ(6) LBA 11944, **24 sectors** | 49152 bytes |

Command 9 is the one no earlier test reached. `tb_cd_boot.vhd` used to report a 2-track
stand-in TOC, so mode 0 answered "last track = 2" and the system card never asked about
track 34 at all -- the simulation was structurally incapable of walking the real path.

## Reproducing the raw capture

The disc's TOC is regenerated straight from the .chd, and it agrees with this trace on
all three independently checkable values -- track 2 = LBA 3590, track 34 = LBA 299077
(AMSF 66:29:52), lead-out = LBA 316011 (AMSF 70:15:36):

    scripts/cd_toc.py "Dungeon Explorer II (USA).chd"
