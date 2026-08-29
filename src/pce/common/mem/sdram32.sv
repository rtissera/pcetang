// SPDX-License-Identifier: GPL-3.0-or-later

//============================================================================
//
//  32-bit SDRAM controller for the ZX Spectrum Next core.
//
//  Derived from ZXNext_MISTer rtl/mister/sdram.sv, Copyright (C) 2021 Alexey Melnikov,
//  GPL-2.0-or-later. The arbitration is his: port A is the CPU/DMA read-write channel and
//  drives RAM_A_WAIT into the core's CPU_WAIT, port B is layer 2's read-only channel, and
//  each keeps a 4-byte cache line so most accesses never reach the chip.
//
//  This variant targets the Tang Nano 20K's on-package SDRAM: 32 bits wide, 11-bit
//  address, 4 byte-enables, against the 16-bit / 13-bit / 2 module the GW5A boards use.
//  Two consequences beyond the pin widths:
//
//    - One access now returns the whole 4-byte cache line, so the two-halves `store`
//      machinery of the 16-bit original is gone. It reads simpler than its ancestor.
//    - The original smuggled the byte selects through SDRAM_A[12:11]. An 11-bit address
//      bus has no spare lines, so DQM is driven explicitly.
//
//  Address map, for the 2 MB the Next needs out of the 8 MB die:
//    byte address [20:0] -> word [18:0] = addr[20:2]
//    column = word[7:0]   row = word[18:8]   bank = 0
//    2048 rows x 256 columns x 4 bytes = 2 MB in bank 0.
//
//  Verified on a Tang Nano 20K at 140 MHz by (in the ZX Next port) src/boards/
//  tang_nano20k/bringup/nano20k_diag: 256 sequential byte writes read back byte-exact,
//  and -- the case that actually caught a bug -- 256 byte writes each read back
//  immediately at the address just written, which is the pattern a Z80 stack makes and
//  the one every earlier test missed.
//
//  Copied into this port (PC Engine/SGX/TG16, GPL-3.0-or-later) from
//  ../TangNano60K/src/common/mem/sdram32.sv, same author, same board -- see
//  THIRD_PARTY_LICENSES.md. Clocked from clk_sdram (135 MHz, tapped off the HDMI rPLL
//  rather than the 140.4 MHz this file was tuned against) in this port; see
//  src/common/pll/nano20k_pll.vhd and NECTang's docs/PORTING.md for why, and re-check SAMPLE_SKEW
//  against a real timing report before trusting it at that different rate.
//
//  PCE PORT: no longer byte-identical to the ZX Next original. Two changes, both marked
//  "PCE PORT" at the site:
//    - Port A carries VRAM0 here (needs writes and real wait-state feedback -- the VDC has
//      no tolerance for a late response, see NECTang's docs/PORTING.md's "Nano 20K external memory"
//      design consult). Port B carries cartridge ROM -- read side is latency-tolerant via
//      pce_top.vhd's existing ROM_RDY -> WAIT_N path; write side (added 2026-08-30, see
//      RAM_B_WE/RAM_B_DI) is the board-level ROM-load bridge writing a HuCard dump in at
//      boot, also tolerant (iosys_bl616's own rom_do_valid handshake already waits).
//      Arbitration priority swapped so A (VRAM, zero tolerance) beats B (ROM, tolerant) --
//      the ZX Next original gave B priority because ITS port B was the latency-sensitive
//      one (Layer 2 video fetch); that reasoning still applies here, just to the other port.
//    - Added RAM_B_WAIT (the original has no completion signal on port B at all -- callers
//      there implicitly assumed a fixed latency). The board-level adapter that turns
//      RAM_B_WAIT into pce_top.vhd's ROM_RDY needs a real one now that B can genuinely miss.
//    - Added RAM_B_WE/RAM_B_DI (2026-08-30): port B was read-only until now (ROM lived
//      on-chip). Real HuCard ROMs are >=128K -- too big for on-chip BRAM once the rest of
//      pce_top is already fitted -- so ROM moves to this chip's own SDRAM instead, same
//      pattern as sdram.sv's port B on the GW5A boards (pcetang_primer25k.vhd's ROM
//      bridge is the reference this was copied from). No address widening needed: this
//      board's whole chip is 2 MB (see the address-map note above), VRAM0 (port A) uses
//      well under 128K of it (real PC Engine VRAM is 64K), so ROM fits in the SAME 2 MB at
//      a different offset -- unlike the GW5A boards' CD-RAM/ADPCM/Arcade-Card widening,
//      this stays inside the existing 21-bit address bus entirely.
//
//  Part of the PC Engine / SGX / TG16 port to Sipeed Tang boards. GPLv3.
//
//  PCE PORT (2026-08-28): "line refill" -- 4-word VRAM0 cache-line refill for port A,
//  the Nano 20K counterpart of the mechanism already shipped on Primer 25K's sdram.sv
//  (see that file's own "line refill" header note and
//  scratchpad/vram0_deadline_implementation_plans.md option (c)). vram0_cache.vhd's own
//  cache line is 4 PCE (16-bit) words = 8 bytes; THIS controller's native "word" is
//  already the 4-byte SDRAM access (word_a) -- confirmed from source, not assumed:
//  vram0_cache.vhd:749 drives `ram_a_addr <= "00000" & seq_addr & '0'` (byte address =
//  seq_addr*2, same convention sdram.sv relies on), and word_a = a_addr_d[20:2] drops
//  RAM_A_ADDR's bit 1 (the half-word select, byte_a[1]) as well as bit 0 -- so ONE line
//  is exactly TWO back-to-back word_a fetches (word_a, word_a+1), not four. A line's own
//  base word_a (seq_addr(1:0)="00") is always EVEN, and its own +1 covers the line's
//  other half without ever crossing the column->row boundary (an even base's column is
//  <=254, +1<=255, both inside the 8-bit column field -- the row field never changes).
//  BURST_LENGTH/ACCESS_TYPE/the mode register are completely untouched -- this issues a
//  SECOND ordinary single-beat (BURST_LENGTH=0) READ command to the SAME already-open
//  row, not a burst-length or mode-register change.
//
//  Real, load-bearing correction versus a naive port of sdram.sv's own two-burst scheme
//  (found from reading THIS file's own address generation, not assumed to carry over):
//  this controller issues auto-precharge (SDRAM_A[10]=1) on EVERY read today, since it
//  normally never keeps a row open across transactions -- each STATE_IDLE->STATE_LAST
//  run is a fresh ACTIVE+READ+auto-precharge, single-shot. For a line refill the row
//  MUST stay open between the two back-to-back reads, so the FIRST read's auto-precharge
//  bit is suppressed (SDRAM_A[10]=0, gated on `line_refill && !we` -- see the address-
//  generation block's own comment for why the !we term is load-bearing, not decorative)
//  and only the SECOND (last) read closes the row as normal -- see the address-generation
//  block below. Getting this backwards would have the bank start closing after read 1,
//  corrupting read 2's data on
//  real hardware in a way no behavioral model would catch unless it explicitly tracks
//  row-open state (this file's own testbench does, specifically to catch this class of
//  bug -- see scratchpad/nano20k_line_refill_verification.md).
//
//  RAM_A_LINE_REFILL is sampled through the SAME one-cycle a_addr_d-style pipeline
//  register as RAM_A_ADDR/RAM_A_RD_n/RAM_A_DI (line_refill_d, declared below), not used
//  directly at the launch decision -- this file's own real-hardware fix (see a_addr_d's
//  own comment above) already established that mixing an unregistered control signal
//  into the SAME launch decision as the registered address bundle reintroduces the exact
//  skew/hazard that fix exists to prevent. vram0_cache.vhd holds RAM_A_LINE_REFILL
//  steady for the whole REQ/WAIT round trip (same convention as ram_a_req itself), so
//  the extra cycle of registration costs nothing.
//
//  RAM_A_ADDR's word-within-line bits are forced to 0 for BOTH the launch address latch
//  AND last_a[0]'s own tag (mirrors sdram.sv's own masking correction) -- word_a/byte_a
//  are set from the masked address, not the exact missed word, so the line is always
//  fetched in fixed order word0,word1 (from word_a) then word2,word3 (from word_a+1),
//  never starting mid-line.
//
//  A line refill always forces a real SDRAM access (never the free-hit path below) --
//  last_data0_ext (words 2/3) has no tag/valid tracking of its own, so a coincidental
//  hit on the low-level 2-word cache (last_data[0]/last_valid[0]) would hand back stale,
//  unrelated data for words 2/3 specifically.
//
//============================================================================

