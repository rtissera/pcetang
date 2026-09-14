// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Romain Tisserand
//
// Behavioural SDR SDRAM model, just complete enough to exercise src/pce/common/mem/
// sdram.sv's controller: ACTIVE/READ/WRITE/PRECHARGE/REFRESH/LOAD MODE, CAS latency 3,
// burst length 2, single-access write (NO_WRITE_BURST=1). Matches the localparams at
// sdram.sv:256-262; if those change this must change with them.
//
// This is NOT a timing-accurate part model -- it does not check tRC/tRP/tRFC/tWR and it
// will not tell you the real chip is happy. It models the DATA path faithfully, which is
// the question under test: does the controller lose or misroute a write when three client
// ports contend? A model that silently returned X or 0 on an unwritten address would
// answer that question for us, so unwritten reads return a per-address poison pattern
// instead and the testbench treats poison as "never written".
`default_nettype none

module sdram_chip_model #(
	parameter CAS_LATENCY = 3,
	parameter BURST_LEN   = 2
) (
	input  wire        SDRAM_CLK,
	input  wire [12:0] SDRAM_A,
	input  wire  [1:0] SDRAM_BA,
	input  wire        SDRAM_nCS,
	input  wire        SDRAM_nRAS,
	input  wire        SDRAM_nCAS,
	input  wire        SDRAM_nWE,
	input  wire        SDRAM_DQML,
	input  wire        SDRAM_DQMH,
	inout  wire [15:0] SDRAM_DQ
);
	// 4 banks x 8192 rows x 512 cols of 16 bits. Sparse: a flat array that big is 32 Mbit
	// of simulator memory, which Verilator handles fine as a 2-state array.
	localparam ROWS = 8192, COLS = 512;
	reg [15:0] mem  [0:4*ROWS*COLS-1];
	reg        seen [0:4*ROWS*COLS-1];   // 1 = this cell was ever written

	reg [12:0] act_row [0:3];
	reg  [3:0] act_val;

	// Read pipeline: CAS_LATENCY stages, each carrying validity + flat address.
	reg         rd_v   [0:7];
	reg  [31:0] rd_a   [0:7];
	integer     i;

	reg [15:0] dq_drv;
	reg        dq_oe;
	assign SDRAM_DQ = dq_oe ? dq_drv : 16'bz;

	// Burst counters for the 2-beat read/write bursts the controller programs.
	reg  [2:0] wr_left;
	reg [31:0] wr_addr;

	function [31:0] flat(input [1:0] b, input [12:0] r, input [9:0] c);
		flat = ((b * ROWS) + r) * COLS + c[8:0];
	endfunction

	initial begin
		act_val = 0; dq_oe = 0; wr_left = 0;
		for (i = 0; i < 8; i = i + 1) begin rd_v[i] = 0; rd_a[i] = 0; end
	end

	wire [2:0] cmd = {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};
	localparam CMD_ACTIVE = 3'b011, CMD_READ = 3'b101, CMD_WRITE = 3'b100,
	           CMD_PRE = 3'b010, CMD_REF = 3'b001, CMD_MODE = 3'b000, CMD_NOP = 3'b111;

	always @(posedge SDRAM_CLK) begin
		// advance the CAS pipeline
		for (i = 7; i > 0; i = i - 1) begin rd_v[i] <= rd_v[i-1]; rd_a[i] <= rd_a[i-1]; end
		rd_v[0] <= 1'b0;

		// NOTE: no write-burst continuation. sdram.sv sets NO_WRITE_BURST=1
		// (sdram.sv:261), so a WRITE is a SINGLE 16-bit beat even though BURST_LENGTH=1
		// makes READS two beats. Modelling writes as a 2-beat burst wrote a bogus second
		// word at addr+1 from a stale DQ, which is what made phase 1 fail.

		if (!SDRAM_nCS) begin
			case (cmd)
			CMD_ACTIVE: begin
				act_row[SDRAM_BA] <= SDRAM_A;
				act_val[SDRAM_BA] <= 1'b1;
			end
			CMD_READ: begin
				rd_v[0] <= 1'b1;
				rd_a[0] <= flat(SDRAM_BA, act_row[SDRAM_BA], SDRAM_A[9:0]);
			end
			CMD_WRITE: begin
				// first beat is captured on the command cycle itself
				if (!SDRAM_DQML) mem[flat(SDRAM_BA, act_row[SDRAM_BA], SDRAM_A[9:0])][7:0]
				                   <= SDRAM_DQ[7:0];
				if (!SDRAM_DQMH) mem[flat(SDRAM_BA, act_row[SDRAM_BA], SDRAM_A[9:0])][15:8]
				                   <= SDRAM_DQ[15:8];
				if (!(SDRAM_DQML && SDRAM_DQMH))
					seen[flat(SDRAM_BA, act_row[SDRAM_BA], SDRAM_A[9:0])] <= 1'b1;
			end
			CMD_PRE: begin
				if (SDRAM_A[10]) act_val <= 4'b0000; else act_val[SDRAM_BA] <= 1'b0;
			end
			default: ;
			endcase
		end
	end

	// drive DQ CAS_LATENCY cycles after the READ command, for BURST_LEN beats
	reg [15:0] pois;
	always @(*) begin
		// rd_v[k] is set BY the posedge at T+k, so an output driven combinationally from
		// rd_v[k] is first sampleable at edge T+k+1. A real part presents burst beat 0 to
		// be captured AT edge T+CAS_LATENCY, so drive one stage earlier.
		dq_oe  = rd_v[CAS_LATENCY-1] | rd_v[CAS_LATENCY];
		if (rd_v[CAS_LATENCY-1]) begin
			pois   = {2'b10, rd_a[CAS_LATENCY-1][13:0]} ^ 16'hA5A5;
			dq_drv = seen[rd_a[CAS_LATENCY-1]] ? mem[rd_a[CAS_LATENCY-1]] : pois;
		end else if (rd_v[CAS_LATENCY]) begin
			pois   = {2'b10, (rd_a[CAS_LATENCY][13:0]+14'd1)} ^ 16'hA5A5;
			dq_drv = seen[rd_a[CAS_LATENCY]+1] ? mem[rd_a[CAS_LATENCY]+1] : pois;
		end else dq_drv = 16'h0;
	end
endmodule
`default_nettype wire
