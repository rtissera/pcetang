// SPDX-License-Identifier: GPL-3.0-or-later
// Modifications copyright (c) 2026 Romain Tisserand.
// This file is derived from third-party code and is NOT original work of this project; only the
// changes made here are covered by the line above. See THIRD_PARTY_LICENSES.md for the upstream
// project, author and licence.
//
// ARCADE_CARD_SLIM -- arcade.sv with two changes, selected by pce_top's AC_SLIM generic. It is a
// separate MODULE, not a parameter, because GowinSynthesis cannot bind a VHDL generic to a
// Verilog module: `ERROR (EX4677): Binding entity 'ARCADE_CARD' does not have generic ...`.
// Keep it in step with arcade.sv, which stays byte-identical to the donor.
//
// 1. REGISTERED WRITE BUS (timing). The donor decodes the LIVE CPU address/data combinationally
//    into a 24-bit adder feeding port[].base: CPU microcode -> decode -> port select -> add ->
//    register, all inside one 23 ns clock. Primer 25K's 428 setup violations with the card in ALL
//    ended at core/gen_ac.AC/port[N].base_*. Safe because CPU_A/CPU_DO only change on a CPU
//    clock-enable pulse and the CE scheme guarantees >=6 clk_pce between pulses (stable counts
//    1..5; the card acts at count 3), so sampling one clock later sees identical values in the
//    same CPU cycle. DO/SEL_N/RAM_CS_N/RAM_A stay combinational off the LIVE address -- the CPU
//    samples read data in the cycle it presents the address.
//
// 2. ONE SHARED ADDRESS ADDER (area). The donor builds FOUR 21-bit adders that run every clock
//    although `RAM_A = port[p].addr` can only ever present one. The four-way select already
//    exists. This is the only way of making room on Primer 25K (100% logic with the stock card)
//    that takes no feature away -- every alternative costs the SF2' mapper, the VRAM prefetch fix
//    or the PSG path.
//
// NOT FUNCTIONALLY VALIDATED -- area/timing measurement only. `addr` now tracks only the SELECTED
// port, so a read that changes `p` and samples RAM_A in the same cycle would see the old port.
// Whether that is reachable must be shown in simulation (the co-sim, since the card shares SDRAM
// port C with CD-RAM) before this ships.
// Modifications copyright (c) 2026 Romain Tisserand.
// This file is derived from third-party code and is NOT original work of
// this project; only the changes made here are covered by the line above.
// See THIRD_PARTY_LICENSES.md for the upstream project, author and licence.
//
// Arcade Card
// Copyright (c) 2020 Alexey Melnikov
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
//
// GOWIN FIX (NECTang, GPL-3.0-or-later on this port's own changes): `DO`, `RAM_CS_N`
// were implicit-typed output ports and `p` was declared `wire`, all three procedurally
// assigned inside `always_comb` below. Real gw_sh run failed with EX3900 "Procedural
// assignment to a non-register" -- Gowin's SystemVerilog parser treats an implicit or
// `wire`-declared signal as a net, not `logic`, unlike some other tools' SV defaults.
// Fixed by declaring all three explicitly `logic`, the standard SystemVerilog fix for
// this exact error class. No behavioral change -- see NECTang's docs/PORTING.md.
//

module ARCADE_CARD_SLIM
(
	input         CLK,
	input         RST_N,

	input         EN,
	input         WR_N,
	input         RD_N,
	input  [20:0] A,
	input   [7:0] DI,
	output logic [7:0] DO,
	output        SEL_N,

	output logic  RAM_CS_N,
	output [20:0] RAM_A
);


typedef struct packed
{
	reg [23:0] base;
	reg [15:0] offset;
	reg [15:0] increment;
	reg  [6:0] control;
	reg [20:0] addr;
} port_t;

port_t port[4];
logic [1:0] p;

reg        ena;
reg [31:0] shift_latch;
reg  [7:0] shift_bits;
reg  [7:0] rotate_bits;

// Registered CPU bus, used by the WRITE path only (see header).
reg [20:0] A_q;  reg [7:0] DI_q;  reg WR_N_q, RD_N_q;
always @(posedge CLK) begin
	A_q <= A;  DI_q <= DI;  WR_N_q <= WR_N;  RD_N_q <= RD_N;
