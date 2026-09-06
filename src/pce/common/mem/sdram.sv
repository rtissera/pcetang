// SPDX-License-Identifier: GPL-3.0-or-later

// SDRAM controller for the ZX Spectrum Next core, retargeted to Gowin GW5A.
//
// Copied from ZXNext_MISTer rtl/mister/sdram.sv, Copyright (C) 2021 Alexey Melnikov,
// GPL-2.0-or-later. Changes are marked "Gowin port:" and are limited to the 140 MHz
// clock, the widened state counter that follows from it, and the clock output primitive.
// The interesting part -- the 32-bit read cache per channel, the port A/B arbitration
// and RAM_A_WAIT driving the core's CPU_WAIT -- is untouched.
//
// Pin names map to the Tang SDRAM V1.3 module on the 40-pin header; see
// src/tang_console60k/zxnext_console60k.cst (O_sdram_* / IO_sdram_dq).
//
// Part of the ZX Spectrum Next port to the Tang Console 60K. GPLv3.
//
// PCE PORT: copied into this port (PC Engine/SGX/TG16, GPL-3.0-or-later) from
// ../TangNano60K/src/common/mem/sdram.sv, same author, same GW5A family (Primer 25K here,
// not Console 60K -- that board's whole engine already fits on-chip, no external memory
// needed there) -- see THIRD_PARTY_LICENSES.md. Not byte-identical: two changes, both
// marked "PCE PORT" at the site, mirroring the identical reasoning already applied to
// src/common/mem/sdram32.sv (the Nano 20K variant of this same donor) -- see that file's
// header for the fuller rationale, not repeated here. Port A carries VRAM0 (needs writes
// and real wait-state feedback -- the VDC has zero tolerance for a late response, see
// NECTang's docs/PORTING.md's "VRAM0 external memory" design consult). Port B carries cartridge ROM
// (latency-tolerant via pce_top.vhd's existing ROM_RDY -> WAIT_N path).
// Arbitration priority swapped so A beats B, and RAM_B_WAIT added (the original has no
// completion signal on port B at all).
//
// PCE PORT (2026-08-26): port B given a write side (RAM_B_WE/RAM_B_DI) for the Primer 25K
// CD build's cart/syscard ROM offload -- see docs/ARCHITECTURE.md's "Goal revised" section.
// Loading (write) and gameplay (read) never overlap in time (the core is held in reset
// during load), so this reuses the one port rather than adding a third -- no new
// arbitration needed. A write always forces a real bus cycle (never served from the line
// cache -- see fetch_req_b below) and invalidates the cached line afterward, since the
// cache's shadow copy (last_data) is not updated by a write. RAM_B_WE defaults to 0 so
// existing callers that don't connect it are unaffected.
//
// PCE PORT (2026-08-27): a real third client, port C, added for CD-RAM offload -- see
// docs/ARCHITECTURE.md's "Real syscard boot" section. Unlike B, this one genuinely
// overlaps in time with A and B during real gameplay (CD-RAM is CPU-random-access,
// backing pce_top.vhd's CD_RAM_A window), so it needed real arbitration, not a mux.
// Mirrors port A's convention (real read+write, small line cache, level-held REQ with
// rising-edge launch) rather than B's toggle/write-invalidates one -- see fetch_req_c
// and the ch2_busy completion block. Priority is refresh > A > B > C -- see the
// refresh-first note below for why refresh leads. `store` widened from 3 bits to 4
// (was a 1-bit channel select packed into its top 2 bits alongside the pending flag;
// now a real 2-bit channel select, `store[2:1]`, for 3 channels).
//
// PCE PORT (2026-08-27): refresh moved to the FRONT of the STATE_IDLE priority chain,
// ahead of all three clients -- it used to be the last `else if`, so a client only had
// to stay busy to starve it indefinitely, and this design's own header had flagged
// exactly that risk as real but unmeasured once a third continuously-active client
// (C) was added. sdram32.sv's own header documents the identical bug already found
// and fixed on the Nano 20K variant of this donor, with a real field symptom: every
// ROM loaded and verified, then the machine dropped to a grey screen with random bars
// once real traffic (not just the boot loader) kept the controller busy enough that
// STATE_IDLE was never reached with every client quiet -- rows need refreshing every
// 7.8us and none were issued. `rfsh_cnt` is 9 bits and saturates, so the deadline is
// 511 cycles -- at this file's 120MHz `clk_sdram`, 4.26us, comfortably inside spec.
// PCE PORT (2026-08-27), corrected: this originally claimed preempting cost "a
// handful of clk_sdram cycles, not a whole transaction" -- WRONG, real Verilator sim
// (see docs/ARCHITECTURE.md's "Port-A throughput measurement" section) measured a
// full STATE_START->STATE_LAST cycle count, same length as any other access (10
// cycles/83.33ns at 120MHz) -- `state <= STATE_START` on the refresh branch runs the
// exact same counter as everything else. Preempting costs whichever client was about
// to launch one full transaction slot, not a discount.
//
// PCE PORT (2026-08-27): `last_valid[]` replaces the "stuff last_a with all-ones on a
// miss/write" sentinel, for ports A and C (port B already used a separate real
// invalidate site, see below). sdram32.sv's header documents the same fix on the Nano
// 20K variant of this donor: the all-ones trick makes the 20-bit comparator
// (last_a != RAM_x_ADDR) drive a register's synchronous SET pins directly on every
// miss, which is a measurably worse timing shape than a plain data path -- confirmed
// as the real, single worst setup path in this design's own timing report after the
// ADPCM-to-SDRAM offload (`sdram_inst/last_a[0]...->last_a[2].../SET`, see
// docs/ARCHITECTURE.md). A dedicated valid bit per channel gives the same behaviour
// through an ordinary register write instead. Ported here as its own scoped change,
// not bundled with any other fix, so its effect on clk_sdram's margin can be measured
// in isolation.
//
// PCE PORT (2026-08-28): "line refill" -- 4-word VRAM0 cache-line refill for port A.
//
// CORRECTION (2026-08-28, real GHDL dbg_deadline_miss measurement, see
// scratchpad/deadline_miss_rate_measurement.md): this does NOT close the VRAM0
// deadline gap -- deadline-miss rate is empirically saturated at the cache-miss rate
// in BOTH single-word and line-refill configs (cache_ctrl's give-up logic ends every
// outstanding refill at dwell-1 cycles regardless of refill speed). What this real,
// measured mechanism buys is fewer misses triggered at all: BAT's real measured miss
// rate drops 17.2%->5.44% (3.16x fewer, real GHDL-measured per-stream same-line
// locality: 75.4% for BAT, ~0% for CG0/CG1/sprites within a scanline -- see
// docs/ARCHITECTURE.md's VRAM0 deadline-gap section and
// scratchpad/vram0_deadline_implementation_plans.md option (c)). CG0/CG1 still
// benefit via fewer FUTURE misses (1.6-2.0x measured), not this scanline's deadline.
// `vram0_cache.vhd`'s own cache line is 4 words (`address(10:2)`); on a
// genuine read-miss refill (never a write-drain), it now requests the WHOLE line's
// base word (word 0) with a new `RAM_A_LINE_REFILL` flag held for the request, instead
// of just the one missed word. This file answers with TWO back-to-back burst-of-2 READ
// commands to the SAME already-open row -- confirmed bit-exact from this file's own
// `{bank,a} <= RAM_A_ADDR` and the STATE_CONT/STATE_START column/row split: VRAM0's
// cache-line-selecting address bits fall entirely inside the column field (`a[9:1]`),
// never the row field (`a[22:10]`), for every word in a 4-aligned line, so no new
// ACTIVE is needed between the two READs. `BURST_LENGTH`/`ACCESS_TYPE`/the mode
// register are completely untouched -- an earlier draft of this design considered
// switching to a real burst-of-4 and was rejected specifically because that's a global,
// once-at-init mode-register setting, real risk to ports B/C and the Primer 25K CD
// build's already-thin clk_sdram margin, for the same net effect the two-burst
// approach gets without touching the mode register at all.
//
// Real, measured (not assumed) SIM-model calibration and timing derivation for this
// change lives in scratchpad/line_refill_verification.md, not repeated here -- but the
// key structural facts: the 2nd READ launches at STATE_CONT+2 (clk_sdram cycles), to
// column = 1st READ's own column + 2 words; RAM_A_WAIT is held (not cleared at the
// usual STATE_READY) through a new STATE_LAST_LR = STATE_READY+4 for a line refill
// specifically -- the PROVEN minimum (a real simulation sweep, not a guess: +2/+3 each
// miss one of the two trailing words, see the verification log), not an
// arbitrarily-conservative pad; RAM_A_ADDR's word-within-line bits are forced to 0 (always
// fetch fixed order word0,1,2,3 -- critical-word-first was considered and dropped, see
// the plan doc, since with two FIXED burst-of-2 halves rather than one wrapping
// burst-of-4, "start at the missed word" only helps if it's word 0 or 2) for BOTH the
// launch address and last_a[0]'s own tag (the second one caught by advisor review --
// masking only the launch address while leaving the tag unmasked would let a
// word0/word1 fetch's cache tag falsely match a later word2/word3 request). A line
// refill always forces a real SDRAM access (never the free low-level-cache-hit path --
// see the STATE_IDLE port-A launch block below), since the new `last_data0_ext`
// holding words 2/3 has no tag/valid tracking of its own and a coincidental hit would
// hand back stale, unrelated data for those two words specifically.
//
// This must NOT (and per scratchpad/line_refill_verification.md's Stage 3 differential
// test, does NOT) change ports B/C's own behaviour, timing, or the refresh-starvation
// fix's ordering in any way when RAM_A_LINE_REFILL is never asserted -- `line_refill`
// is reset every STATE_IDLE cycle alongside `we`/`ch0_busy`/etc (same pattern), so
// every new state (STATE_CONT2/STATE_READY2/STATE_LAST_LR) is provably unreachable
// outside a real line-refill transaction, not just unlikely to be reached.

