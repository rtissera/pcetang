# TangCore integration overhead — what it costs, why, and real alternatives

Written 2026-08-26 at the user's request, after Phase 1/2 `gw_sh` work established real
BSRAM cost numbers for the TangCore integration layer and after researching how
comparable Sipeed Tang ecosystems solve the same problem. All numbers below are real
`gw_sh` measurements from this session unless marked otherwise (NECTang/MiSTer/MiSTle
numbers are from reading their source directly, not measured by this project).

## 1. Where the BSRAM actually goes (measured, per-module)

pcetang's Phase 1 Console 60K build costs 106/118 BSRAM (90%) vs. NECTang's own bare
engine baseline of 82/118 (70%, no TangCore, no video output, no joypad) — a real +24
block delta for adding TangCore integration. Broken down by actual module, not guessed:

| Module | Real BSRAM cost | Source |
|---|---|---|
| `iosys_bl616.v` (UART protocol engine) | **0 blocks** | no internal memory at all |
| `textdisp.v` + `gowin_dpb_menu.v` (OSD) | **1 block** | one explicit Gowin `DPB` primitive, 2Kx8, already at the floor |
| `hdmi2/packet_picker.sv` (header/subs arrays, audio sample buffer) | **~3-4 blocks** | `headers[256]x24` + `subs[256][4]x56` ≈ 57344 bits; audio buffer is 384 bits, negligible |
| `pce2hdmi.sv` (this project's own new code, NOT part of the TangCore fork) — full-frame capture buffer | **~19-28 blocks** (256x224x9 = 516096 bits at the real measurement point) | scan-converts PCE's native, variable-timing video into a fixed 1280x720p60 grid |

**The TangCore fork itself is cheap (~4-5 blocks).** The dominant cost is this
project's own frame-capture buffer, needed *only* because of one specific TangCore
convention (below) — not because of the BL616/UART/OSD machinery itself.

## 2. Why the framebuffer exists: TangCore's own documented convention

`tangcore/doc/dev.md`: *"The hdl-util/HDMI interface should run in 720p mode."* This is
TangCore's own prescribed pattern for every core (nestang, snestang, mdtang, gbatang) —
scan-convert whatever the emulated system natively outputs into a fixed 1280x720p60
grid, so every core presents an identical, universally-compatible HDMI signal
regardless of the source system's real timing. `nes2hdmi.sv` (the reference this
project's `pce2hdmi.sv` was modeled on) does the same thing: full-frame capture at the
source resolution (256x240, 6 bits/pixel for NES's palette index), read out at a
completely independent 720p60 rate.

This is a real, deliberate, project-wide design choice across the whole TangCore
ecosystem, not a mistake or an accident specific to this port. It buys a genuinely
valuable thing (works on any HDMI display, no user-side timing/EDID concerns) at a
real, now-quantified BSRAM cost.

## 3. How other Sipeed Tang / retro-FPGA ecosystems solve this differently

### MiSTer (`sys_top.v`, real source read directly)

Defaults to `direct_video=1`: the HDMI PLL and output timing are driven by the core's
*own* native `CLK_VIDEO`/`CE_PIXEL`, not a fixed external grid. No scan-conversion
buffer exists in this (default, common) path — pixels flow straight from the core to
HDMI at whatever rate/resolution the core natively produces. A separate `vga_fb`
(genuine full framebuffer) mode exists but is opt-in per-core, not the default. Trade:
the display must lock onto the core's native timing rather than a guaranteed-universal
720p60 — real, but MiSTer's target audience (dedicated retro-gaming displays/capture
cards) tolerates this; a general-purpose HDMI monitor usually does too, since HDMI's
EDID/PLL range is flexible in practice.

### MiSTle-Dev/FPGA-Companion + MiSTeryNano (real source read directly, GitHub API)

The user's "mistle dev" reference: `github.com/MiSTle-Dev/FPGA-Companion` is the
companion-MCU firmware behind MiSTeryNano (Atari ST), NanoMig (Amiga), C64Nano,
VIC20Nano, NanoMac, A2600Nano, and others — **and MiSTeryNano explicitly targets Tang
Console 60K, Tang Primer 25K, and Tang Mega 138K**, the same boards as pcetang. Real
architectural differences from TangCore:

- **Companion protocol is SPI, not UART**, and the companion MCU is interchangeable
  (BL616, RP2040, or ESP32-S2/S3) rather than locked to one chip.
- **No frame buffer at all.** `src/tang/nano20k/video2hdmi.v` feeds RGB pixels directly
  into the HDMI serializer at a fixed *source-native* pixel clock (32MHz for Atari ST's
  800x576@50 mode) — the video path only line-doubles via `src/misc/scandoubler.v`, a
  **2-line ping-pong buffer** (`sd_buffer[2*2**HCNT_WIDTH]`, 12-bit RGB444, HCNT_WIDTH=9
  → 1024 entries x12 bits ≈ 12Kbit, **~1 BSRAM block**), not a full frame. Line-rate
  doubling only, timing selected per-mode (`vmode`/`screen` params) from a small fixed
  table matching Atari ST's few known real video modes.

This is the single biggest real number in this report: **~1 block for line-doubling
vs. ~19-28 blocks for full-frame capture-and-scale to a fixed grid.**

## 4. What this means for pcetang, honestly

Console 60K's real CD-fit problem this session came from two stacked costs: the
framebuffer (~19-28 blocks) and `ADPCM_DRAM` at real spec (~28 blocks, 64KB, real
CD-ROM² hardware capacity). Reducing ADPCM to 16KB alone got a real, clean, passing
build (`pcetang_console60k_cd.vhd`, `BSRAM 115/118`, 0/0 violations) — but at the cost
of real ADPCM fidelity. **Replacing the frame-capture approach with a line-doubling
scandoubler (MiSTeryNano's approach) could recover most of the ~19-28 blocks the
framebuffer costs, potentially making room for full 64KB `ADPCM_DRAM` fidelity instead
of the current 16KB reduction** — trading a smaller, real cost (non-universal HDMI
output timing, addressed below) for a bigger one (audio fidelity).

**Real complication, not yet resolved, that must be checked before committing to this
design:** PCE's `HuC6260` VCE has a live `DOTCLOCK` control register (`CR(1:0)`,
`huc6260.vhd:252`) selecting among three dot-clock rates (256/336/512-pixel-wide
modes), and the RTL explicitly detects and handles this register changing **while
already inside active display** (`huc6260.vhd:254`, guarded by a `MULTIRES` signal) —
real PC Engine games can and do switch resolution mid-frame for specific effects. A
single fixed output pixel clock (as MiSTeryNano uses for Atari ST's much simpler,
fixed-mode-set video) may not cleanly cover this without either (a) accepting visual
artifacts on the rare games that use mid-frame resolution switches, or (b) real
per-scanline output reclocking, a harder design. Note this is **not a new limitation
introduced by switching approaches** — the current shipped `pce2hdmi.sv` already
captures into one fixed-size buffer regardless of the source's actual per-scanline dot
clock, so it already doesn't handle this case correctly either; a scandoubler approach
is not obviously worse here, just not yet verified either way.

**Also relevant to the standing NTSC-60Hz requirement**: a line-doubling approach
preserves the source's exact frame rate (whatever PCE's HuC6260 actually outputs,
~59.826Hz for real NTSC PCE timing), whereas the current fixed-720p60 approach
resamples PCE's native rate into an independent 720p60 grid — a latent judder/tear
source that was never actually verified against the standing "PCE is NTSC 60Hz, we
need 60Hz-like output" instruction. Line-doubling is arguably the more correct
approach for that requirement, not a compromise against it.

