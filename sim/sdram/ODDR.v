// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Romain Tisserand
// Minimal Gowin ODDR stub for simulation only. On hardware this primitive regenerates
// SDRAM_CLK at the pin with the output register's delay; the chip model is clocked from
// the controller's own `clk` instead, so nothing in this test depends on Q0/Q1. It exists
// purely so Verilator can elaborate sdram.sv.
module ODDR #(parameter TXCLK_POL = 1'b0, parameter CONSTANT = "FALSE")
	(input D0, input D1, input TX, input CLK, output reg Q0, output reg Q1);
	always @(posedge CLK) Q0 <= D0;
	always @(*)           Q1 = TX;
endmodule