//============================================================================
//
//  SDRAM controller
//  Copyright (C) 2021 Alexey Melnikov
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module sdram
(
	input             clk,
	input             init,

	output reg [12:0] SDRAM_A,
	inout      [15:0] SDRAM_DQ,
	output reg  [1:0] SDRAM_BA,
	output reg        SDRAM_DQML,
	output reg        SDRAM_DQMH,
	output reg        SDRAM_nWE,
	output reg        SDRAM_nCAS,
	output reg        SDRAM_nRAS,
	output            SDRAM_nCS,
	output            SDRAM_CKE,
	output            SDRAM_CLK,

	// PCE PORT (2026-08-29): widened 21->25 bits -- real chip capacity confirmed (Winbond
	// W9825G6KH-6, 256Mbit=32MB, 4 banks -- datasheet + a real board photo match, see
	// session memory), and this file's own row/column/bank signal widths (a[22:0] +
	// bank[1:0] = 25 bits) already matched that chip exactly; only the CLIENT PORTS were
	// narrower, forcing bank and a[22:21] to 0 via implicit zero-extension at every
	// `{bank,a} <= RAM_x_ADDR` site. This is a real address-space widening, not a cosmetic
	// one -- every client (VRAM0, ROM, CD-RAM/ADPCM/Arcade-Card) can now genuinely reach
	// all 32MB, not just bank 0's 2MB. See the opportunistic per-channel cache note at
	// `last_a`'s own declaration for the one correctness-critical consequence of this.
	input      [24:0] RAM_A_ADDR,
	input             RAM_A_REQ,
	input             RAM_A_RD_n,
	// PCE PORT (2026-08-27): widened 8->16 bits -- see header's "port A width" note.
	// Address stays byte-granular (bit 0 always 0 from vram0_cache.vhd, word-aligned).
	input      [15:0] RAM_A_DI,
	output reg [15:0] RAM_A_DO,
	output reg        RAM_A_WAIT,
	// PCE PORT (2026-08-28): 4-word cache-line refill for VRAM0 -- see header's "line
	// refill" note. Sampled at launch exactly like RAM_A_RD_n/RAM_A_ADDR; held by the
	// caller for the whole 4-word request, but only the launch-time value matters here.
	// Never combined with a write (vram0_cache.vhd only asserts this on a genuine read
	// miss refill, never a write-drain).
	input             RAM_A_LINE_REFILL = 1'b0,
	// PCE PORT (2026-08-28): all 4 words of a completed line refill, valid (and stable
	// until the NEXT line-refill transaction) from the same cycle RAM_A_WAIT falls for
	// that transaction. {word3,word2,word1,word0}. RAM_A_DO itself is unchanged (still
	// just the originally-addressed word, 16 bits) for compatibility with every other
	// caller of this port.
	output reg [63:0] RAM_A_LINE_DO,

	input      [24:0] RAM_B_ADDR,
	input             RAM_B_REQ,
	input             RAM_B_WE  = 1'b0,  // PCE PORT: write side, added for ROM offload, see header
	input       [7:0] RAM_B_DI  = 8'h0,  // PCE PORT: write data, added for ROM offload, see header
	output reg  [7:0] RAM_B_DO,
	output reg        RAM_B_WAIT,     // PCE PORT: absent in the ZX Next original, see header

	// PCE PORT: third client, added for CD-RAM offload, see header. Level-held REQ like
	// port A (rising-edge launch, held through the wait, same convention as RAM_A_REQ) --
	// unlike port B, this needed real read+write from day one, so it matches A's shape
	// more closely than B's toggle-per-request one. Lowest arbitration priority (below
	// both A and B) -- see header's arbitration note.
	input      [24:0] RAM_C_ADDR = 25'h0,
	input             RAM_C_REQ  = 1'b0,
	input             RAM_C_RD_n = 1'b1,
	input       [7:0] RAM_C_DI   = 8'h0,
	output reg  [7:0] RAM_C_DO,
	output reg        RAM_C_WAIT,

	// PCE PORT (2026-08-30): real 16-bit + line-refill additions for a SECOND external-
	// VRAM client (VRAM1/SGX) sharing this same lowest-priority port -- see the SGX
	// contention feasibility record in session memory. Port C's own fetch already reads a
	// full 16-bit word from SDRAM (data_reg, same 2-word opportunistic cache as port A) --
	// only the output mux threw half away for CD-RAM's own real byte interface. These new,
	// DEFAULTED ports let a wide caller (RAM_C_WIDE=1) get the full word/line without
	// touching a single bit of CD-RAM's existing 8-bit RAM_C_DI/RAM_C_DO path -- a board
	// that never asserts RAM_C_WIDE (every existing CD-RAM caller) is byte-identical to
	// before this port existed. RAM_C_WIDE is expected held constant per board (VRAM1 and
	// CD-RAM never coexist on the same board today), not toggled per-transaction.
	input             RAM_C_WIDE = 1'b0,
	input      [15:0] RAM_C_DI16 = 16'h0,
	output reg [15:0] RAM_C_DO16,
	input             RAM_C_LINE_REFILL = 1'b0,
	output reg [63:0] RAM_C_LINE_DO
);