## 5. Scope assessment — this is a real R&D project, not a build-flag change

Everything else this session (Phase 1 board bring-up, the ADPCM bisection) was
build-flag-level or small, targeted RTL edits, each verifiable in one `gw_sh` run.
Building a working PCE scandoubler + variable/selectable-timing HDMI output is a new
RTL module of real complexity (timing detection, line-buffer control, HDMI PLL/timing
selection per mode, and a real answer to the mid-frame-resolution-switch question
above) — closer in size to `pce2hdmi.sv`'s original design effort than to any fix made
today. It is real, promising, and directly responsive to what the user asked
("explore... suggest ways to fit everything bare metal... this is a fork and allowed to
change some tangcore mechanics"), but it is a multi-session engineering effort, not
something to start and finish inside this same turn without the user weighing in on
scope.

Per the user's own framing, this would be scoped as **pcetang-local** first (a new
sibling module wired only into `pcetang_console60k_cd.vhd`, not touching the three
tracked, real, measured Phase 1 tops or the shared `hdmi2/*.sv` files) — with the
question of back-porting to other TangCore cores (nestang, snestang, etc.) explicitly
deferred, per the user's own words, to "later if needed."

## 6. Follow-up (2026-08-26): PCE video timing specifics — the mid-frame dot-clock risk is real but tractable, verified from `huc6260.vhd` directly

