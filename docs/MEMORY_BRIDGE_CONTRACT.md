# The memory-bridge contract — and the bug class that broke PC Engine CD

Written 2026-09-15, after the CD-RAM stale-byte root cause. Read this before writing or
reviewing any bridge between the PCE core and an off-chip memory.

## The rule, in one sentence

**A memory client's request line is a LEVEL that stays asserted across consecutive bus
cycles, so a bridge may never use a rising edge alone to decide that a new access has
begun.**

Every bridge in this port sits between a donor core that assumes zero-wait memory and an
SDRAM that is anything but. Getting the *data* right is not enough: the bridge must also
be certain that the data it publishes belongs to the address the client is asking about
*right now*. A bridge that launches nothing, leaves the previous byte on the bus and keeps
its ready high is indistinguishable, to the client, from a bridge that answered correctly.
That is the failure mode below, and it is silent.

## Why the donor does not have this problem

The donor (MiSTer TurboGrafx16) never edge-detects. `TurboGrafx16.sv:768`:

```verilog
.rd(use_sdr & (rom_rd | cd_ram_rd) & ce_rom),
```

`ce_rom` is `pce_top`'s `ROM_CLKEN`, which is `CPU_CLKEN`, which is the CPU's own bus-cycle
clock enable (`pce_top.vhd`: `ROM_CLKEN <= CPU_CLKEN;`). One launch per memory cycle, by
construction — a level-held read line is harmless because the strobe, not the level, is
what starts the access.

The donor also gives ROM and CD-RAM **one** SDRAM port, **one** data bus and **one** ready
(its `pce_top` has no `CD_RAM_RDY` port at all), so CD-RAM inherits ROM's stall path for
free.

This port changed both properties: ROM and CD-RAM/ADPCM were split onto separate SDRAM
ports with independent request/ack arbiters and separate readys, and `ROM_CLKEN` was wired
to `open`. Each arbiter then had to rediscover, on its own, that a level-held line needs a
per-cycle trigger. Some did. Some did not.

## The failure, concretely

`CD_RAM_RD` is a level:

```
pce_top.vhd      CD_RAM_RD <= CPU_PRE_RD and not (CD_RAM_CS_N and AC_RAM_CS_N)
HUC6280.vhd      PRE_RD    <= CPU_WE_N and CPU_MCYCLE
HUC6280_CPU.vhd  MCYCLE    <= MC.MEM_CYCLE          -- combinational, per microcode row
```

`TAM` ($53) is `STATE0: [PC]->IR, PC++` then `STATE1: [PC]->T, PC++`, both `MEM_CYCLE='1'`.
Executed from CD-RAM, the read line never falls between them. With an edge-only detect the
second fetch launched **no access at all**: the ready stayed high, the CPU was never
stalled, and the data register still held the first byte. The CPU took the TAM *opcode* as
its operand mask.

$53 as a mask is bits 0,1,4,6. The trapped MPR file read `00 97 83 97 81 80 97 97` —
MPR0/1/4/6 = $97, MPR2/3/5/7 untouched. A bit-exact fingerprint. $97 is not a bank, so I/O
and work RAM (the stack) unmapped and the next `RTI` jumped into nowhere.

Generalised: **any run of consecutive fetches returns the first byte of the run**, so
multi-byte code cannot execute from that memory at all. This is why the CD *data* path
always measured clean — the syscard's CD-RAM traffic is interleaved with I/O, work-RAM and
ROM cycles, so the line toggles and every access gets its edge (hence the 16/16
byte-identical CD-RAM readback) — while every disc died the instant the syscard *jumped*
into CD-RAM.

The same defect on the ROM bridge is what produced the HuCard black screen, fixed in
777ba38.

## The two accepted constructions

**(a) A per-cycle strobe.** The donor's. `client_rd and clken`, where `clken` pulses once
per client bus cycle. Robust, requires the core to export such an enable (`ROM_CLKEN`,
`ADPCM_RAM_SLOT_CNT`, a VDC dot-clock enable).