assign SDRAM_nCS = 0;
assign SDRAM_CKE = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];

// Gowin port: the original declared SDRAM_DQ as `inout reg` and drove it procedurally,
// which GowinSynthesis rejects (ERROR EX3900, procedural assignment to a non-register).
// Same behaviour, expressed as an explicit tristate driver.
reg [15:0] dq_out;
reg        dq_oe;
assign SDRAM_DQ = dq_oe ? dq_out : 16'bZ;

// Gowin port: retuned from MiSTer's 112 MHz to the 140 MHz this board's PLL can make.
// At 140 MHz one cycle is 7.14 ns, so tRCD=18ns needs 3 cycles (21.4 ns), not 2 (14.3 ns),
// and the Tang SDRAM V1.3 module wants CL3 at this clock.
localparam RASCAS_DELAY   = 3'd3; // tRCD=18ns -> 3 cycles@140MHz
localparam BURST_LENGTH   = 3'd1; // 0=1, 1=2, 2=4, 3=8, 7=full page
localparam ACCESS_TYPE    = 1'd0; // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd3; // 2/3 allowed
localparam OP_MODE        = 2'd0; // only 0 (standard operation) allowed
localparam NO_WRITE_BURST = 1'd1; // 0=write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH}; 

// Gowin port: widened from 3'd to 4'd. With RASCAS_DELAY=3 and CAS_LATENCY=3,
// STATE_READY is 9 -- a 3-bit state counter would silently wrap at 7 and the
// controller would never reach the ready state.
localparam STATE_IDLE  = 4'd0;             // state to check the requests
localparam STATE_START = STATE_IDLE+1'd1;  // state in which a new command is started
localparam STATE_CONT  = STATE_START+RASCAS_DELAY;
localparam STATE_READY = STATE_CONT+CAS_LATENCY+2'd2;
localparam STATE_LAST  = STATE_READY;      // last state in cycle

// PCE PORT (2026-08-28): line-refill extension -- see header's "line refill" note and
// docs/ARCHITECTURE.md's VRAM0 deadline-gap section. A 4-word line refill issues a
// SECOND back-to-back burst-of-2 READ, to the SAME already-open row, exactly 2
// clk_sdram cycles after the first (STATE_CONT2 = STATE_CONT+2) -- real SDR SDRAM
// behaviour, not a new mode; BURST_LENGTH/ACCESS_TYPE/the mode register are untouched.
// STATE_READY2/STATE_LAST_LR mirror STATE_READY/STATE_LAST, offset by that same +2,
// since every downstream timing event of the 2nd READ inherits its +2 offset from the
// 1st. The state counter (4 bits, max 15) comfortably covers this -- no widening
// needed. STATE_LAST_LR = STATE_READY+4 is the PROVEN minimum, not a guess: a real
// simulation sweep of the +2/+3/+4 offsets (see line_refill_verification.md Stage 2)
// showed +2 misses word2, +3 misses word3 (both a real same-edge non-blocking-
// assignment read-before-write of last_data0_ext, not a fluke), +4 is the first value
// where all 4 words land correctly with zero X's -- confirmed by direct simulation,
// then adopted as final rather than starting conservative and never revisiting it.
localparam STATE_CONT2   = STATE_CONT + 3'd2;
localparam STATE_READY2  = STATE_READY + 3'd2;
localparam STATE_LAST_LR = STATE_READY + 3'd4;

