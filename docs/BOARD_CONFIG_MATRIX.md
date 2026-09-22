# Measured board configuration matrix

Every number here is a real `gw_sh` post-place-and-route build. Nothing is estimated.
Configurations marked **not shipped** have never run on hardware; they are measurements,
not recommendations.

## What each board ships today

Measured 2026-09-20 by the `synthesis` CI workflow, which rebuilds all three boards and
fails on any timing violation — so this table cannot silently drift from the tree again.

| | Nano 20K (GW2AR-18C) | Primer 25K (GW5A-25A) | Console 60K (GW5AT-60B) |
|---|---|---|---|
| Setup / hold violations | 0 / 0 | 0 / 0 | 0 / 0 |
| Core clock | **43.200 MHz** | 42.857 MHz | 42.857 MHz |
| Fmax (margin) | 44.475 (**+2.95%**) | 43.389 (+1.24%) | 42.902 (+0.105%) |
| Logic | 18571/20736 (90%) | 21664/23040 (**95%**) | 27005/59904 (46%) |
| BSRAM | 42/46 (**92%**) | 38/56 (68%) | 110/118 (**94%**) |
| Binding constraint | logic + BSRAM | logic | BSRAM + timing |
| Speed accuracy | exact | 0.23% slow | 0.23% slow |
| Bitstream runs on hardware | never loaded | yes (HDMI locks) | yes |
| **Plays games on hardware** | **no — no storage path** | **no — no storage path** | **yes, 13 titles** |

### Features per board

| | Nano 20K | Primer 25K | Console 60K |
|---|---|---|---|
| HuCard `.pce` | yes | yes | yes |
| HuCard > 832 KB | yes | yes | **yes, HW-confirmed** |
| SF2' mapper (2560 KB) | yes | yes | yes |
| CD-ROM² + CD-DA + ADPCM | built | built | **yes, HW-confirmed** |
| SuperGrafx | no (no room) | no (`LITE => 1`) | **yes, all 4 titles** |
| Arcade Card | no (no room) | no (no room) | **yes, games play (2026-09-22)** |
| VRAM0 | SDRAM + prefetch | SDRAM + prefetch | on-chip |
| PSG path | Path 0 (BRAM) | Path A | Path A |

### What inverted since the 2026-09-17 revision of this file

- **Console 60K is now the tightest board on margin** (+0.105%) and nearly out of BSRAM
  (94%) — SuperGrafx and the Arcade Card cost exactly that. The two small boards now have
  10–30x more timing headroom than it does, the reverse of the long-standing assumption.
- **Nano 20K runs at the full 43.200 MHz**, not 42.4286. The 1.22% slowdown recorded below
  is retired: no microcode pipelining was needed, the cause was a stray `syn_preserve`
  attribute that had reached `main` inside a commit labelled "docs".
- **SuperGrafx and the Arcade Card are no longer out on all three** — both are in on
  Console 60K.

### Why only one board plays games

Not a property of this core, and measured rather than assumed. **Console 60K has two USB-C
ports; Primer 25K and Nano 20K have one, and the onboard debugger firmware owns it**, so
their BL616 has no USB controller free to host storage on. Primer 25K additionally has no
microSD at all; Nano 20K has one, but it is wired to **FPGA pins 80-85** where the MCU
cannot reach it. An instrumented USB mass-storage device presented to the Primer recorded
zero USB configurations and zero sector reads, against 4413 transactions for the same
device on a PC. See `STATUS.md`.

## Measured configurations that are better, but NOT SHIPPED

### Primer 25K: the Arcade Card fits, with the best margin this board has had

| config | setup/hold | Fmax | logic | BSRAM |
|---|---|---|---|---|
| shipping | 0/0 | 42.907 (+0.12%) | 94% | 36/56 |
| on-chip VRAM + `syn_preserve` | 0/0 | 43.256 (+0.93%) | 79% | 53/56 |
| **+ Arcade Card** | **0/0** | **44.262 (+3.3%)** | 85% | 53/56 |

The chain, each link measured:

1. `syn_preserve` on the microcode `MI` register stops GowinSynthesis dissolving those flops and
   moves the microcode table out of BSRAM — **9 blocks freed**.
2. Those blocks let VRAM move **on-chip** (`EXT_VRAM0 => 0`) instead of living on SDRAM.
3. Dropping `vram0_cache` / `vram0_prefetch` / CG prefetch frees **3349 LUTs**.
4. It also takes the SDRAM round trip out of the video path — that is where the timing comes from.
5. The Arcade Card (~1500 LUTs) then fits easily.

`syn_preserve` is load-bearing: without it there is not enough BSRAM for on-chip VRAM, so
synthesis implements VRAM in logic — 34482 LUTs against 23040 available.

On-chip VRAM is the **donor's original design**; `EXT_VRAM0 => 1` was this port's adaptation for
BSRAM-poor boards. This configuration is a step back toward upstream, but it has never been built
before on this board and the VRAM data path differs from every Primer 25K build to date.

### Console 60K: SuperGrafx fits, with more margin than the shipping build