The open risk from section 4 (`DOTCLOCK` changing mid-frame) is real, but reading
`huc6260.vhd`'s actual timing-generation process (`:205-239`) resolves it cleanly,
without needing per-mode output timing at all:

- `H_CNT` (0 to `LINE_CLOCKS-1` = 2729) and `V_CNT` are driven purely by the **master
  clock** (`clk_pce`, real ~42.857 MHz on Console 60K, target 42.9545 MHz — standard
  PCE timing) and reset every line/frame **independently of `DOTCLOCK`**. `HSYNC_F`/
  `VSYNC_F` (real, already-exposed huc6260 outputs) are generated purely from
  `H_CNT`/`V_CNT` — real-world scanline and frame duration are **constant regardless of
  which video mode is active**.
- `DOTCLOCK` only changes how often `CLKEN` (the pixel-valid strobe) pulses within that
  fixed window — divide-by-8 (256-wide mode), divide-by-6 (336-wide), divide-by-4
  (512-wide). This matches real hardware: a real PC Engine CRT signal has a constant
  ~63.6us horizontal period regardless of resolution mode; the console widens or
  narrows individual pixel dwell time to fill it, never changes the scanline rate
  itself. `LINE_CLOCKS`/`DISP_CLOCKS` are both single constants in the file, not
  per-mode tables — confirming this in the RTL, not just from spec knowledge.

**This means a scandoubler that samples on the master-clock domain (using `CLKEN` as
its per-pixel write-strobe into a line buffer sized for the max width, 512, and
`HSYNC_F`/`VSYNC_F` for its own timing reference — the same real ports `pce2hdmi.sv`
already consumes) needs no per-mode reconfiguration at all.** A mid-frame `DOTCLOCK`
switch just changes how many valid samples land in that line's buffer before the next
`HSYNC_F` — the playback/output side, driven by the same constant real-world line rate,
doesn't need to know or care. This is not a new invention: it's the same thing a real
analog CRT does when a real PC Engine switches modes mid-frame, and it directly
resolves the concern raised in section 4 without the fixed-single-output-clock
limitation that (correctly) works for Atari ST's much simpler, truly-fixed-mode video.

## 7. Real precedent for modifying the shared `hdmi.sv` core itself

Checked whether `hdmi2/hdmi.sv`'s fixed CEA-861 `VIDEO_ID_CODE` table (`hdmi.sv:203`)
is a hard limitation. It is, **as shipped** — no custom/non-standard timing case exists.
But MiSTeryNano's own `src/hdmi/hdmi.sv` (same donor lineage, same file names,
`packet_picker.sv`/`tmds_channel.sv`/etc. all present) is a **real, working, already-
shipped fork of this exact IP that replaces the fixed `VIDEO_ID_CODE` table entirely**
with a runtime `stmode`/`screen`-selected custom timing table (`timing0`/`timing1`
internal parameters, fixed 32MHz `VIDEO_RATE`, non-CEA-861). This is direct, real proof
that this exact class of modification — teaching the shared HDMI core a non-standard,
source-native timing mode — has already been done successfully on this same board
family, not just theorized.

**Impact on nestang/mdtang/other TangCore cores, concretely: zero, if done additively.**
The natural way to add this to pcetang's own copy of `hdmi2/hdmi.sv` is a new case
alongside the existing `VIDEO_ID_CODE` table (e.g. `VIDEO_ID_CODE == 0` => custom
timing driven by new input ports), not a replacement of the table. Every existing
TangCore core (nestang, snestang, mdtang, gbatang) passes a real, non-zero
`VIDEO_ID_CODE` (1/2/3/4/etc.) and would take the exact same code path as today,
byte-for-byte — untouched. Only pcetang's own top-level would use the new case. Nothing
about this requires touching nestang/mdtang now, or ever, unless a future decision is
made to migrate them too — which stays exactly as deferred as the user already said.