reg  [3:0] state;
reg [22:0] a;
reg  [1:0] bank;
reg [15:0] data;
reg        we;
reg        ram_req=0;
// PCE PORT (2026-08-29): widened 20->23 bits (RAM_x_ADDR[24:2]), alongside the client
// port widening above -- REAL CORRECTNESS HAZARD if missed, not a cosmetic resize: this
// opportunistic 2-word cache's tag previously covered only RAM_x_ADDR[20:2], i.e. bank
// and a[22:21] were NEVER part of the comparison (harmless before, since those bits
// were always 0). Once a client can genuinely address a nonzero bank or a[22:21], two
// DIFFERENT physical SDRAM words that happen to share the same low 19 bits but differ
// in bank/upper-address would have aliased in this cache -- a real, silent data
// corruption bug, not a hypothetical one. The tag now spans the client's FULL real
// address (minus the low 2 bits, which select byte/word within the cached 32-bit
// last_data entry, not a distinct cache line).
reg [24:2] last_a[3];
// PCE PORT (2026-08-27): one valid bit per channel -- see header's "last_valid[]"
// note -- instead of an all-ones sentinel stuffed into last_a itself. Defaults to all
// invalid at reset/power-up, same effective behaviour as the old sentinel (any real
// address technically *could* collide with '1, this never technically could with a
// cleared valid bit).
reg  [2:0] last_valid = 3'b000;
reg  [8:0] rfsh_cnt;
// PCE PORT (2026-08-27): set on port A's launch, clear on B's/C's -- see header's "port A
// width" note. Overrides STATE_CONT's byte-select DQM masking so a port-A write enables
// BOTH SDRAM_DQ byte lanes instead of masking one (port A is now a real 16-bit-wide
// access, not two sequential 8-bit ones).
reg        wide_acc = 1'b0;