**(b) Edge OR address change.** What this port uses, because `ROM_CLKEN` is not wired:

```vhdl
new_req <= '1' when rd = '1' and (rd_prev = '0' or addr /= addr_last) else '0';
```

A rising edge catches a genuinely new bus cycle; an address change catches back-to-back
accesses where the client never lets the line drop. Require **either**, never both —
requiring both stalls on whichever case the client does not exhibit. Latch `addr_last` at
launch. Include writes in the address term: consecutive same-level writes (a remapped
stack) hit the identical hole.

A same-address back-to-back re-read deliberately does *not* relaunch. That is correct: on
this machine nothing else writes these memories inside one CPU cycle.

The address term is itself a new relaunch source, so it is only safe if the address cannot
move during an access the bridge is still serving. For CPU addresses that is guaranteed:
`WAIT_N` low parks `CPU_CLK_CNT` (`HUC6280.vhd:116-121`), so neither `CPU_CE` nor `CPU_CER`
fires and `CPU_A` cannot advance. The one address on these buses that is NOT a CPU address
is the Arcade Card's auto-incrementing `AC_RAM_A`, and it is safe for the same reason one
step removed: `arcade.sv` increments `base`/`offset` on a rising edge of
`acc = ~(WR_N & RD_N)` (`arcade.sv:125,144`), and `WR_N`/`RD_N` are only updated on
`CPU_CER`/`CPU_CE`, which a stall freezes. Any future address source that is NOT derived
from a CE-gated CPU cycle must be re-checked against this before the address term is
allowed to see it.

**Both constructions also need the ready to fall in time.** A ready that is only a register
is one clock late, and in that window the client can still sample the previous byte. Pair
it with a combinational early-drop:

```vhdl
rdy_comb <= rdy_reg and not (new_req and not done);
```

where `done` is a one-cycle strobe raised on **every** completion path, the watchdog
timeout included.

**Do not copy the ROM bridge's `'0' when state /= IDLE` form into a shared arbiter.** The
CD-RAM arbiter also serves ADPCM; that test is true for every ADPCM RAM slot (~420 ns,
continuous during playback) and would stall the CPU on accesses it is not making. The
`rdy_reg and not (...)` form above is the one that composes.

## Audit of every ported memory client (2026-09-15)

| Client | Trigger construction | Verdict |
|---|---|---|
| ROM, Console 60K | edge OR address change | correct since 777ba38 |
| ROM, Primer 25K | edge OR address change | correct |
| ROM, Nano 20K | **edge only** | **defective by inspection**, fixed 2026-09-15 — not yet observed on hardware, because that board's BL616 has not been flashed yet (it has one; see below) |
| CD-RAM / Arcade Card, all three boards | **edge only** | **broken, observed on hardware**, fixed 2026-09-15 |
| ADPCM RAM, all three boards | `ADPCM_RAM_SLOT_CNT` counter change | **was broken** — wrongly listed as correct by construction; fixed 2026-09-17, see below |
| VRAM0 / VRAM1 (`vram0_cache`) | `dck_ce` clock enable | correct trigger — see caveat below |
| Backup RAM (`BRM_*`) | on-chip `spram`, no bridge | not applicable |
| Work RAM, PSG, palette | on-chip | not applicable |
| ROM load path (`rom_do_valid`) | genuine one-cycle pulse from `iosys_bl616` | correct |

Nano 20K's ROM bridge is a different implementation from Console 60K's `RB_*` FSM, which is
why 777ba38 never reached it. Two implementations of the same contract is how this class
survives a fix; prefer one idiom across all bridges.

Nano 20K's defect is by inspection only so far, but it is testable: that board does have a
BL616 companion, it simply has not been flashed yet. Once it is, a HuCard boot there is a
direct second observation of this bug class on real silicon, on a bridge that was written
independently of the two that were already caught.

### The VRAM caveat — the same class, in its other form