module sdram32
#(
	// Cycles after CAS at which the read data is taken off the pins. Correct only for a
	// given clock: the die's data valid window is fixed in nanoseconds, our sampling edges
	// are not. 3 for 140.4 MHz, 2 for 70.
	parameter SAMPLE_SKEW = 3
)
(
	input             clk,
	input             init,

	output reg [10:0] SDRAM_A,
	inout      [31:0] SDRAM_DQ,
	output reg  [1:0] SDRAM_BA,
	output reg  [3:0] SDRAM_DQM,
	output reg        SDRAM_nWE,
	output reg        SDRAM_nCAS,
	output reg        SDRAM_nRAS,
	output            SDRAM_nCS,
	output            SDRAM_CKE,
	output            SDRAM_CLK,

	input      [20:0] RAM_A_ADDR,
	input             RAM_A_REQ,
	input             RAM_A_RD_n,
	// PCE PORT (2026-08-27): widened 8->16 bits, mirroring sdram.sv's port A width fix --
	// see that file's header. Port A here is read-only-shared with no port B write path,
	// so unlike sdram.sv this needs no wide_acc flag: dqm_w/data below are only ever set
	// by port A's own launch branch.
	input      [15:0] RAM_A_DI,
	output reg [15:0] RAM_A_DO,
	output reg        RAM_A_WAIT,
	// PCE PORT (2026-08-28): 4-word cache-line refill for VRAM0 -- see header's "line
	// refill" note. Sampled through line_refill_d exactly like RAM_A_RD_n/RAM_A_ADDR;
	// held by the caller for the whole 4-word request, but only the launch-time value
	// matters here. Never combined with a write (vram0_cache.vhd only asserts this on a
	// genuine read-miss refill, never a write-drain).
	input             RAM_A_LINE_REFILL = 1'b0,
	// PCE PORT (2026-08-28): all 4 words of a completed line refill, valid (and stable
	// until the NEXT line-refill transaction) from the same cycle RAM_A_WAIT falls for
	// that transaction. {word3,word2,word1,word0}. RAM_A_DO itself is unchanged (still
	// just the originally-addressed word, 16 bits) for compatibility with every other
	// caller of this port.
	output reg [63:0] RAM_A_LINE_DO,

	input      [20:0] RAM_B_ADDR,
	input             RAM_B_REQ,
	// PCE PORT (2026-08-30): port B write support, for the ROM-load bridge -- this
	// board's on-package chip is only 2 MB total, of which VRAM0 (port A) uses well
	// under 128K (real PC Engine VRAM is 64K), so ROM lives in the SAME 2 MB at a
	// different offset (ROM_SDRAM_BASE in pcetang_nano20k.vhd), same pattern as
	// sdram.sv's port B on the GW5A boards -- no address widening needed here, this
	// stays inside the existing 21-bit/2MB space. Active-high (not RD_n like port A --
	// port B never needed a read/write distinction before this).
	input             RAM_B_WE,
	input      [7:0]  RAM_B_DI,
	output reg  [7:0] RAM_B_DO,
	output reg        RAM_B_WAIT      // PCE PORT: absent in the ZX Next original, see header
);