// PCE PORT (2026-08-28): line-refill state -- see header. `line_refill` mirrors
// `wide_acc`'s own lifetime exactly (set at port-A's launch, reset every STATE_IDLE
// cycle alongside `we`/`ch0_busy` so a stale '1' can never leak into a B/C/refresh
// transaction -- see the STATE_IDLE reset block below). `last_data0_ext` holds words 2
// and 3 of the line (word2 in [15:0], word3 in [31:16]) captured by the SAME
// arm-then-consume idiom `store` already uses for word1, just re-triggered 2 cycles
// later to match the 2nd READ's own 2-cycle-later issuance -- see the STATE_READY2/
// store_lr handling below. RAM_A_ADDR_LINE_MASKED forces the word-within-line bits
// (RAM_A_ADDR[2:1]) to 0 for BOTH the launch address latch AND last_a[0]'s own tag --
// the advisor caught that masking only the launch address while leaving last_a[0]
// unmasked would tag a word0/word1-pair fetch as if it were the word2/word3 pair,
// manufacturing exactly the false-hit hazard the masking exists to prevent.
reg        line_refill = 1'b0;
// PCE PORT (2026-08-30): which channel's own launch set `line_refill` this transaction --
// A (0) or C (1). `last_data0_ext`/the STATE_CONT2/READY2/LAST_LR sequencing below is
// already fully channel-agnostic (keyed only on `line_refill`/`ram_req`/`we`/`state`/
// `mode`, never on `bank`/`a`) -- this flag is the ONE piece that was A-specific: routing
// the completed 4-word answer to RAM_A_LINE_DO vs RAM_C_LINE_DO, and clearing the right
// WAIT. Meaningless when `line_refill` itself is 0. Only A's and C's own launch branches
// ever set it (to 0 and 1 respectively); B's launch never uses line_refill at all.
reg        lr_is_c = 1'b0;
reg [31:0] last_data0_ext = 32'h0;
// PCE PORT (2026-08-29): widened alongside RAM_A_ADDR (21->25 bits) -- zeroes only the
// low 3 word-within-line bits, preserves everything else INCLUDING the now-real bank/
// upper-address bits, so a line refill correctly targets whatever bank/region the
// caller's real address is in, not implicitly bank 0 (see the `{bank,a} <=` site below,
// which used to hardwire `2'b00` here for exactly that reason -- no longer needed or
// correct now that this wire already carries the real bank bits verbatim).
wire [24:0] RAM_A_ADDR_LINE_MASKED = {RAM_A_ADDR[24:3], 3'b000};
// PCE PORT (2026-08-30): same masking, port C's own wide line-refill client -- see
// RAM_C_LINE_REFILL's own port comment and RAM_A_ADDR_LINE_MASKED's comment above for why
// this must mask both the launch address AND last_a[2]'s own tag.
wire [24:0] RAM_C_ADDR_LINE_MASKED = {RAM_C_ADDR[24:3], 3'b000};

// PCE PORT (2026-08-29): tag comparisons widened to the full RAM_x_ADDR[24:2] (23 bits,
// matching last_a's own widened declaration) -- see that signal's comment for why this
// is a real correctness fix, not just following the port width up.
wire       fetch_req = (RAM_A_RD_n || !last_valid[0] || last_a[0] != RAM_A_ADDR[24:2]);
// PCE PORT: a write always forces a real bus cycle -- see header -- so it's OR'd into miss.
wire       fetch_req_b = RAM_B_WE || !last_valid[1] || (last_a[1] != RAM_B_ADDR[24:2]);
// PCE PORT: third client (CD-RAM). Same shape as fetch_req (port A) -- real read+write,
// small line cache, no forced-miss-on-write -- see header for why this mirrors A rather
// than B's convention.
wire       fetch_req_c = (RAM_C_RD_n || !last_valid[2] || last_a[2] != RAM_C_ADDR[24:2]);

// access manager
always @(posedge clk) begin
	reg old_ref;
	reg        old_b_req;
	reg        old_a_req;
	reg        old_c_req;
	reg [31:0] last_data[3];
	reg [15:0] data_reg;
	reg        ch0_busy;
	reg        ch1_busy;
	reg        ch2_busy;
	reg  [3:0] store;
	// PCE PORT (2026-08-28): line-refill's own one-shot deferred capture for word3 --
	// same idiom as `store`, see the STATE_READY2 handling below.
	reg        store_lr;

	data_reg <= SDRAM_DQ;

	if(~&rfsh_cnt) rfsh_cnt <= rfsh_cnt + 1'd1;

	// PCE PORT (2026-08-27): the free/no-WAIT path on a port-A cache hit (the old
	// `else RAM_A_DO <= last_data[0][...]` branch) is a real, hardware-independent
	// deadlock, not a hypothetical -- confirmed by simulating the exact byte sequence
	// vram0_cache.vhd issues against this file. A 16-bit VRAM0 refill's second byte is
	// ALWAYS a hit on the tag last_a[0] just set by the first byte (same [20:2] address,
	// differing only in bit 0), so the very first refill after reset takes this path
	// (rfsh_cnt is not yet saturated post-init) and RAM_A_WAIT never rises for that
	// access. vram0_cache.vhd's own refill sequencer (SEQ_WAIT_LO_HI/SEQ_WAIT_HI_HI)
	// blocks unconditionally on ram_a_wait='1' while holding ram_a_req high, with no
	// other way to advance -- a permanent hang, not a stall. Now asserts RAM_A_WAIT
	// unconditionally on every REQ edge; the STATE_IDLE launch's existing `|| RAM_A_WAIT`
	// term (below) then runs the real state machine even on a hit (with ram_req=0, so
	// no real SDRAM command is issued -- just the handshake round trip vram0_cache.vhd
	// already expects). Cost: a hit that was free is now a full ~75ns transaction, so a
	// 16-bit refill goes from one real bus transaction to two -- this makes the
	// already-real, already-flagged VRAM0 deadline-miss problem (see docs/
	// ARCHITECTURE.md) numerically worse, not better. Deliberate: a hang is worse than
	// a late/wrong pixel, and the deadline-miss problem needs a real redesign (prefetch)
	// regardless of this fix -- see docs/ARCHITECTURE.md's VRAM0 section for the
	// separate, not-yet-started follow-up.
	old_a_req <= RAM_A_REQ;
	if(~old_a_req & RAM_A_REQ) begin
		RAM_A_WAIT <= 1;
	end

	// PCE PORT: !RAM_B_WE added -- a write must never be served from the cache, it has to
	// reach real SDRAM (last_data is not updated by a write, so a "hit" here would just
	// hand back stale pre-write data on the very next read).
	// PCE PORT (2026-08-29): widened alongside last_a/RAM_B_ADDR -- see last_a's own
	// declaration comment for why this tag must cover the full address, not just [20:2].
	if(!RAM_B_WE && (old_b_req ^ RAM_B_REQ) && last_valid[1] && (last_a[1] == RAM_B_ADDR[24:2])) begin
		old_b_req <= RAM_B_REQ;
		RAM_B_DO <= last_data[1][(RAM_B_ADDR[1:0]*8) +:8];
		// PCE PORT (2026-09-06): REAL DEADLOCK FIX, found on Console 60K hardware.
		// RAM_B_WAIT is set by the miss branch below and cleared ONLY on the ch1_busy
		// completion further down. This hit branch consumes `old_b_req` -- which IS the
		// pending-request flag the STATE_IDLE launch checks -- so if it ever fires while
		// a miss raised by the branch below is still pending, that request is swallowed:
		// nothing is launched, ch1_busy is never set, and RAM_B_WAIT stays high FOREVER
		// with no transaction outstanding. The board's ROM read bridge then sits in
		// RB_WAIT holding pce_top's WAIT_N low, and the HuC6280 freezes mid-fetch.
		// Observed exactly that way: 30 consecutive trace heartbeats with
		// rd_state=RB_WAIT, romb_wait=1, rom_rdy=0, and the VDC write count frozen at 9
		// while video timing kept running -- a black screen WITH sync.
		// Clearing WAIT here is correct and unconditional: reaching this branch means
		// this request is being answered right now from the cache, so by definition
		// nothing is outstanding for port B any more.
		RAM_B_WAIT <= 0;
	end
	// PCE PORT: miss branch, mirrors RAM_A_WAIT's edge-detect above. old_b_req is left
	// unchanged here (same as the original) so the mismatch persists as the pending-
	// request flag the STATE_IDLE launch below checks; WAIT clears on completion.
	else if((old_b_req ^ RAM_B_REQ) && fetch_req_b) begin
		RAM_B_WAIT <= 1;
	end

	// PCE PORT: third client (CD-RAM), mirrors RAM_A_WAIT's edge-detect exactly.
	// PCE PORT (2026-08-30): RAM_C_WIDE forces the free-hit fast path off entirely, same
	// as port A's own real fix -- see RAM_A_WAIT's declaration-site comment above for the
	// exact deadlock this prevents (a 16-bit refill's 2nd byte always tag-hits the 1st
	// byte's just-set tag; a wide caller's own sequencer blocks unconditionally on WAIT='1'
	// with no other way to advance, so WAIT must never stay low on a wide access). CD-RAM
	// (RAM_C_WIDE=0, the default) is completely unaffected -- byte-identical fast path.
	old_c_req <= RAM_C_REQ;
	if(~old_c_req & RAM_C_REQ) begin
		if(RAM_C_WIDE) RAM_C_WAIT <= 1;
		else if(fetch_req_c) RAM_C_WAIT <= 1;
		else RAM_C_DO <= last_data[2][(RAM_C_ADDR[1:0]*8) +:8];
	end

	if(state == STATE_IDLE && mode == MODE_NORMAL) begin
		ram_req <= 0;
		we <= 0;
		ch0_busy <= 0;
		ch1_busy <= 0;
		ch2_busy <= 0;
		// PCE PORT (2026-08-28): reset every idle cycle, alongside we/ch0_busy/etc --
		// mirrors their own pattern exactly, so a line-refill flag can never leak into a
		// later B/C/refresh transaction that doesn't override it below (state cannot
		// reach STATE_CONT2/READY2/LAST_LR at all unless this is '1', so this reset is
		// what makes those states provably unreachable outside a real line refill).
		line_refill <= 1'b0;
		// PCE PORT (2026-08-30): reset alongside line_refill -- meaningless whenever
		// line_refill is 0 (the IDLE default), but resetting it here means only C's own
		// launch (the one case that needs '1') has to touch it at all; A's launch relies
		// on this default, same as it already relies on ch0_busy/etc's own IDLE reset.
		lr_is_c <= 1'b0;

		// PCE PORT (2026-08-27): refresh checked FIRST, ahead of all three clients --
		// see header's refresh-first note for the real starvation bug this avoids.
		if(&rfsh_cnt) begin
			rfsh_cnt <= 0;
			state <= STATE_START;
		end
		// PCE PORT: A (VRAM0, zero wait-tolerance) now goes before B (ROM, tolerant via
		// pce_top.vhd's ROM_RDY -> WAIT_N) -- see header. Same launch logic as before,
		// just reordered.
		else if((~old_a_req && RAM_A_REQ && (fetch_req || rfsh_cnt[8])) || RAM_A_WAIT) begin
			we <= RAM_A_RD_n;
			// PCE PORT (2026-08-28): line-refill address forced to the line's own word0
			// (see header) -- both the launch latch AND last_a[0]'s own tag, so the
			// low-level 2-word opportunistic cache can never mistag a word0/word1 fetch
			// as a word2/word3 one (see RAM_A_ADDR_LINE_MASKED's declaration comment).
			// PCE PORT (2026-08-29): no more `2'b00,` bank-force prefix here -- see
			// RAM_A_ADDR_LINE_MASKED's own comment. It's now full-width and carries the
			// real bank bits verbatim, so this is a plain width-matched mux, not a
			// bank-0-hardwiring one.
			{bank,a} <= RAM_A_LINE_REFILL ? RAM_A_ADDR_LINE_MASKED : RAM_A_ADDR;
			data <= RAM_A_DI;                  // PCE PORT: real 16-bit word, no replication
			wide_acc <= 1'b1;                  // PCE PORT: see wide_acc declaration
			// PCE PORT (2026-08-28): a line refill always performs a REAL SDRAM access,
			// never the free-hit path -- last_data0_ext (words 2/3) has no tag/valid
			// tracking of its own, so a coincidental hit on the low-level word0/word1
			// cache would return stale/unrelated data for words 2/3. Cheap, safe: real
			// line-refill callers only ever request this on a genuine miss anyway.
			ram_req <= RAM_A_LINE_REFILL ? 1'b1 : fetch_req;
			last_a[0] <= RAM_A_LINE_REFILL ? RAM_A_ADDR_LINE_MASKED[24:2] : RAM_A_ADDR[24:2];
			last_valid[0] <= ~RAM_A_RD_n;
			ch0_busy <= 1;
			line_refill <= RAM_A_LINE_REFILL;
			state <= STATE_START;
		end
		else if((old_b_req ^ RAM_B_REQ) && fetch_req_b) begin
			old_b_req <= RAM_B_REQ;
			we <= RAM_B_WE;                    // PCE PORT: was implicitly 0 (B was read-only)
			{bank,a} <= RAM_B_ADDR;
			data <= {RAM_B_DI,RAM_B_DI};        // PCE PORT: write data, only used when RAM_B_WE
			wide_acc <= 1'b0;                  // PCE PORT: port B stays byte-granular
			ram_req <= 1;
			last_a[1] <= RAM_B_ADDR[24:2];
			last_valid[1] <= 1'b1;
			ch1_busy <= 1;
			state <= STATE_START;
		end
		// PCE PORT: third client, lowest priority among the three (after refresh, A, and
		// B) -- CD-RAM traffic is real-time (CPU-stalling via CD_RAM_RDY -> WAIT_N) but
		// less latency-sensitive than VRAM0 (A) and expected to be less frequent than ROM
		// fetch (B). Refresh now preempts all three -- see header's refresh-first note.
		else if((~old_c_req && RAM_C_REQ && fetch_req_c) || RAM_C_WAIT) begin
			we <= RAM_C_RD_n;
			// PCE PORT (2026-08-30): RAM_C_WIDE/RAM_C_LINE_REFILL additions -- mirrors
			// port A's own launch branch exactly (RAM_C_ADDR_LINE_MASKED, wide_acc,
			// line_refill, ram_req's real-access-vs-fake-round-trip choice). `lr_is_c`
			// records this launch was C's, for STATE_LAST_LR's completion routing below.
			// CD-RAM (RAM_C_WIDE=0, RAM_C_LINE_REFILL=0, both default) takes the exact
			// same values the old byte-granular code always used -- byte-identical.
			{bank,a} <= RAM_C_LINE_REFILL ? RAM_C_ADDR_LINE_MASKED : RAM_C_ADDR;
			data <= RAM_C_WIDE ? RAM_C_DI16 : {RAM_C_DI,RAM_C_DI};
			wide_acc <= RAM_C_WIDE;
			ram_req <= RAM_C_LINE_REFILL ? 1'b1 : fetch_req_c;
			last_a[2] <= RAM_C_LINE_REFILL ? RAM_C_ADDR_LINE_MASKED[24:2] : RAM_C_ADDR[24:2];
			last_valid[2] <= ~RAM_C_RD_n;
			ch2_busy <= 1;
			line_refill <= RAM_C_LINE_REFILL;
			lr_is_c <= 1'b1;
			state <= STATE_START;
		end
	end

	if(store) begin
		last_data[store[2:1]][(store[0] ? 16 : 0) +:16] <= data_reg;
		store <= 0;
	end

	if(state == STATE_READY) begin
		if(~ram_req) rfsh_cnt <= 0;
		if(ch0_busy) begin
			ch0_busy <= 0;
			// PCE PORT (2026-08-28): for a line refill, RAM_A_WAIT must NOT clear here --
			// words 2/3 (the 2nd back-to-back READ's own burst) haven't landed yet. It
			// clears instead at STATE_LAST_LR, below, once all 4 words are safe. Every
			// other access (the vast majority: writes, B/C-mirroring behaviour on port A,
			// non-line-refill reads) is completely unchanged -- WAIT still clears here,
			// same cycle as always.
			if(!line_refill) RAM_A_WAIT <= 0;
			if(ram_req) begin
				// PCE PORT (2026-08-27): port A is a real 16-bit word access now (see
				// wide_acc) -- no a[0] byte-select on either the write echo or the read.
				if(we) RAM_A_DO <= data;
				else begin
					RAM_A_DO <= data_reg;
					last_data[0][(a[1] ? 16 : 0) +:16] <= data_reg;
					store <= {1'b1,2'b00,~a[1]};
				end
			end
			else RAM_A_DO <= last_data[0][(a[1] ? 16 : 0) +:16];
		end
		if(ch1_busy) begin
			ch1_busy <= 0;
			RAM_B_WAIT <= 0;   // PCE PORT
			// PCE PORT: a write's data_reg readback does not reflect what was just written
			// (see header), so last_data[1] would go stale -- invalidate the line instead of
			// caching it, forcing the next read to really re-fetch from SDRAM.
			if(we) last_valid[1] <= 1'b0;
			else begin
				RAM_B_DO <= a[0] ? data_reg[15:8] : data_reg[7:0];
				last_data[1][(a[1] ? 16 : 0) +:16] <= data_reg;
				store <= {1'b1,2'b01,~a[1]};
			end
		end
		// PCE PORT: third client (CD-RAM), mirrors ch0_busy exactly -- real read+write
		// with a small line cache, same as port A (see header for why this doesn't use
		// port B's write-invalidates convention).
		// PCE PORT (2026-08-30): RAM_C_WIDE branch added throughout, mirroring ch0_busy's
		// own wide-vs-byte split exactly (RAM_C_DO16 <= full word, no a[0]/a[1:0] byte
		// select) -- CD-RAM's own RAM_C_WIDE=0 path is completely unchanged, same
		// expressions as before this port existed. `if(!line_refill)` on RAM_C_WAIT
		// mirrors ch0_busy's own line-refill guard -- words 2/3 of a wide line refill
		// haven't landed yet; it clears instead at STATE_LAST_LR below.
		if(ch2_busy) begin
			ch2_busy <= 0;
			if(!line_refill) RAM_C_WAIT <= 0;
			if(ram_req) begin
				if(we) begin
					if(wide_acc) RAM_C_DO16 <= data;
					else RAM_C_DO <= data[7:0];
				end else begin
					if(wide_acc) RAM_C_DO16 <= data_reg;
					else RAM_C_DO <= a[0] ? data_reg[15:8] : data_reg[7:0];
					last_data[2][(a[1] ? 16 : 0) +:16] <= data_reg;
					store <= {1'b1,2'b10,~a[1]};
				end
			end
			else begin
				if(wide_acc) RAM_C_DO16 <= last_data[2][(a[1] ? 16 : 0) +:16];
				else RAM_C_DO <= last_data[2][(a[1:0]*8) +:8];
			end
		end
	end

	// PCE PORT (2026-08-28): line-refill words 2/3 -- extends the SAME arm-then-consume
	// idiom `store` already uses for word1 (see its own site above), just re-triggered
	// exactly 2 clk_sdram cycles later, matching the 2nd READ's own 2-cycle-later
	// issuance (see the SDRAM state machines block below) so every downstream timing
	// event inherits the identical +2 offset the 1st READ's own events already have.
	// `line_refill` gates both terms; state cannot reach STATE_READY2/STATE_LAST_LR at
	// all unless it's set (STATE_LAST wrap stays at 9 for every other transaction --
	// see below), so this is defense-in-depth, not the only thing preventing this from
	// firing during a B/C/refresh/non-line-refill-A transaction.
	if(store_lr) begin
		last_data0_ext[31:16] <= data_reg;   // word3
		store_lr <= 1'b0;
	end
	if(line_refill && state == STATE_READY2) begin
		last_data0_ext[15:0] <= data_reg;    // word2
		store_lr <= 1'b1;
	end
	// PCE PORT (2026-08-30): routed by `lr_is_c` -- everything upstream of this point
	// (STATE_CONT2's 2nd READ reissue, last_data0_ext's word2/word3 capture) is already
	// channel-agnostic, keyed only on `line_refill`/state/mode, never on which port
	// launched it. This is the one place that was A-specific: which real destination
	// (RAM_A_LINE_DO/last_data[0] vs RAM_C_LINE_DO/last_data[2]) gets the completed line,
	// and which WAIT clears. CD-RAM never sets RAM_C_LINE_REFILL (defaults 0), so
	// line_refill can only be 1 here via A's own request or a real VRAM1/wide-C request --
	// lr_is_c disambiguates the two.
	if(line_refill && state == STATE_LAST_LR) begin
		if(lr_is_c) begin
			RAM_C_WAIT    <= 1'b0;
			RAM_C_LINE_DO <= {last_data0_ext, last_data[2]};
		end else begin
			RAM_A_WAIT    <= 1'b0;
			RAM_A_LINE_DO <= {last_data0_ext, last_data[0]};
		end
	end

	if(mode != MODE_NORMAL || state != STATE_IDLE || reset) begin
		state <= state + 1'd1;
		if(state == (line_refill ? STATE_LAST_LR : STATE_LAST)) state <= STATE_IDLE;
	end
end

localparam MODE_NORMAL = 2'b00;
localparam MODE_RESET  = 2'b01;
localparam MODE_LDM    = 2'b10;
localparam MODE_PRE    = 2'b11;

initial reset = 5'h1f;

// initialization 
reg [1:0] mode;
reg [4:0] reset=5'h1f;
always @(posedge clk) begin
	reg init_old=0;
	init_old <= init;

	if(init_old & ~init) reset <= 5'h1f;
	else if(state == STATE_LAST) begin
		if(reset != 0) begin
			reset <= reset - 5'd1;
			if(reset == 14)     mode <= MODE_PRE;
			else if(reset == 3) mode <= MODE_LDM;
			else                mode <= MODE_RESET;
		end
		else mode <= MODE_NORMAL;
	end
end

localparam CMD_NOP             = 3'b111;
localparam CMD_ACTIVE          = 3'b011;
localparam CMD_READ            = 3'b101;
localparam CMD_WRITE           = 3'b100;
localparam CMD_BURST_TERMINATE = 3'b110;
localparam CMD_PRECHARGE       = 3'b010;
localparam CMD_AUTO_REFRESH    = 3'b001;
localparam CMD_LOAD_MODE       = 3'b000;

// SDRAM state machines
always @(posedge clk) begin
	if(state == STATE_START) SDRAM_BA <= (mode == MODE_NORMAL) ? bank : 2'b00;

	dq_oe <= 1'b0;                                    // Gowin port: was SDRAM_DQ <= 'Z
	casex({ram_req,we,mode,state})
		{2'b1X, MODE_NORMAL, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_ACTIVE;
		// Gowin port: split from a single concatenated target so the data half drives
		// the tristate register instead of the port directly.
		{2'b11, MODE_NORMAL, STATE_CONT }: begin
		                                      {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_WRITE;
		                                      dq_out <= data;
		                                      dq_oe  <= 1'b1;
		                                   end
		{2'b10, MODE_NORMAL, STATE_CONT }: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_READ;
		{2'b0X, MODE_NORMAL, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_AUTO_REFRESH;

		// init
		{2'bXX,    MODE_LDM, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_LOAD_MODE;
		{2'bXX,    MODE_PRE, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRECHARGE;

		                          default: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_NOP;
	endcase

	// PCE PORT (2026-08-28): line-refill's 2nd back-to-back READ -- see header. Kept as
	// a trailing override rather than folded into the casex above (a NEW casex arm keyed
	// only on `state==STATE_CONT2` would ALSO match ordinary non-line-refill reads that
	// happen to pass through that same state value during their own STATE_CONT..
	// STATE_LAST run -- the casex's existing selector doesn't carry `line_refill`, and
	// widening it to do so would touch every other arm's bit positions for no reason).
	// Explicit `!we`: a line refill should never coincide with a write (vram0_cache.vhd
	// never asserts RAM_A_LINE_REFILL on a write-drain), kept as defense-in-depth.
	if(line_refill && ram_req && !we && mode == MODE_NORMAL && state == STATE_CONT2) begin
		{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_READ;
	end

	casex({ram_req,mode,state})
		{1'b1,  MODE_NORMAL, STATE_START}: SDRAM_A <= a[22:10];
		// PCE PORT (2026-08-27): wide_acc (port A only) forces both DQM lanes low on a
		// write -- a real 16-bit word write, not a byte-masked one. Ports B/C keep the
		// original a[0] byte-select unchanged.
		// PCE PORT (2026-08-28), REAL BUG FOUND AND FIXED: A10 (auto-precharge, the
		// fixed '2'b10' this arm used to assert unconditionally) must be SUPPRESSED on
		// a line refill's FIRST read -- asserting it here would auto-precharge (close)
		// the row before the 2nd READ at STATE_CONT2 can reach it, a real SDR SDRAM
		// protocol violation on real hardware (this project's own scratch Verilator
		// model never caught it: it computes read data as a pure function of row/
		// column and has no physical row-close side effect to violate -- found by
		// re-deriving the Nano 20K counterpart of this mechanism from sdram32.sv's own
		// address generation, which auto-precharges on every read and needed the
		// identical fix, then re-checking this file against the same question).
		// `line_refill & !we` mirrors the STATE_CONT2 arm's own predicate below exactly
		// (line_refill is never combined with a write by design -- vram0_cache.vhd
		// never asserts it on a write-drain -- but checking `!we` here too, not just
		// `line_refill`, closes the same class of currently-unreachable-but-real gap a
		// reviewer would otherwise flag, matching sdram32.sv's own fix). Ordinary
		// reads/writes (line_refill='0', the vast majority of all traffic) are
		// byte-for-byte unchanged: A10 stays asserted exactly as before.
		{1'b1,  MODE_NORMAL, STATE_CONT }: SDRAM_A <= {(we & ~a[0]) & ~wide_acc, (we & a[0]) & ~wide_acc, ((line_refill & !we) ? 2'b00 : 2'b10), a[9:1]};

		// init
		{1'bX,     MODE_LDM, STATE_START}: SDRAM_A <= MODE;
		{1'bX,     MODE_PRE, STATE_START}: SDRAM_A <= 13'b0010000000000;

		                          default: SDRAM_A <= 13'b0000000000000;
	endcase

	// PCE PORT (2026-08-28): line-refill's 2nd READ column = 1st READ's column + 2 words
	// (the SAME row/bank, already open -- see header). DQM bits forced 0 (unmasked),
	// matching the existing STATE_CONT arm's own read-side value (`we`=0 there always
	// zeroes both DQM terms already); A10/A9 bits ('10') copied verbatim from that same
	// arm. Mirrors, does not duplicate, the existing read column's own expression.
	if(line_refill && ram_req && !we && mode == MODE_NORMAL && state == STATE_CONT2) begin
		SDRAM_A <= {2'b00, 2'b10, (a[9:1] + 9'd2)};
	end
end


// Gowin port: the Altera altddio_out that forwarded the clock to the SDRAM pin
// becomes an ODDR. Same trick -- a DDR output fed 0 on the rising half and 1 on the
// falling half reproduces the clock at the pin with the output register's delay,
// rather than routing a clock through fabric.
ODDR sdramclk_ddr (
	.Q0 (SDRAM_CLK),
	.Q1 (),
	.D0 (1'b0),
	.D1 (1'b1),
	.TX (1'b0),
	.CLK(clk)
);

endmodule