`vram0_cache` triggers correctly (`req_valid_d <= dck_ce`), but it **cannot stall its
client**: the VDC's raster timing is fixed, so a refill that misses its deadline delivers
data for the wrong address rather than holding the VDC off. That is the same contract
violation, and it is tolerated deliberately — mitigated by line refill and BAT/CG prefetch,
and *instrumented* (`dbg_deadline_miss`) rather than left silent. It is a measured
trade-off, not a latent bug, and it is the reason a VDC memory cannot simply reuse a CPU
bridge's design.

## The mechanism, reproduced

`tb_cd_boot` on Dracula X sectors, `CDRAM_WAIT=40`, everything else identical:

| | `CDRAM_STALE_BUG=1` (old bridge) | `CDRAM_STALE_BUG=0` (fixed) |
|---|---|---|
| SCSI commands | stalls at **7** | **8**, still running when stopped |
| `cpu_a` | `1FE009` — bank **$FF**, out of ROM entirely | `000A9D` — bank 0, syscard ROM |
| bytes served | 12 289, `lvl=0`, drained, nothing moving | 34 051, `lvl=2285`, `cdbst=5`, streaming |

The broken bridge does not merely run slower: the CPU leaves ROM and executes in a bank it
has no business being in, the same class of derailment the hardware trap caught at bank
`$97`.

Command 8 in the fixed run decodes to `08 00 0E 0C 20` — READ(6), LBA 3596, count 32 —
which is exactly the golden reference's command 8, the first bulk read. The board stalls at
precisely that boundary: it completes 7, SELECTs for 8, and never sends the CDB.

## Testbench rule

`sim/cd/tb_cd_boot.vhd` used to drive `cd_ram_di_s` from the current address every clock,
unconditionally. A model that always presents the correct byte cannot show a bridge that
presents the wrong one — so the testbench booted Dracula X to its title screen while the
board stalled, and the contradiction went unexplained for days.

**A memory model must be able to be wrong in the ways the hardware can be wrong.** The
testbench now republishes only on an actual launch and carries a `CDRAM_STALE_BUG` generic
that reproduces the broken bridge on demand. This is the second time this file manufactured
a false conclusion (the first was an unwired `FIFO_SPACE` port defaulting to "plenty of
room"); diff a testbench's port map and its memory models against the board's before
trusting a result from it.

## Correction, 2026-09-17: the ADPCM bridge was NOT correct by construction

The audit above listed ADPCM RAM as safe because it detected a new access on a change of
`ADPCM_RAM_SLOT_CNT`. That is only true if the request is already raised when the slot
begins, and it is not: the pend flags behind `ADPCM_RAM_REQ` rise on the MSM5205 sample
clock, on SCSI REQ and on CPU `$180A` accesses, none of them aligned to DRAM slots. A request
that rose mid-slot launched nothing, `READY` was still `'1'` from the previous access, and
`cd.vhd` consumed a stale nibble or counted a write that never reached SDRAM. This is what
silenced ADPCM voices.

There was a second, subtler instance of the same class *inside* `cd.vhd`: its wait gate
decides on one cycle and `DRAM_CLKEN` is consumed on the next, so a pend rising in between
was consumed with no access at all. No bridge could see that in time.

`sim/cd/tb_adpcm_bridge.vhd` measured it with the real `cd.vhd` and an SDRAM model, best case
(no CD-RAM contention), 4000 nibbles each way:

| | writes never reaching SDRAM | playback reads stale |
|---|---|---|
| as shipped | 16.7 % | 23.7 % |
| bridge fixed only | 0 | 2.7 % |
| bridge fixed + `cd.vhd` `DRAM_REQ_SEEN` | **0** | **0** |

A negative control (fixed bridge, old `cd.vhd`) makes the checker report 108 address skips,
so the zero is not a blind checker.

The lesson for the contract: **a "new access" detector is only correct if it cannot miss a
request that starts at any cycle, and a wait gate is only correct if the thing consumed is
the thing it decided on.** Detecting on a slot, strobe or counter boundary is the same
mistake as detecting on a rising edge, whenever the request itself is not aligned to it.