end
wire [1:0] pw     = (A_q[20:15] == 16) ? A_q[14:13] : A_q[5:4];
wire       SEL_N_q = ~(EN && &A_q[20:13] && (A_q[12:8] == 'h1A));

assign SEL_N = ~(EN && &A[20:13] && (A[12:8] == 'h1A));
assign RAM_A = port[p].addr;

always_comb begin
	DO = 8'hFF;
	RAM_CS_N = 1;

	if(A[20:15] == 16) begin // pages 0x40-0x43
		p = A[14:13];
		RAM_CS_N = ~EN | ~ena;
	end
	else begin
		p = A[5:4];

		if(!A[7]) begin

			case(A[3:0])
				0,1: RAM_CS_N = SEL_N;

				2: DO = port[p].base[7:0];
				3: DO = port[p].base[15:8];
				4: DO = port[p].base[23:16];
				5: DO = port[p].offset[7:0];
				6: DO = port[p].offset[15:8];
				7: DO = port[p].increment[7:0];
				8: DO = port[p].increment[15:8];
				9: DO = port[p].control;
				default:;
			endcase
		end
		else if(&A[6:5]) begin

			case (A[4:0])
				0: DO = shift_latch[7:0];
				1: DO = shift_latch[15:8];
				2: DO = shift_latch[23:16];
				3: DO = shift_latch[31:24];
				4: DO = shift_bits;
				5: DO = rotate_bits;

				'h1C: DO = 0;
				'h1D: DO = 0;

				'h1E: DO = 8'h10;
				'h1F: DO = 8'h51;
				default:;
			endcase
		end
	end
end

// ONE adder behind the existing four-way select, instead of four running every clock.
always @(posedge CLK) begin
	port[p].addr <= port[p].base[20:0] + (port[p].control[1] ? {{5{port[p].control[3]}}, port[p].offset} : 21'd0);
end

wire [3:0] rot = DI_q[3] ? (4'd8 - DI_q[2:0]) : DI_q[2:0];
wire acc = ~(WR_N_q & RD_N_q);

always @(posedge CLK) begin
	reg old_acc;

	old_acc <= acc;

	if(~RST_N) begin
		for(int i=0; i<4; i++) begin
			port[i].base <= 0;
			port[i].offset <= 0;
			port[i].increment <= 0;
			port[i].control <= 0;
		end
		ena <= 0;
		shift_latch <= 0;
		shift_bits <= 0;
		rotate_bits <= 0;
	end
	else if(~old_acc & acc) begin

		if(~SEL_N_q & ~WR_N_q) begin
			if(!A_q[7]) begin

				ena <= 1;
				case(A_q[3:0])
					2: port[pw].base[7:0] <= DI_q;
					3: port[pw].base[15:8] <= DI_q;
					4: port[pw].base[23:16] <= DI_q;
					5: begin
							port[pw].offset[7:0] <= DI_q;
							if(port[pw].control[6:5] == 1) port[pw].base <= port[pw].base + {{8{port[pw].control[3]}}, port[pw].offset[15:8], DI_q};
						end
					6: begin
							port[pw].offset[15:8] <= DI_q;
							if(port[pw].control[6:5] == 2) port[pw].base <= port[pw].base + {{8{port[pw].control[3]}}, DI_q, port[pw].offset[7:0]};
						end
					7: port[pw].increment[7:0] <= DI_q;
					8: port[pw].increment[15:8] <= DI_q;
					9: port[pw].control <= DI_q[6:0];
					10: if(port[pw].control[6:5] == 3) port[pw].base <= port[pw].base + {{8{port[pw].control[3]}}, port[pw].offset};
				endcase
			end
			else if(&A_q[6:5]) begin

				case (A_q[4:0])
					0: shift_latch[7:0] <= DI_q;
					1: shift_latch[15:8] <= DI_q;
					2: shift_latch[23:16] <= DI_q;
					3: shift_latch[31:24] <= DI_q;
					4: begin
							shift_bits <= DI_q[3:0];
							shift_latch <= DI_q[3] ? (shift_latch >> (8 - DI_q[2:0])) : (shift_latch << DI_q[2:0]);
						end
					5: begin
							rotate_bits <= DI_q[3:0];
							if(DI_q[3]) shift_latch <= (shift_latch >> rot) | (shift_latch << (32 - rot));
							else shift_latch <= (shift_latch << rot) | ((shift_latch >> (32 - rot)) & ((32'd1 << rot) - 1'd1));
						end
				endcase
			end
		end

		if(~RAM_CS_N & port[pw].control[0]) begin
			if(port[pw].control[4]) port[pw].base <= port[pw].base + port[pw].increment;
			else port[pw].offset <= port[pw].offset + port[pw].increment;
		end
	end
end

endmodule
