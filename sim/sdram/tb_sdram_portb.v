// SPDX-License-Identifier: GPL-3.0-or-later
//
// Port-B back-to-back same-line read test for sdram.sv.
//
// WHY THIS EXISTS: on Console 60K the HuC6280 fetched a TAM opcode at 0x474 and then its
// operand at 0x475 -- the SAME 4-byte cache line -- and received the OPCODE byte for both.
// Every TAM then used $53 as its MPR write-enable mask, writing MPR0/1/4/6 (exactly the
// set bits of $53), which is precisely what the hardware MPR dump showed. The GHDL boot
// testbench could never catch this: it stubs the memory controller out entirely and hands
// the CPU a zero-latency ROM model.
//
// This drives the REAL sdram.sv against a minimal SDRAM model and asserts that a read
// issued while the previous fill is still in flight returns ITS OWN byte.
//
//   iverilog -g2012 -o tb sim/sdram/tb_sdram_portb.v src/pce/common/mem/sdram.sv && ./tb
//
// Memory content is a pure function of address -- byte(X) = X[7:0] ^ 0x5A -- so a wrong
// byte names the address that was actually served.

`timescale 1ns/1ps

// Gowin output DDR primitive, stubbed: only the clock forwarding pin uses it and this
// test does not care about the SDRAM clock's phase.
module ODDR (output reg Q0, output Q1, input D0, input D1, input TX, input CLK);
	assign Q1 = 1'b0;
	always @(posedge CLK) Q0 <= D0;
endmodule

module tb_sdram_portb;

	localparam CAS_LATENCY = 3;   // must match sdram.sv's localparam

	reg clk = 0;
	always #3.5 clk = ~clk;       // ~143 MHz, the rate sdram.sv's delays are written for

	reg init = 1;

	wire [12:0] SDRAM_A;
	wire  [1:0] SDRAM_BA;
	wire [15:0] SDRAM_DQ;
	wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS;
	wire        SDRAM_CKE, SDRAM_CLK;

	reg  [24:0] b_addr = 0;
	reg         b_req  = 0;
	wire  [7:0] b_do;
	wire        b_wait;

	sdram dut (
		.clk(clk), .init(init),
		.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ), .SDRAM_BA(SDRAM_BA),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_nWE(SDRAM_nWE), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
		.RAM_A_ADDR(25'd0), .RAM_A_REQ(1'b0), .RAM_A_RD_n(1'b1), .RAM_A_DI(16'd0),
		.RAM_B_ADDR(b_addr), .RAM_B_REQ(b_req), .RAM_B_WE(1'b0), .RAM_B_DI(8'd0),
		.RAM_B_DO(b_do), .RAM_B_WAIT(b_wait),
		.RAM_C_ADDR(25'd0), .RAM_C_REQ(1'b0), .RAM_C_RD_n(1'b1), .RAM_C_DI(8'd0)
	);

	// ---- minimal SDRAM model --------------------------------------------------------
	// Address mapping mirrors sdram.sv exactly:
	//   ACTIVE : SDRAM_A[12:0] = a[22:10] (row),  SDRAM_BA = bank
	//   READ   : SDRAM_A[8:0]  = a[9:1]   (col)
	// so the 25-bit byte address is {bank, row, col, 1'b0}.
	reg [12:0] row;
	reg  [1:0] bank_r;
	reg [24:0] word_addr;

	wire [2:0] cmd = {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};
	localparam CMD_ACTIVE = 3'b011, CMD_READ = 3'b101;

	reg [15:0] dq_pipe [0:CAS_LATENCY];
	reg        oe_pipe [0:CAS_LATENCY];
	integer    k;
	reg dbg = 0;

	function [7:0] mem_byte(input [24:0] a);
		mem_byte = a[7:0] ^ 8'h5A;
	endfunction

	assign SDRAM_DQ = oe_pipe[0] ? dq_pipe[0] : 16'hzzzz;

	initial for (k = 0; k <= CAS_LATENCY; k = k + 1) begin
		dq_pipe[k] = 16'h0; oe_pipe[k] = 1'b0;
	end

	always @(posedge clk) begin
		if (!SDRAM_nCS && cmd == CMD_ACTIVE) begin
			row    <= SDRAM_A;
			bank_r <= SDRAM_BA;
			if (dbg) $display("    [model] ACTIVE t=%0t bank=%0d row=%h", $time, SDRAM_BA, SDRAM_A);
		end

		for (k = 0; k < CAS_LATENCY; k = k + 1) begin
			dq_pipe[k] <= dq_pipe[k+1];
			oe_pipe[k] <= oe_pipe[k+1];
		end
		oe_pipe[CAS_LATENCY] <= 1'b0;

		if (!SDRAM_nCS && cmd == CMD_READ) begin
			word_addr = {bank_r, row, SDRAM_A[8:0], 1'b0};
			if (dbg) $display("    [model] READ  t=%0t bank=%0d row=%h col=%h -> word_addr=%07h",
			                  $time, bank_r, row, SDRAM_A[8:0], word_addr);
			dq_pipe[CAS_LATENCY] <= {mem_byte(word_addr | 25'd1), mem_byte(word_addr)};
			oe_pipe[CAS_LATENCY] <= 1'b1;
		end
	end

	// ---- the test -------------------------------------------------------------------
	integer errors = 0;
	integer guard;

	task do_read(input [24:0] addr, input [255:0] label);
		reg [7:0] expect_byte;
		begin
			expect_byte = mem_byte(addr);
			@(posedge clk);
			b_addr <= addr;          // address settles a cycle before REQ toggles, which
			@(posedge clk);          // is what the board's bridge does (RB_ADDR state)
			b_req  <= ~b_req;        // port B launches on a REQ toggle
			@(posedge clk);
			guard = 0;
			while (b_wait && guard < 400) begin
				@(posedge clk);
				guard = guard + 1;
			end
			@(posedge clk);
			if (guard >= 400) begin
				$display("  FAIL %0s: timed out with RAM_B_WAIT still high", label);
				errors = errors + 1;
			end else if (b_do !== expect_byte) begin
				$display("  FAIL %0s: addr %06h -> got %02h, expected %02h",
				         label, addr, b_do, expect_byte);
				errors = errors + 1;
			end else begin
				$display("  ok   %0s: addr %06h -> %02h", label, addr, b_do);
			end
		end
	endtask

	// Model FPGA power-up: on Gowin every register comes up at 0, but Verilog leaves an
	// uninitialised reg at X, and an X in `state` or `old_b_req` freezes the controller
	// before it issues a single command. This is a simulation artefact, not a DUT bug.
	initial begin
		dut.state = 4'd0;
		dut.access_manager.old_b_req = 1'b0;
		dut.access_manager.old_a_req = 1'b0;
		dut.access_manager.old_ref   = 1'b0;
		dut.access_manager.ch0_busy  = 1'b0;
		dut.access_manager.ch1_busy  = 1'b0;
		dut.access_manager.pend_a_b  = 23'd0;
		// rfsh_cnt X makes `&rfsh_cnt` X, so the refresh-first branch wins forever and
		// starves every client -- the controller issues nothing but AUTO_REFRESH.
		dut.rfsh_cnt = 9'd0;
	end

	initial begin
		repeat (10) @(posedge clk);
		init = 0;
		repeat (400) @(posedge clk);   // let the controller finish its init sequence

		dbg = 1;
		$display("sdram.sv port-B reads   (byte at X == X[7:0] ^ 5A):");

		// Cold reads in different lines -- the case that always worked.
		do_read(25'h000474, "cold  0x474");
		do_read(25'h001000, "cold  0x1000");

		// THE REGRESSION: consecutive reads inside ONE 4-byte line, which is exactly the
		// HuC6280's opcode-then-operand fetch pattern.
		do_read(25'h000474, "line  0x474 (opcode)");
		do_read(25'h000475, "line  0x475 (operand)  <-- the corrupted one on hardware");
		do_read(25'h000476, "line  0x476");
		do_read(25'h000477, "line  0x477");

		$display("");
		if (errors == 0) $display("PASS: every port-B read returned its own byte");
		else             $display("FAIL: %0d wrong byte(s)", errors);
		$finish;
	end

	// DUT state trace, on for a short window after the first request
	integer dbgn = 0;
	always @(posedge clk) if (dbg && dbgn < 40) begin
		dbgn <= dbgn + 1;
		$display("    [dut] t=%0t state=%0d mode=%0d req=%b wait=%b nCS=%b cmd=%b A=%h",
		         		         $time, dut.state, dut.mode, b_req, b_wait,
		         SDRAM_nCS, cmd, SDRAM_A);
	end

	initial begin
		#5000000;
		$display("FAIL: global timeout");
		$finish;
	end

endmodule