assign SDRAM_nCS = 0;
assign SDRAM_CKE = 1;

// 140.4 MHz on this board: 7.12 ns a cycle, so tRCD=18ns needs 3 and the die wants CL3.
localparam RASCAS_DELAY   = 3'd3;
localparam BURST_LENGTH   = 3'b000;   // 1 word -- the word IS the cache line here
localparam ACCESS_TYPE    = 1'd0;     // 0=sequential
localparam CAS_LATENCY    = 3'd3;
localparam OP_MODE        = 2'd0;
localparam NO_WRITE_BURST = 1'd1;     // single-access writes

// 11 address lines: A10 reserved, A9 write burst, A8:A7 op mode, A6:A4 CAS,
// A3 burst type, A2:A0 burst length.
localparam [10:0] MODE = {1'b0, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};

localparam STATE_IDLE  = 4'd0;
localparam STATE_START = STATE_IDLE + 1'd1;
localparam STATE_CONT  = STATE_START + RASCAS_DELAY;

// When the read data is latched out of data_reg, and the whole reason this controller
// corrupted memory at 140 MHz.
//
// data_reg samples the DQ pins every cycle, so using it during state N means taking the
// bus as it stood at the edge *into* state N. Work the round trip through in real time,
// with our clock edges at 7.122 ns intervals and the die's at our falling edges because
// the forwarded clock is inverted:
//
//   READ appears on the pins at the start of state 5; the die clocks it in 3.56 ns later
//   CL3 -> the die drives data three of its edges after that, plus tAC to reach our pins
//
// That lands the data valid window a nanosecond or two AFTER the edge into state 9, which
// is where +2 sampled it. The bus is mid-transition at that instant: bits that swing fast
// arrive, bits that swing slow read back as whatever the floating bus had decayed to.
// Which is exactly the fault seen -- the value read back was always a SUBSET of the bits
// written, never a foreign value:
//
//   expected  A5 A4 A7 A6 A1 A0 A3 A2 AD AC AF AE A9 A8 AB AA
//   got       A5 84 A7 26 A1 80 A3 22 AD 08 AF AE A9 A8 AB AA
//
// Halving the clock to 70 MHz made the same test byte-exact, which is what pinned it to
// interface timing rather than logic: nothing constrains these pins, there is no
// set_input_delay or set_output_delay on any of them, so the tool never analysed the path.
// Sampling one cycle later costs 7.1 ns per access and puts the edge inside the window.
localparam STATE_READY = STATE_CONT + CAS_LATENCY + SAMPLE_SKEW;

// The cycle the machine returns to idle on, which is what gates the NEXT access.
//
// Reads are done at STATE_READY. Writes are not: this controller writes with auto-precharge
// (A10 high during CAS), so after the write data the die still needs tWR before it may
// precharge, then tRP before the next ACTIVE. The +3 was added when short write recovery
// was the leading theory for the corruption above; it made no difference to the result and
// so was not the cause. Kept anyway -- it is three idle cycles on a path that has no
// timing constraint at all, and the fault that did explain the corruption was on that same
// unanalysed interface.
localparam STATE_LAST  = STATE_READY + 3'd3;

// PCE PORT (2026-08-28): line-refill extension -- see header's "line refill" note. A
// 4-word line refill issues a SECOND back-to-back single-beat READ, to the SAME
// already-open row, exactly 1 clk_sdram cycle after the first (STATE_CONT2 =
// STATE_CONT+1) -- real SDR SDRAM CCD (column-to-column delay) for BURST_LENGTH=0 is 1
// clock, fixed, not clock-period-dependent (unlike RASCAS_DELAY/tRCD), so this does not
// need to scale with SAMPLE_SKEW the way that constant does. STATE_READY2/STATE_LAST_LR
// mirror STATE_READY/STATE_LAST, offset by that same +1, since every downstream timing
// event of the 2nd READ inherits its +1 offset from the 1st (its own CAS_LATENCY+
// SAMPLE_SKEW is identical to the 1st read's). STATE_LAST_LR keeps the SAME +3 idle-cycle
// margin after read 2's own STATE_READY2 that STATE_LAST already keeps after every
// ordinary single read's STATE_READY -- read 2 is, from the chip's point of view, an
// ordinary read (it's the one that auto-precharges, see header), so it needs the same
// post-read margin before the next ACTIVE that any other read already gets, not a novel
// smaller one. (Real GHDL/Verilator confirmation that a smaller pad already suffices
// FUNCTIONALLY, and that this one is not required for correctness but is kept for
// margin-parity, is in scratchpad/nano20k_line_refill_verification.md.) The 4-bit state
// counter (max 15) comfortably covers STATE_LAST_LR=14 -- no widening needed.
localparam STATE_CONT2   = STATE_CONT + 3'd1;
localparam STATE_READY2  = STATE_READY + 3'd1;
localparam STATE_LAST_LR = STATE_READY2 + 3'd3;

reg  [3:0] state;
reg [18:0] word_a;                    // word address of the access in flight
reg  [1:0] byte_a;                    // byte within that word
reg [31:0] data;                      // write data, byte replicated across all lanes
reg  [3:0] dqm_w;                     // byte enable for writes
reg        we;
reg        ram_req = 0;
reg [18:0] last_a[2];                 // cached word address per channel
reg  [1:0] last_valid = 2'b00;        // and whether that cache line means anything
reg  [8:0] rfsh_cnt;

// PCE PORT (2026-08-28): line-refill state -- mirrors sdram.sv's own `line_refill`/
// `last_data0_ext` idiom. `line_refill` is reset every STATE_IDLE cycle alongside
// ram_req/we/ch0_busy/ch1_busy (see that reset block below), so a stale '1' can never
// leak into a later non-line-refill transaction -- every new state (CONT2/READY2/
// LAST_LR) is therefore provably unreachable outside a real line-refill transaction, not
// just unlikely to be reached. `last_data0_ext` holds words 2 and 3 of the line (word2 in
// [15:0], word3 in [31:16]), captured directly from data_reg at STATE_READY2 -- no
// two-stage deferred capture is needed here (unlike sdram.sv's `store`/`store_lr`), since
// this controller's own read data already arrives complete in ONE beat per READ command
// (BURST_LENGTH=0), not split across two beats of a burst-of-2.
reg        line_refill = 1'b0;
reg [31:0] last_data0_ext;            // words 2+3 of the line

reg [31:0] dq_out;
reg        dq_oe;
assign SDRAM_DQ = dq_oe ? dq_out : 32'bZ;

localparam MODE_NORMAL = 2'b00;
localparam MODE_RESET  = 2'b01;
localparam MODE_LDM    = 2'b10;
localparam MODE_PRE    = 2'b11;

// initialization
reg [1:0] mode;
reg [4:0] reset = 5'h1f;
always @(posedge clk) begin
	reg init_old = 0;
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


// A separate valid bit rather than stuffing last_a with all-ones on a write. The
// all-ones trick makes the 19-bit comparator drive the SET pins of the 19-bit register,
// and on GW2A that path measured 8.817 ns against the 7.122 ns a 140.4 MHz cycle allows
// (TNS -50.987 over 65 endpoints). Clearing one bit instead is the same behaviour with a
// far shorter path.
// The cache-hit comparison is registered rather than combinational. Feeding a 19-bit
// comparator straight into the clock enables of the transaction registers costs ~8.5 ns
// on GW2A, against 7.122 ns per 140.4 MHz cycle.
//
// The request is therefore delayed by one cycle to line up with it. An earlier version
// compared the current address against a hit computed from the previous one, arguing that
// the core holds RAM_A_ADDR steady for a whole 28 MHz cycle -- five of these -- so a
// one-cycle-old result described the same address. Hardware disagreed. A request whose
// address changes on the same edge as RAM_A_REQ returns the *previous* cache line:
// measured on a Tang Nano 20K as 252 of 256 bytes wrong, with alias markers written as
// AABBCCDD reading back AAAACCCC -- every second probe echoing the one before it.
//
// Aligning them costs one 140.4 MHz cycle of latency per access, 7.12 ns, inside a 35.6 ns
// CPU cycle.
reg [20:0] a_addr_d, b_addr_d;
reg        a_req_d, a_rd_n_d, b_req_d;
reg [15:0] a_di_d;
// PCE PORT (2026-08-30): port B write's own pipeline registers, same treatment as
// b_addr_d/b_req_d above.
reg        b_we_d;
reg  [7:0] b_di_d;
// PCE PORT (2026-08-28): line-refill's own pipeline register, same treatment as
// a_addr_d/a_rd_n_d/a_di_d above and for the same reason -- see RAM_A_LINE_REFILL's own
// port comment.
reg        line_refill_d;
reg hit_a, hit_b;
always @(posedge clk) begin
	a_addr_d <= RAM_A_ADDR;
	a_req_d  <= RAM_A_REQ;
	a_rd_n_d <= RAM_A_RD_n;
	a_di_d   <= RAM_A_DI;
	line_refill_d <= RAM_A_LINE_REFILL;
	b_addr_d <= RAM_B_ADDR;
	b_req_d  <= RAM_B_REQ;
	b_we_d   <= RAM_B_WE;
	b_di_d   <= RAM_B_DI;

	hit_a <= last_valid[0] && (last_a[0] == RAM_A_ADDR[20:2]);
	hit_b <= last_valid[1] && (last_a[1] == RAM_B_ADDR[20:2]);
end

wire fetch_req = (a_rd_n_d || !hit_a);
// PCE PORT (2026-08-30): a write must never take the free-hit path below (it would
// skip the real SDRAM access and cache the wrong thing) -- b_we_d gates it out here,
// same role a_rd_n_d already plays for port A's fetch_req.
wire fetch_req_b = (b_we_d || !hit_b);

// PCE PORT (2026-08-28): line-refill's launch address, masked to the line's own base
// word0 -- forces BOTH the word-select bit (RAM_A_ADDR[1], byte_a) and word_a's own LSB
// (RAM_A_ADDR[2]) to 0. Same masking formula as sdram.sv's RAM_A_ADDR_LINE_MASKED, since
// both controllers share vram0_cache.vhd's `RAM_A_ADDR = seq_addr*2` convention
// (confirmed at vram0_cache.vhd:749, not assumed).
wire [20:0] a_addr_d_line_masked = {a_addr_d[20:3], 3'b000};

// access manager
always @(posedge clk) begin
	reg        old_b_req;
	reg        old_a_req;
	reg [31:0] last_data[2];
	reg [31:0] data_reg;
	reg        ch0_busy;
	reg        ch1_busy;

	data_reg <= SDRAM_DQ;

	if(~&rfsh_cnt) rfsh_cnt <= rfsh_cnt + 1'd1;

	// PCE PORT (2026-08-27): same real deadlock as sdram.sv had (see that file's
	// STATE_IDLE header note) -- the free/no-WAIT cache-hit path here means a hit never
	// raises RAM_A_WAIT, and vram0_cache.vhd's refill sequencer blocks unconditionally on
	// ram_a_wait='1'. At this controller's 4-byte-aligned cache-line granularity, two
	// consecutive 16-bit-word fetches within the same 4-byte span alias to the same
	// last_a[0] -- i.e. every refill's second word, not just an occasional one -- so this
	// was live on every access, worse than sdram.sv's "first refill after reset" case.
	// Fixed the same way: RAM_A_WAIT now asserts unconditionally on every port-A REQ
	// edge; the STATE_IDLE launch's existing `|| RAM_A_WAIT` term runs the real state
	// machine even on a hit (ram_req=0, no real SDRAM command, just the handshake round
	// trip vram0_cache.vhd already expects).
	old_a_req <= a_req_d;
	if(~old_a_req & a_req_d) begin
		RAM_A_WAIT <= 1;
	end

	if((old_b_req ^ b_req_d) && !fetch_req_b) begin
		old_b_req <= b_req_d;
		RAM_B_DO <= last_data[1][(b_addr_d[1:0]*8) +:8];
	end
	// PCE PORT: miss/write branch, mirrors port A's RAM_A_WAIT<=1 above. old_b_req is
	// left unchanged here (same as the original) so the mismatch persists as the
	// pending-request flag the STATE_IDLE launch below checks; WAIT clears on
	// completion. fetch_req_b (2026-08-30) forces this branch, never the free-hit one
	// above, whenever b_we_d is set -- see fetch_req_b's own comment.
	else if((old_b_req ^ b_req_d) && fetch_req_b) begin
		RAM_B_WAIT <= 1;
	end

	if(state == STATE_IDLE && mode == MODE_NORMAL) begin
		ram_req  <= 0;
		we       <= 0;
		ch0_busy <= 0;
		ch1_busy <= 0;
		// PCE PORT (2026-08-28): reset every idle cycle, alongside ram_req/we/ch0_busy --
		// mirrors their own pattern exactly, so a line-refill flag can never leak into a
		// later transaction that doesn't override it below (state cannot reach
		// STATE_CONT2/READY2/LAST_LR at all unless this is '1', so this reset is what
		// makes those states provably unreachable outside a real line refill).
		line_refill <= 1'b0;

		// Refresh goes FIRST once its deadline is reached, ahead of both ports.
		//
		// It used to be the last else-if, so a port only had to stay busy to starve it
		// indefinitely -- and port B, the video fetch, does exactly that. Each access is
		// STATE_LAST cycles and B asks again every few, so through the ~18 ms of active
		// video in every 20 ms frame the machine never reaches STATE_IDLE with both ports
		// quiet, and not one AUTO REFRESH is issued. Rows need one every 7.8 us.
		//
		// That is invisible while the boot loader runs -- little video traffic, controller
		// mostly idle, refresh constant -- and fatal the moment NextZXOS starts fetching
		// for real. Which is precisely the reported symptom: every ROM loads and verifies,
		// then the machine drops to a grey screen with random bars, the classic look of a
		// Spectrum whose RAM has decayed under it.
		//
		// rfsh_cnt is 9 bits and saturates, so the deadline is 511 cycles = 3.65 us at
		// 140 MHz, inside the requirement with margin. Preempting costs the waiting port
		// one refresh cycle, about 78 ns.
		if(&rfsh_cnt) begin
			rfsh_cnt <= 0;
			state    <= STATE_START;
		end
		// PCE PORT: A (VRAM0, zero wait-tolerance) now goes before B (ROM, tolerant via
		// pce_top.vhd's ROM_RDY -> WAIT_N) -- see header. Same launch logic as before,
		// just reordered.
		else if((~old_a_req && a_req_d && (fetch_req || rfsh_cnt[8])) || RAM_A_WAIT) begin
			we        <= a_rd_n_d;
			// PCE PORT (2026-08-28): a line refill always requests the LINE's own base
			// word0 (see header) -- both word_a/byte_a AND last_a[0]'s own tag, so the
			// low-level 2-word opportunistic cache can never mistag a word0/word1 fetch
			// as a word2/word3 one.
			word_a    <= line_refill_d ? a_addr_d_line_masked[20:2] : a_addr_d[20:2];
			byte_a    <= line_refill_d ? 2'b00 : a_addr_d[1:0];
			// PCE PORT (2026-08-27): port A is a real 16-bit word now (see RAM_A_DI/DO
			// width note) -- writes both bytes of the addressed half, not one byte of
			// four. a_addr_d[0] is always 0 (word-aligned from vram0_cache.vhd); [1]
			// selects which half of the 4-byte SDRAM line.
			data      <= {2{a_di_d}};
			dqm_w     <= a_addr_d[1] ? 4'b0011 : 4'b1100;
			// PCE PORT (2026-08-28): a line refill always performs a REAL SDRAM access,
			// never the free-hit path -- last_data0_ext (words 2/3) has no tag/valid
			// tracking of its own, so a coincidental hit on the low-level word0/word1
			// cache would return stale/unrelated data for words 2/3 specifically.
			ram_req   <= line_refill_d ? 1'b1 : fetch_req;
			// A write invalidates the line rather than trying to patch it: the byte went
			// to the chip, and the cached copy would otherwise go stale.
			last_a[0]     <= line_refill_d ? a_addr_d_line_masked[20:2] : a_addr_d[20:2];
			last_valid[0] <= ~a_rd_n_d;
			ch0_busy  <= 1;
			line_refill <= line_refill_d;
			state     <= STATE_START;
		end
		else if((old_b_req ^ b_req_d) && fetch_req_b) begin
			old_b_req <= b_req_d;
			word_a    <= b_addr_d[20:2];
			byte_a    <= b_addr_d[1:0];
			// PCE PORT (2026-08-30): write support -- we/data/dqm_w are the SAME shared
			// registers port A's launch branch drives; safe to reuse since A and B
			// launches are mutually exclusive (this whole chain is one else-if), exactly
			// like ram_req/word_a/byte_a already are. Single-byte write: replicate across
			// all 4 lanes (matches port A's 16-bit replication for the same reason -- only
			// the DQM-selected lane(s) actually latch) and mask everything but byte_a's
			// own lane.
			we        <= b_we_d;
			data      <= {4{b_di_d}};
			dqm_w     <= ~(4'b0001 << b_addr_d[1:0]);
			ram_req   <= 1;
			last_a[1] <= b_addr_d[20:2];
			// A write invalidates the line rather than patching it -- same reasoning as
			// port A's last_valid[0] <= ~a_rd_n_d above.
			last_valid[1] <= ~b_we_d;
			ch1_busy  <= 1;
			state     <= STATE_START;
		end
	end

	if(state == STATE_READY) begin
		if(~ram_req) rfsh_cnt <= 0;
		if(ch0_busy) begin
			ch0_busy   <= 0;
			// PCE PORT (2026-08-28): for a line refill, RAM_A_WAIT must NOT clear here --
			// words 2/3 (the 2nd back-to-back READ's own beat) haven't landed yet. It
			// clears instead at STATE_LAST_LR, below, once all 4 words are safe. Every
			// other access (writes, ordinary non-line-refill reads) is completely
			// unchanged -- WAIT still clears here, same cycle as always.
			if(!line_refill) RAM_A_WAIT <= 0;
			if(ram_req) begin
				// PCE PORT (2026-08-27): 16-bit word select via byte_a[1] (which half of
				// the 4-byte line), not the old byte_a[1:0]*8 byte select.
				if(we) RAM_A_DO <= a_di_d;
				else begin
					RAM_A_DO       <= byte_a[1] ? data_reg[31:16] : data_reg[15:0];
					last_data[0]   <= data_reg;      // one access fills the whole line
				end
			end
			else RAM_A_DO <= byte_a[1] ? last_data[0][31:16] : last_data[0][15:0];
		end
		if(ch1_busy) begin
			ch1_busy     <= 0;
			RAM_B_WAIT   <= 0;   // PCE PORT
			// PCE PORT (2026-08-30): write case mirrors port A's own `if(we) RAM_A_DO <=
			// a_di_d` above -- data_reg holds whatever the DQ pins carried during a write
			// (our own driven data, not meaningful to read back), so RAM_B_DO/last_data[1]
			// must come from the input, not data_reg, when `we` is set.
			if(we) RAM_B_DO <= b_di_d;
			else begin
				RAM_B_DO     <= data_reg[(byte_a*8) +:8];
				last_data[1] <= data_reg;
			end
		end
	end

	// PCE PORT (2026-08-28): line-refill words 2/3 -- the 2nd back-to-back READ's own
	// single beat lands here, exactly STATE_CONT2-STATE_CONT (1) cycles after the 1st
	// read's own STATE_READY. `line_refill` gates both terms; state cannot reach
	// STATE_READY2/STATE_LAST_LR at all unless it's set (STATE_LAST wrap stays at 13 for
	// every other transaction -- see below), so this is defense-in-depth, not the only
	// thing preventing this from firing during a non-line-refill transaction.
	if(line_refill && state == STATE_READY2) begin
		last_data0_ext <= data_reg;          // words 2 (low) and 3 (high)
	end
	if(line_refill && state == STATE_LAST_LR) begin
		RAM_A_WAIT    <= 1'b0;
		RAM_A_LINE_DO <= {last_data0_ext, last_data[0]};
	end

	if(mode != MODE_NORMAL || state != STATE_IDLE || reset) begin
		state <= state + 1'd1;
		if(state == (line_refill ? STATE_LAST_LR : STATE_LAST)) state <= STATE_IDLE;
	end
end

localparam CMD_NOP             = 3'b111;
localparam CMD_ACTIVE          = 3'b011;
localparam CMD_READ            = 3'b101;
localparam CMD_WRITE           = 3'b100;
localparam CMD_PRECHARGE       = 3'b010;
localparam CMD_AUTO_REFRESH    = 3'b001;
localparam CMD_LOAD_MODE       = 3'b000;

wire [10:0] row = word_a[18:8];
wire  [7:0] col = word_a[7:0];

// PCE PORT (2026-08-28): line-refill's 2nd back-to-back READ launch condition. Read 1's
// A10 (auto-precharge) suppression below is gated on the LITERALLY IDENTICAL `line_refill
// && !we` term (not bare `line_refill`) specifically so these two predicates can never
// diverge -- see header's precharge-sequencing note for why divergence would be a real
// bug: a transaction that suppresses read 1's auto-precharge and then never issues read 2
// leaves the row open with nothing left to close it. (line_refill=1 with we=1 should be
// unreachable in real use -- vram0_cache.vhd only ever asserts RAM_A_LINE_REFILL on a
// genuine read-miss refill, never a write-drain -- but the predicates are kept literally
// matched rather than relying on that external guarantee, so this file's own invariant
// doesn't depend on a caller behaving correctly.) The additional ram_req/mode terms here
// are defense-in-depth (line_refill can only be set when mode==MODE_NORMAL at launch, and
// ram_req is not changed again until the next STATE_IDLE).
wire line_refill_2nd_read = line_refill && ram_req && !we && mode == MODE_NORMAL && state == STATE_CONT2;

// command and address generation
always @(posedge clk) begin
	if(state == STATE_START) SDRAM_BA <= 2'b00;   // the Next's 2 MB live in bank 0

	casex({ram_req,we,mode,state})
		{2'b1X, MODE_NORMAL, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_ACTIVE;
		{2'b11, MODE_NORMAL, STATE_CONT }: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_WRITE;
		{2'b10, MODE_NORMAL, STATE_CONT }: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_READ;
		{2'b0X, MODE_NORMAL, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_AUTO_REFRESH;

		// init
		{2'bXX,    MODE_LDM, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_LOAD_MODE;
		{2'bXX,    MODE_PRE, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRECHARGE;

		                          default: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_NOP;
	endcase

	// PCE PORT (2026-08-28): line-refill's 2nd back-to-back READ -- see header. Kept as
	// a trailing override rather than folded into the casex above (a NEW casex arm keyed
	// only on state==STATE_CONT2 would ALSO match any ordinary non-line-refill
	// transaction that happens to pass through that same state value during its own
	// STATE_CONT..STATE_LAST run -- the casex's own selector doesn't carry line_refill).
	if(line_refill_2nd_read) begin
		{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_READ;
	end

	casex({ram_req,mode,state})
		{1'b1,  MODE_NORMAL, STATE_START}: SDRAM_A <= row;
		// A10 high = auto precharge, A9:A8 unused, A7:A0 = column. PCE PORT (2026-08-28):
		// suppressed (A10=0) on a line refill's FIRST read only -- the row must stay open
		// for the 2nd read that follows at STATE_CONT2 (see header's precharge-sequencing
		// note). Every other read (the vast majority: ordinary non-line-refill accesses)
		// is unchanged, still auto-precharges here exactly as before.
		{1'b1,  MODE_NORMAL, STATE_CONT }: SDRAM_A <= {((line_refill && !we) ? 1'b0 : 1'b1), 2'b00, col};

		// init
		{1'bX,     MODE_LDM, STATE_START}: SDRAM_A <= MODE;
		{1'bX,     MODE_PRE, STATE_START}: SDRAM_A <= 11'b100_0000_0000;   // precharge all

		                          default: SDRAM_A <= 11'b000_0000_0000;
	endcase

	// PCE PORT (2026-08-28): line-refill's 2nd READ column = 1st read's own column + 1
	// (the SAME row/bank, already open -- see header; word_a's own even/odd pairing
	// guarantees this never crosses into the row field). This IS the last read of the
	// transaction, so unlike read 1 it auto-precharges normally (A10=1) to close the row
	// afterward -- mirrors, does not duplicate, the existing read column's own STATE_CONT
	// expression above.
	if(line_refill_2nd_read) begin
		SDRAM_A <= {1'b1, 2'b00, col + 8'd1};
	end
end

// Write data leaves half a cycle before everything else, and stays a cycle longer.
//
// The forwarded clock is inverted, so the die's sampling edge falls in the middle of our
// cycle -- 3.56 ns after we launch at 140 MHz. Commands survive that: eleven address lines
// and three strobes. Write data did not. A byte write replicates the byte across all four
// lanes, so storing 0x00 over a bus floating high swings all 32 pins at once, and the die
// latched only the bits that had settled: 0x00 written, 0xC0 read back, which is 0xFF with
// the low six bits taken and the top two not. That single lost byte was a stack push, so
// the boot ROM popped a corrupt loop counter and never got past its palette setup.
//
// Preparing the data one state early and passing it through a falling-edge register puts it
// on the pins from the middle of STATE_CONT, a full cycle before the die samples it in the
// middle of STATE_CONT+1. Holding it for two states rather than one keeps it there across
// that edge instead of changing on it, which would trade the setup problem for a hold one.
// Setup and hold both become 7.12 ns where setup was 3.56 and hold was zero.
reg [31:0] dq_pre;
reg        dq_oe_pre;
reg  [3:0] dqm_pre;
always @(posedge clk) begin
	if(ram_req && we && mode == MODE_NORMAL &&
	   (state == STATE_CONT - 4'd1 || state == STATE_CONT)) begin
		dq_pre    <= data;
		dq_oe_pre <= 1'b1;
		dqm_pre   <= dqm_w;
	end
	else begin
		dq_oe_pre <= 1'b0;
		dqm_pre   <= 4'b0000;
	end
end

always @(negedge clk) begin
	dq_out    <= dq_pre;
	dq_oe     <= dq_oe_pre;
	SDRAM_DQM <= dqm_pre;
end

// Clock to the die, forwarded through an output register rather than routed as a clock.
ODDR sdramclk_ddr (
	.Q0 (SDRAM_CLK),
	.Q1 (),
	.D0 (1'b0),
	.D1 (1'b1),
	.TX (1'b0),
	.CLK(clk)
);

endmodule
