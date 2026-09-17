// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Romain Tisserand
//
// ADPCM co-simulation top: the REAL cd.vhd and the port-C arbiter (both converted to Verilog by
// `ghdl synth --out=verilog`) in front of the REAL sdram.sv and the SDRAM chip model -- so port
// C behaves exactly like the shipped controller, including the line-cache hit path where WAIT
// never rises, which no hand-written model had exercised.
//
// Two clocks, as on Console 60K: clk_pce 42.857 MHz for cd/arbiter, clk_sdram 85.714 MHz for
// sdram.sv. The C++ driver keeps them phase aligned (every clk_pce rise is a clk_sdram rise).
//
// pre_sel=1 hands port C to the C++ driver so it can load ADPCM RAM through sdram.sv's real
// write path before cd.vhd runs; pre_sel=0 gives port C to the arbiter.
module tb_adpcm_cosim_top (
	input  wire        clk_pce,
	input  wire        clk_sdram,
	input  wire        sdram_init,
	input  wire        rst_n,
	input  wire        cpu_ce,
	input  wire [20:0] ext_a,
	input  wire  [7:0] ext_di,
	input  wire        ext_wr_n,
	input  wire        ext_rd_n,
	// CD-RAM client of the arbiter (traffic generator lives in C++)
	input  wire [21:0] cd_ram_a,
	input  wire  [7:0] cd_ram_do,
	input  wire        cd_ram_rd,
	input  wire        cd_ram_wr,
	output wire  [7:0] cd_ram_di,
	output wire        cd_ram_rdy,
	// ports A/B of sdram.sv, driven by C++ to create contention (or idle)
	input  wire [24:0] ram_a_addr, input wire ram_a_req, input wire ram_a_rd_n,
	input  wire [24:0] ram_b_addr, input wire ram_b_req,
	output wire        ram_a_wait, output wire ram_b_wait,
	// preload access to port C
	input  wire        pre_sel,
	input  wire [24:0] pre_addr,
	input  wire        pre_req,
	input  wire        pre_rd_n,
	input  wire  [7:0] pre_di,
	// observation
	output wire [15:0] ad_s,
	output wire  [1:0] adpcm_slot,
	output wire        adpcm_req,
	output wire        adpcm_we,
	output wire [16:0] adpcm_a,
	output wire  [3:0] adpcm_di,
	output wire  [7:0] ram_c_do,
	output wire        ram_c_wait,
	output wire        arb_req
);
	wire [16:0] a_a;  wire [3:0] a_do; wire a_we, a_req; wire [1:0] a_slot;
	wire  [3:0] a_di; wire a_rdy;
	wire [24:0] arb_addr; wire arb_req_w, arb_rd_n; wire [7:0] arb_di;

	cd cd_i (
		.RST_N(rst_n), .CLK(clk_pce), .EN(1'b1),
		.EXT_A(ext_a), .EXT_DI(ext_di), .EXT_WR_N(ext_wr_n), .EXT_RD_N(ext_rd_n), .CPU_CE(cpu_ce),
		.CD_STAT(8'h00), .CD_MSG(8'h00), .CD_STAT_GET(1'b0), .CD_DOUT_REQ(1'b0), .CD_REGION(1'b0),
		.CD_DATA(8'h00), .CD_DATA_WR(1'b0), .CD_AUDIO_WR(1'b0), .CD_SUBCD_WR(1'b0),
		.CD_DATAIN_SECTORS(9'd0), .DM(1'b0),
		.ADPCM_RAM_DI(a_di), .ADPCM_RAM_READY(a_rdy),
		.EXT_DO(), .SEL_N(), .IRQ_N(), .RAM_CS_N(), .BRAM_EN(),
		.CD_COMM(), .CD_COMM_SEND(), .CD_DOUT(), .CD_DOUT_SEND(), .CD_RESET(), .CD_DATA_END(),
		.DBG_DATAIN_CNT(), .DBG_FIRST8(), .DBG_SP(), .DBG_ADPCM(), .DBG_COMM_POS(), .DBG_COMM0(),
		.DBG_COMM1(), .DBG_SEL_CNT(), .DBG_FIFO_SPACE(), .DBG_FIFO_DROPS(), .DBG_GDI(),
		.DBG_RD_TOTAL(), .DBG_CDDA_SPACE(), .DBG_UNDERRUNS(),
		.CD_SL(), .CD_SR(), .AD_S(ad_s),
		.ADPCM_RAM_A(a_a), .ADPCM_RAM_DO(a_do), .ADPCM_RAM_WE(a_we),
		.ADPCM_RAM_REQ(a_req), .ADPCM_RAM_SLOT_CNT(a_slot)
	);

	wire [7:0] c_do; wire c_wait;

	portc_arbiter arb_i (
		.clk_pce(clk_pce),
		.cd_ram_a(cd_ram_a), .cd_ram_do(cd_ram_do), .cd_ram_rd(cd_ram_rd), .cd_ram_wr(cd_ram_wr),
		.cd_ram_di(cd_ram_di), .cd_ram_rdy(cd_ram_rdy),
		.adpcm_ram_a(a_a), .adpcm_ram_do(a_do), .adpcm_ram_we(a_we), .adpcm_ram_req(a_req),
		.adpcm_ram_slot_cnt(a_slot), .adpcm_ram_di(a_di), .adpcm_ram_ready(a_rdy),
		.ram_c_addr(arb_addr), .ram_c_req(arb_req_w), .ram_c_rd_n(arb_rd_n), .ram_c_di(arb_di),
		.ram_c_do(c_do), .ram_c_wait(c_wait)
	);

	wire [12:0] SDRAM_A; wire [1:0] SDRAM_BA; wire [15:0] SDRAM_DQ;
	wire SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS, SDRAM_CKE, SDRAM_CLK;

	sdram sdram_i (
		.clk(clk_sdram), .init(sdram_init),
		.SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_nWE(SDRAM_nWE), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
		.RAM_A_ADDR(ram_a_addr), .RAM_A_REQ(ram_a_req), .RAM_A_RD_n(ram_a_rd_n),
		.RAM_A_DI(16'h0000), .RAM_A_DO(), .RAM_A_WAIT(ram_a_wait),
		.RAM_A_LINE_REFILL(1'b0), .RAM_A_LINE_DO(),
		.RAM_B_ADDR(ram_b_addr), .RAM_B_REQ(ram_b_req), .RAM_B_WE(1'b0),
		.RAM_B_DI(8'h00), .RAM_B_DO(), .RAM_B_WAIT(ram_b_wait),
		.RAM_C_ADDR(pre_sel ? pre_addr : arb_addr),
		.RAM_C_REQ (pre_sel ? pre_req  : arb_req_w),
		.RAM_C_RD_n(pre_sel ? pre_rd_n : arb_rd_n),
		.RAM_C_DI  (pre_sel ? pre_di   : arb_di),
		.RAM_C_DO(c_do), .RAM_C_WAIT(c_wait),
		.RAM_C_WIDE(1'b0), .RAM_C_DI16(16'h0000), .RAM_C_DO16(),
		.RAM_C_LINE_REFILL(1'b0), .RAM_C_LINE_DO()
	);

	sdram_chip_model chip_i (
		.SDRAM_CLK(clk_sdram), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_nWE(SDRAM_nWE), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_DQ(SDRAM_DQ)
	);

	assign adpcm_slot = a_slot;
	assign adpcm_req  = a_req;
	assign adpcm_we   = a_we;
	assign adpcm_a    = a_a;
	assign adpcm_di   = a_di;
	assign ram_c_do   = c_do;
	assign ram_c_wait = c_wait;
	assign arb_req    = arb_req_w;
endmodule
