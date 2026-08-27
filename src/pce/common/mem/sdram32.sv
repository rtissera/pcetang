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
//  src/common/pll/nano20k_pll.vhd and docs/PORTING.md for why, and re-check SAMPLE_SKEW
//  against a real timing report before trusting it at that different rate.
//
//  PCE PORT: no longer byte-identical to the ZX Next original. Two changes, both marked
//  "PCE PORT" at the site:
//    - Port A carries VRAM0 here (needs writes and real wait-state feedback -- the VDC has
//      no tolerance for a late response, see docs/PORTING.md's "Nano 20K external memory"
//      design consult). Port B carries cartridge ROM (read-only, already latency-tolerant
//      via pce_top.vhd's existing ROM_RDY -> WAIT_N path). Arbitration priority swapped so
//      A (VRAM, zero tolerance) beats B (ROM, tolerant) -- the ZX Next original gave B
//      priority because ITS port B was the latency-sensitive one (Layer 2 video fetch);
//      that reasoning still applies here, just to the other port.
//    - Added RAM_B_WAIT (the original has no completion signal on port B at all -- callers
//      there implicitly assumed a fixed latency). The board-level adapter that turns
//      RAM_B_WAIT into pce_top.vhd's ROM_RDY needs a real one now that B can genuinely miss.
//
//  Part of the PC Engine / SGX / TG16 port to Sipeed Tang boards. GPLv3.
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

	input      [20:0] RAM_B_ADDR,
	input             RAM_B_REQ,
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
reg hit_a, hit_b;
always @(posedge clk) begin
	a_addr_d <= RAM_A_ADDR;
	a_req_d  <= RAM_A_REQ;
	a_rd_n_d <= RAM_A_RD_n;
	a_di_d   <= RAM_A_DI;
	b_addr_d <= RAM_B_ADDR;
	b_req_d  <= RAM_B_REQ;

	hit_a <= last_valid[0] && (last_a[0] == RAM_A_ADDR[20:2]);
	hit_b <= last_valid[1] && (last_a[1] == RAM_B_ADDR[20:2]);
end

wire fetch_req = (a_rd_n_d || !hit_a);
wire fetch_req_b = !hit_b;   // PCE PORT: B is read-only, no rd_n term needed

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

	if((old_b_req ^ b_req_d) && hit_b) begin
		old_b_req <= b_req_d;
		RAM_B_DO <= last_data[1][(b_addr_d[1:0]*8) +:8];
	end
	// PCE PORT: miss branch, mirrors port A's RAM_A_WAIT<=1 above. old_b_req is left
	// unchanged here (same as the original) so the mismatch persists as the pending-
	// request flag the STATE_IDLE launch below checks; WAIT clears on completion.
	else if((old_b_req ^ b_req_d) && !hit_b) begin
		RAM_B_WAIT <= 1;
	end

	if(state == STATE_IDLE && mode == MODE_NORMAL) begin
		ram_req  <= 0;
		we       <= 0;
		ch0_busy <= 0;
		ch1_busy <= 0;

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
			word_a    <= a_addr_d[20:2];
			byte_a    <= a_addr_d[1:0];
			// PCE PORT (2026-08-27): port A is a real 16-bit word now (see RAM_A_DI/DO
			// width note) -- writes both bytes of the addressed half, not one byte of
			// four. a_addr_d[0] is always 0 (word-aligned from vram0_cache.vhd); [1]
			// selects which half of the 4-byte SDRAM line.
			data      <= {2{a_di_d}};
			dqm_w     <= a_addr_d[1] ? 4'b0011 : 4'b1100;
			ram_req   <= fetch_req;
			// A write invalidates the line rather than trying to patch it: the byte went
			// to the chip, and the cached copy would otherwise go stale.
			last_a[0]     <= a_addr_d[20:2];
			last_valid[0] <= ~a_rd_n_d;
			ch0_busy  <= 1;
			state     <= STATE_START;
		end
		else if((old_b_req ^ b_req_d) && !hit_b) begin
			old_b_req <= b_req_d;
			word_a    <= b_addr_d[20:2];
			byte_a    <= b_addr_d[1:0];
			ram_req   <= 1;
			last_a[1] <= b_addr_d[20:2];
			last_valid[1] <= 1'b1;
			ch1_busy  <= 1;
			state     <= STATE_START;
		end
	end

	if(state == STATE_READY) begin
		if(~ram_req) rfsh_cnt <= 0;
		if(ch0_busy) begin
			ch0_busy   <= 0;
			RAM_A_WAIT <= 0;
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
			RAM_B_DO     <= data_reg[(byte_a*8) +:8];
			last_data[1] <= data_reg;
		end
	end

	if(mode != MODE_NORMAL || state != STATE_IDLE || reset) begin
		state <= state + 1'd1;
		if(state == STATE_LAST) state <= STATE_IDLE;
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

	casex({ram_req,mode,state})
		{1'b1,  MODE_NORMAL, STATE_START}: SDRAM_A <= row;
		// A10 high = auto precharge, A9:A8 unused, A7:A0 = column
		{1'b1,  MODE_NORMAL, STATE_CONT }: SDRAM_A <= {1'b1, 2'b00, col};

		// init
		{1'bX,     MODE_LDM, STATE_START}: SDRAM_A <= MODE;
		{1'bX,     MODE_PRE, STATE_START}: SDRAM_A <= 11'b100_0000_0000;   // precharge all

		                          default: SDRAM_A <= 11'b000_0000_0000;
	endcase
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