| config | setup/hold | Fmax | logic | BSRAM |
|---|---|---|---|---|
| shipping | 0/0 | 43.056 (+0.46%) | 32% | 78/118 |
| SuperGrafx (`LITE => 0`) | 0/0 | 42.896 | 42% | 117/118 |
| **SuperGrafx + `syn_preserve`** | **0/0** | **43.182 (+0.76%)** | 43% | 108/118 |
| Arcade Card (stock donor code) | 0/0 | 42.865 (+0.02%) | 35% | 78/118 |
| SGX + preserve + Arcade Card | 0/0 | 42.874 (+0.04%) | 45% | 108/118 |

SuperGrafx is BSRAM-bound (117/118 on its own); `syn_preserve` frees the 9 blocks that make it
comfortable. The Arcade Card closes with unmodified donor code — the 2026-09-09 removal is
obsolete.

## Why the Arcade Card cannot follow the same route on Nano 20K

The Primer 25K chain does not transfer, and the blocker is BSRAM, measured not guessed.

On Primer, moving VRAM on-chip cost **+26 blocks net** (27 → 53 after `syn_preserve`). Nano 20K
has **46 blocks in total**:

| step | Nano 20K BSRAM |
|---|---|
| shipping | 40/46 |
| with `syn_preserve` | 31/46 |
| + on-chip VRAM (+26) | **≈ 57/46 — over by ~11** |

No combination of trims reaches 26 free blocks on this device: PSG Path A would shed 6 but costs
399 setup violations, and halving the CD-DA FIFO buys ~2. So `EXT_VRAM0 => 1` is genuinely forced
on Nano 20K, not a legacy choice — and without on-chip VRAM there is no timing gain either, since
Primer's +3.3% came from removing the SDRAM round trip from the video path.

The old route does not work either: 18613 + ~1500 LUTs ≈ 97% logic, at **+0.09%** timing margin on
an already-reduced clock, when the Arcade Card's own paths were the worst paths on both larger
boards. The next available clock notch (27 × 14/9 = 42.0 MHz) buys ~1% margin at the cost of 2.2%
slow audio — audible, and not worth it.

**The only lever with the right magnitude is `cd_bridge` (4004 LUTs on Primer 25K).** A diet
shedding 1500–2000 LUTs is the single change that could make the Arcade Card fit on Nano's logic
budget, and freeing logic at 90% utilisation may also relieve the routing congestion that dominates
the critical path. Both effects are plausible and unmeasured. It is also real work on the module
that took the CD stack from "never boots" to a working CD path (13 titles hardware-tested), so it needs the whole CD
simulation suite as regression.

**What this means for release claims — REVISED 2026-09-20.** The paragraph that stood here
said "full PC Engine CD including Arcade Card titles on Console 60K and Primer 25K". Both
halves were wrong, and this is the one place in this file where being wrong would leak
straight into a public claim, so state it exactly:

- **Console 60K**: HuCards (including >832 KB), CD-ROM² and Super CD-ROM² with CD-DA and
  ADPCM, and all four SuperGrafx titles — confirmed on hardware across 13 titles. The
  Arcade Card plays its games too (Sapphire, Garou Densetsu 2, World Heroes 2, 2026-09-22).
- **Primer 25K and Nano 20K**: build clean and the core runs, but **neither plays a game**,
  because neither board's MCU can reach storage. Not a CD-tier distinction at all — a
  storage one. See "Why only one board plays games" above.

So the honest headline is one board, stated precisely, plus a measured explanation for the
other two. The Arcade Card tier mirroring real hardware remains an aspiration, not a
shipped feature.

## Measured dead ends — do not retry without new evidence

| attempt | result |
|---|---|
| CE-strobe request detection (donor `ce_rom` idiom) | boot sim byte-identical, but Fmax 42.857 vs 43.056 — worse |
| `AC_SLIM`, one shared address adder | 33 LUTs saved; the 4-way mux costs what 3 adders saved |
| Arcade Card registered write bus | no measurable margin (42.860 vs 42.865) |
| Arcade Card on Primer 25K, old config | 100% logic; slim over capacity; +Path0 697 unrouted |
| PSG Path A on Nano 20K | 399 setup violations, 40.104 MHz |
| PSG Path 0 on Primer 25K | fails routing at place_option 0/1/2 (18/16/13 unrouted) |
| `syn_preserve` as a timing fix | it is a BSRAM↔logic trade; −0.07% on Primer, −0.3% on Console 60K standalone |

## Where the logic actually goes

From `impl/gwsynthesis/<top>_syn_resource.html`, which carries a per-module breakdown. Reading it
found 3349 LUTs in one measurement after a night of guesses returned under 300 each.

Primer 25K, largest modules: **`cd_bridge` 4004 LUTs**, VRAM0 prefetch 518, HDMI packet assembler
343, CPU 291, SDRAM controller 281. `cd_bridge` is this project's own code and is larger than
SuperGrafx's entire second VDC on Console 60K (4939 LUTs) — it has never been examined for area,
and it is where the next headroom is on every board.
