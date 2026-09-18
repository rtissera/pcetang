# Measured board configuration matrix

Every number here is a real `gw_sh` post-place-and-route build, measured 2026-09-17/18.
Nothing in this file is estimated. Configurations marked **not shipped** have never run on
hardware; they are measurements, not recommendations.

## What each board ships today

| | Nano 20K (GW2AR-18C) | Primer 25K (GW5A-25A) | Console 60K (GW5AT-60B) |
|---|---|---|---|
| Setup / hold violations | 0 / 0 | 0 / 0 | 0 / 0 |
| Core clock | 42.4286 MHz | 42.857 MHz | 42.857 MHz |
| Fmax (margin) | 42.466 (+0.09%) | 42.907 (+0.12%) | 43.056 (+0.46%) |
| Logic | 18613/20736 (90%) | 21509/23040 (94%) | 19173/59904 (32%) |
| BSRAM | 40/46 (87%) | 36/56 (65%) | 78/118 (66%) |
| Binding constraint | logic + timing | logic + routing | BSRAM |
| Hardware-tested | never | never | yes, 5 CD games |
| Speed accuracy | 1.22% slow | 0.23% slow | 0.23% slow |

HuCard, CD-ROM², CD-DA, ADPCM and the SF2' mapper are in on all three. The Arcade Card and
SuperGrafx are out on all three.

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
