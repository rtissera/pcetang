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

module ARCADE_CARD #(
	// PCE PORT 2026-09-18. Both default OFF, so an unset board is bit-identical to the donor.
	//   AC_REG_BUS: register the CPU bus into the WRITE path (timing fix, see below).
	//   AC_SLIM   : one shared address adder instead of four (area fix, see below).
	parameter AC_REG_BUS = 0,
	parameter AC_SLIM    = 0
)
(
	input         CLK,
	input         RST_N,

	input         EN,
	input         WR_N,
	input         RD_N,
	input  [20:0] A,
	input   [7:0] DI,
	output  [7:0] DO,
	output        SEL_N,
	
	output        RAM_CS_N,
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
wire [1:0] p;

reg        ena;
reg [31:0] shift_latch;
reg  [7:0] shift_bits;
reg  [7:0] rotate_bits;

// ---------------------------------------------------------------------------------------
// AC_REG_BUS (timing). This module decoded the LIVE CPU address/data combinationally into a
// 24-bit adder feeding port[].base, so the path ran CPU microcode -> address decode -> port
// select -> 24-bit add -> base register inside one 23 ns clock. Primer 25K reported 428 setup
// violations with the AC in, EVERY one ending at core/gen_ac.AC/port[N].base_*, and seven of
// Console 60K's eight worst paths ran into this module.
//
// Safe because CPU_A/CPU_DO only change on a CPU clock-enable pulse and HUC6280's CE scheme
// (CPU_CLK_CNT 0..5, held at 5 while WAIT_N=0) guarantees >=6 clk_pce between pulses: the bus is
// stable for counts 1..5 and this module acts on the ~old_acc&acc edge at count 3, so sampling
// one clock later sees IDENTICAL values inside the SAME CPU cycle.
//
// NOT registered on purpose: SEL_N, DO, RAM_CS_N, RAM_A stay combinational off the LIVE address --
// the CPU samples read data in the cycle it presents the address, and the CD-RAM bridge compares
// RAM_A against its own last address.
reg [20:0] A_q;
reg  [7:0] DI_q;
reg        WR_N_q, RD_N_q;
always @(posedge CLK) begin
	A_q    <= A;
	DI_q   <= DI;
	WR_N_q <= WR_N;
	RD_N_q <= RD_N;
end
wire [20:0] Aw    = AC_REG_BUS ? A_q    : A;
wire  [7:0] DIw   = AC_REG_BUS ? DI_q   : DI;
wire        WR_Nw = AC_REG_BUS ? WR_N_q : WR_N;
wire        RD_Nw = AC_REG_BUS ? RD_N_q : RD_N;
wire  [1:0] pw    = (Aw[20:15] == 16) ? Aw[14:13] : Aw[5:4];
wire        SEL_Nw = ~(EN && &Aw[20:13] && (Aw[12:8] == 'h1A));

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

// ---------------------------------------------------------------------------------------
// AC_SLIM (area). The donor builds FOUR 21-bit adders that run every clock for all four ports,
// although `RAM_A = port[p].addr` can only ever present ONE of them. The four-way select already
// exists, so one adder behind that select is the same function with a quarter of the arithmetic.
// This matters because the Arcade Card does not FIT on Primer 25K: 100% logic (23020/23040) with
// the stock card, and 1706 unrouted nets when it is forced. Every other way of making room takes
// a feature away (SF2' mapper, VRAM prefetch, PSG path); this one takes nothing away.
//
// NOT FUNCTIONALLY VALIDATED YET -- built for AREA/TIMING MEASUREMENT ONLY. `addr` is registered
// in both variants so RAM_A stays a register output, but in the slim variant it tracks only the
// CURRENTLY SELECTED port, so a read that changes `p` and samples RAM_A in the same cycle would
// see the old port. Whether that can happen depends on the CE timing of a real AC access, and
// that must be shown in simulation before this is ever shipped.
generate
if (AC_SLIM) begin : gen_slim_addr
	always @(posedge CLK) begin
		port[p].addr <= port[p].base[20:0] + (port[p].control[1] ? {{5{port[p].control[3]}}, port[p].offset} : 21'd0);
	end
end else begin : gen_wide_addr
	always @(posedge CLK) begin
		for(int i=0; i<4; i++) begin
			port[i].addr = port[i].base[20:0] + (port[i].control[1] ? {{5{port[i].control[3]}}, port[i].offset} : 21'd0);
		end
	end
end
endgenerate

wire [3:0] rot = DIw[3] ? (4'd8 - DIw[2:0]) : DIw[2:0];
wire acc = ~(WR_Nw & RD_Nw);

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

		if(~SEL_Nw & ~WR_Nw) begin
			if(!Aw[7]) begin

				ena <= 1;
				case(Aw[3:0])
					2: port[pw].base[7:0] <= DIw;
					3: port[pw].base[15:8] <= DIw;
					4: port[pw].base[23:16] <= DIw;
					5: begin
							port[pw].offset[7:0] <= DIw;
							if(port[pw].control[6:5] == 1) port[pw].base <= port[pw].base + {{8{port[pw].control[3]}}, port[pw].offset[15:8], DIw};
						end
					6: begin
							port[pw].offset[15:8] <= DIw;
							if(port[pw].control[6:5] == 2) port[pw].base <= port[pw].base + {{8{port[pw].control[3]}}, DIw, port[pw].offset[7:0]};
						end
					7: port[pw].increment[7:0] <= DIw;
					8: port[pw].increment[15:8] <= DIw;
					9: port[pw].control <= DIw[6:0];
					10: if(port[pw].control[6:5] == 3) port[pw].base <= port[pw].base + {{8{port[pw].control[3]}}, port[pw].offset};
				endcase
			end
			else if(&Aw[6:5]) begin

				case (Aw[4:0])
					0: shift_latch[7:0] <= DIw;
					1: shift_latch[15:8] <= DIw;
					2: shift_latch[23:16] <= DIw;
					3: shift_latch[31:24] <= DIw;
					4: begin
							shift_bits <= DIw[3:0];
							shift_latch <= DIw[3] ? (shift_latch >> (8 - DIw[2:0])) : (shift_latch << DIw[2:0]);
						end
					5: begin
							rotate_bits <= DIw[3:0];
							if(DIw[3]) shift_latch <= (shift_latch >> rot) | (shift_latch << (32 - rot));
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
