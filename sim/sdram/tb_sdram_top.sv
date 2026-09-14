// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Romain Tisserand
//
// Wrapper tying sdram.sv to the behavioural chip model so Verilator can drive the whole
// thing from C++. Exists because sdram.sv's SDRAM_DQ is an inout: Verilator will not let
// C++ drive a tristate cleanly, so the net stays inside SystemVerilog.
`default_nettype none

module tb_sdram_top (
	input  wire        clk,
	input  wire        init,

	input  wire [24:0] RAM_A_ADDR, input wire RAM_A_REQ, input wire RAM_A_RD_n,
	input  wire [15:0] RAM_A_DI,   output wire [15:0] RAM_A_DO, output wire RAM_A_WAIT,

	input  wire [24:0] RAM_B_ADDR, input wire RAM_B_REQ, input wire RAM_B_WE,
	input  wire  [7:0] RAM_B_DI,   output wire [7:0] RAM_B_DO, output wire RAM_B_WAIT,

	input  wire [24:0] RAM_C_ADDR, input wire RAM_C_REQ, input wire RAM_C_RD_n,
	input  wire  [7:0] RAM_C_DI,   output wire [7:0] RAM_C_DO, output wire RAM_C_WAIT
);
	wire [12:0] SDRAM_A;
	wire  [1:0] SDRAM_BA;
	wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS;
	wire        SDRAM_nCS, SDRAM_CKE, SDRAM_CLK;
	wire [15:0] SDRAM_DQ;

	sdram dut (
		.clk(clk), .init(init),
		.SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_nWE(SDRAM_nWE), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
		.RAM_A_ADDR(RAM_A_ADDR), .RAM_A_REQ(RAM_A_REQ), .RAM_A_RD_n(RAM_A_RD_n),
		.RAM_A_DI(RAM_A_DI), .RAM_A_DO(RAM_A_DO), .RAM_A_WAIT(RAM_A_WAIT),
		.RAM_B_ADDR(RAM_B_ADDR), .RAM_B_REQ(RAM_B_REQ), .RAM_B_WE(RAM_B_WE),
		.RAM_B_DI(RAM_B_DI), .RAM_B_DO(RAM_B_DO), .RAM_B_WAIT(RAM_B_WAIT),
		.RAM_C_ADDR(RAM_C_ADDR), .RAM_C_REQ(RAM_C_REQ), .RAM_C_RD_n(RAM_C_RD_n),
		.RAM_C_DI(RAM_C_DI), .RAM_C_DO(RAM_C_DO), .RAM_C_WAIT(RAM_C_WAIT)
	);

	// The controller drives SDRAM_CLK through a DDR primitive on real hardware; in sim it
	// is combinational from clk, which Verilator would flag as a clock it cannot infer.
	// Feed the model the same clk the controller uses -- same edge, no skew modelled.
	sdram_chip_model model (
		.SDRAM_CLK(clk), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_nWE(SDRAM_nWE), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_DQ(SDRAM_DQ)
	);
endmodule
`default_nettype wire
