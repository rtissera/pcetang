# CD-DA timing: why the music was scratchy, and what the link can actually carry

Measured 2026-09-16, the day CD games first booted. Read this before changing anything in
the CD-DA path — the numbers here decide which fixes can possibly work.

## The requirement

CD-DA is 44100 Hz, 16-bit stereo = **176 400 bytes/s**. The MCU serves it as raw 2352-byte
sectors, so the board needs **75 sectors/s — one every 13.33 ms**, sustained.

## What we actually deliver

From `debug.log`'s `cdprog: reqs=N ... tick=T` counters (ticks are FreeRTOS ms):

| run | disc | rate | % of realtime | period |
|---|---|---|---|---|
| 1 | Rondo | 49.7 /s | 66.2 % | 20.1 ms |
| 1 | Rondo, later segment | 49.7 /s | 66.2 % | 20.1 ms |
| 2 | R-Type Complete CD | 49.7 /s | 66.2 % | 20.1 ms |
| 3 | Bonk III | 31.4 /s | 41.8 % | 31.9 ms |

Identical across discs and runs, so it is a structural limit and not content-dependent.

## Where the 20.1 ms goes

**11.76 ms is wire time.** 2352 bytes at 2 Mbaud 8N1 = 200 000 B/s. That alone is **88 % of
the 13.33 ms budget** — the link has 13.4 % headroom for CD-DA before anything else is
counted.

**~8.3 ms is MCU turnaround, paid on every single sector**, because the fetch loop is
strictly serialized with no prefetch:

    SCSI_READ_REQ        assert SECTOR_REQ (read_lba)
    SCSI_READ_WAIT_BYTE  receive 2352 bytes ............ 11.76 ms
       on SECTOR_DATA_LAST -> read_lba+1 -> SCSI_IDLE
    SCSI_IDLE            audio-continue -> SCSI_READ_REQ
                         ^ the MCU only NOW learns about sector N+1

The map / decode / first-byte latency happens *after* the wire goes idle instead of
overlapping the tail of the current transfer.

## What this rules out

- **A bigger FIFO cannot fix it.** CDDA_FIFO is 2048x32 = 46 ms of audio (the donor's 4096
  was halved in `cd_fifos.vhd` for BSRAM). A 34 % *sustained* deficit drains any buffer;
  4096 would only move the first dropout from ~46 ms to ~93 ms.
- **libchdr is not the bottleneck on these discs.** Rondo: 1024 requests, 134 hunk decodes
  = 7.6 sectors per decode, so decode amortises over 8 sectors and cannot account for
  8.3 ms on every one.
- **Resampling is not involved.** `CDDA_CLK_GEN` is `CEGen IN_CLK=429545 OUT_CLK=441` —
  exactly 44.1 kHz from 42.9545 MHz. There is no rate conversion anywhere in the path.
- **Not volume.** Pitch and level are correct whenever data is present. The FIFO simply
  runs dry between refills, which is what makes it *scratchy* rather than slow or quiet.

## Disc geometry varies — check it before blaming the cache

Run 3 logs `loadpcecd: hunkbytes=2448 unitbytes=2448 sectors_per_hunk=1`. That CHD was
built with 1-sector hunks, so every sector costs a full hunk decode (509 decodes for 512
requests — correct for that geometry, not a cache bug) and the rate falls to 41.8 %.
Rondo and R-Type are `hunkbytes=19584 unitbytes=2448 sectors_per_hunk=8`.

## The two fixes, in the order they should be tried

### 1. Prefetch — the actual fix

Issue the request for sector N+1 *before* the last byte of N arrives, so the MCU's
turnaround overlaps the tail of the current transfer. Wire time then becomes the only
cost: **11.76 ms per sector = 113 % of realtime.**

Cost: `cd_bridge.vhd` plus a level output on CDDA_FIFO for flow control (pure pointer
arithmetic on registers that already exist — the data path already does exactly this with
`FIFO_SPACE`). **0 BSRAM.**

Flow control is not optional: at 113 % the FIFO fills, and `CDDA_FIFO` drops writes when
full (`wren_a_i <= wrreq and not full_i`), which would trade dropouts for dropped samples.

**No firmware change is required.** The MCU is already structured for it:

    uart1_rx_task   priority 3   sole RX FIFO consumer, always drains
    cd_req_queue    depth 16     xQueueSend(..., 0), never served inline
    cd_serve_task   priority 2   pops and serves

An early `SECTOR_REQ` arriving mid-transmission is already received and queued, because the
RX task outranks the serve task and drains the FIFO even while a sector is streaming. That
split was built to stop logging preempting a hunk decode; it happens to be exactly the
decoupling prefetch needs.

### 2. Raising the UART rate — the margin, not the fix

`uart_fixed.v` oversamples x8 and rejects less, so with `FREQ => 42_857_000` the ceiling is
**42.857/8 = 5.36 Mbaud**. `BaudTickGen` uses a fractional accumulator, so non-integer
divisors are fine.

| baud | clk/bit | wire/sector | no prefetch | with prefetch | % of budget |
|---|---|---|---|---|---|
| 2M (today) | 21.4 | 11.76 ms | 49.9/s (66 %) | 85/s (113 %) | 88 % |
| 3M | 14.3 | 7.84 ms | 62/s (83 %) | 128/s (170 %) | 59 % |
| **4M** | 10.7 | **5.88 ms** | 70.5/s (94 %) | **170/s (227 %)** | **44 %** |
| 5M | 8.6 | 4.70 ms | 77/s (103 %) | 213/s (283 %) | 35 % |

**Raising the baud alone does NOT fix it** — at 4 Mbaud without prefetch you are still at
94 % of realtime, because the 8.3 ms turnaround is untouched and now dominates. Prefetch is
the fix; baud is what buys room for CD-DA and data streaming at the same time (176 kB/s of
audio on a 200 kB/s pipe leaves nothing for data at 2 Mbaud, at any buffer size).

Raising it is not free, either: `BAUD_RATE` is a `localparam` in `iosys_bl616.v`, and the
MCU sets UART1 once at boot in `init_gpio_and_uart()` before any core is known — so one
firmware binary serves NES/SNES/GBA/MD/SMS/PC/PCE and they would all stop talking. The two
ways out are rebuilding every core at the new rate, or switching baud after core load
(the MCU already knows the CORE_ID it just programmed). Given `origin` is nand2mario's
upstream, the post-load switch is the one that keeps this fork compatible.

Secondary risks at 4M: the MCU's per-byte RX window halves, and there is history there
(polled RX truncating sector-request frames, fixed by moving to a worker task) — `rxhi`
needs re-measuring, not assuming. Also note iosys is told `FREQ => 42_857_000` while
`CDDA_CLK_GEN` implies clk_pce is 42.9545 MHz; the 0.23 % error is proportional and well
inside UART tolerance at any baud, but it is wrong and worth correcting.
