// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Romain Tisserand
//
// ADPCM co-simulation driver. Replays a beetle-pce-fast golden case (sim/cd/golden/<case>)
// against the REAL cd.vhd + port-C arbiter + REAL sdram.sv, and checks every nibble cd.vhd
// consumes, in order. Same pass criterion and output format as tb_adpcm_golden.vhd, so the two
// can be compared directly -- the only thing that differs is the memory underneath.
//
// usage: tb_adpcm_cosim <case_dir> <pcm_out.txt> [fast_freq=1] [cdram_traffic=0] [ab_contention=0]
#include "Vtb_adpcm_cosim_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>

static Vtb_adpcm_cosim_top *top;
static uint64_t T = 0;        // quarter-clk_pce steps
double sc_time_stamp() { return (double)T; }

// Phase-aligned clocks: t%4 == 1 is a rising edge of BOTH clocks, t%4 == 3 rises clk_sdram only.
static void step() {
	int q = T % 4;
	top->clk_sdram = (q == 1 || q == 3) ? 1 : 0;
	top->clk_pce   = (q == 1 || q == 2) ? 1 : 0;
	top->eval();
	T++;
}
static bool pce_rise_next() { return (T % 4) == 1; }

// Run until just BEFORE the next clk_pce rising edge (so inputs set now are seen at that edge,
// and outputs read now are the pre-edge values), then take the edge.
static int cpu_ce_div = 0;
static void cyc() {
	while (!pce_rise_next()) step();
	cpu_ce_div = (cpu_ce_div + 1) % 6;
	top->cpu_ce = (cpu_ce_div == 0) ? 1 : 0;
	step();                                   // the rising edge
}
static void sdram_cyc() { step(); step(); }  // one clk_sdram period

// ---- optional stressors ------------------------------------------------------------------
static bool g_cdram = false, g_ab = false;
static int g_cpu_fetches = 0;
static uint32_t rng = 0x1234567;
static uint32_t rnd() { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
// CD-RAM traffic: bursts of consecutive reads at moving addresses, like the CPU executing
// from CD-RAM (CD-RAM wins arbitration ties, so this directly delays ADPCM accesses).
static int cd_burst = 0, cd_gap = 0; static uint32_t cd_addr = 0;
static void traffic_before_edge() {
	if (g_cdram) {
		if (top->cd_ram_rd && !top->cd_ram_rdy) {
			/* hold while the arbiter stalls us, as the CPU would */
		} else if (cd_burst > 0) {
			top->cd_ram_rd = 1; top->cd_ram_a = 0x200000 | (cd_addr++ & 0x3FFFF); cd_burst--;
		} else if (cd_gap > 0) {
			top->cd_ram_rd = 0; cd_gap--;
		} else {
			cd_burst = 2 + rnd() % 30; cd_gap = rnd() % 40;
			cd_addr = rnd();
		}
	}
	if (g_ab) {
		// port A (VRAM-style level requests) and port B (toggle protocol) at random
		if (!top->ram_a_wait && (rnd() % 9) == 0) {
			top->ram_a_req = !top->ram_a_req; top->ram_a_addr = rnd() & 0x3FFFFF; top->ram_a_rd_n = 0;
		}
		if (!top->ram_b_wait && (rnd() % 11) == 0) {
			top->ram_b_req = !top->ram_b_req; top->ram_b_addr = 0x400000 | (rnd() & 0x3FFFFF);
		}
	}
}

// ---- preload ADPCM RAM through sdram.sv's real write path ------------------------------------
static bool port_c_write(uint32_t addr, uint8_t v) {
	top->pre_addr = addr; top->pre_rd_n = 1; top->pre_di = v; top->pre_req = 1;
	int n = 0; bool seen = false;
	while (n < 20000) {
		sdram_cyc(); n++;
		if (top->ram_c_wait) seen = true;
		if (seen && !top->ram_c_wait) break;
	}
	top->pre_req = 0;
	for (int i = 0; i < 4; i++) sdram_cyc();
	return seen && n < 20000;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 3) { fprintf(stderr, "usage: %s <case_dir> <pcm_out> [fast] [cdram] [ab]\n", argv[0]); return 2; }
	std::string dir = argv[1];
	FILE *pcm_out = fopen(argv[2], "w");
	bool fast = argc > 3 ? atoi(argv[3]) : 1;
	g_cdram = argc > 4 ? atoi(argv[4]) : 0;
	g_ab    = argc > 5 ? atoi(argv[5]) : 0;
	if (argc > 6) rng = (uint32_t)strtoul(argv[6], nullptr, 0) | 1;
	// 7th arg: CPU-realistic pacing. The gap between the game's register accesses is spent
	// executing code FROM CD-RAM, so it is N CD-RAM fetches that each wait for cd_ram_rdy,
	// instead of a fixed number of clock cycles. That makes register pacing slow down under
	// port contention the way the real CPU does.
	g_cpu_fetches = argc > 7 ? atoi(argv[7]) : 0;
	top = new Vtb_adpcm_cosim_top;

	// golden data
	std::vector<uint8_t> ram;
	{ FILE *f = fopen((dir + "/ram.hex").c_str(), "r"); unsigned b; while (f && fscanf(f, "%x", &b) == 1) ram.push_back(b); if (f) fclose(f); }
	std::vector<int> gold;
	{ FILE *f = fopen((dir + "/nib.hex").c_str(), "r"); unsigned b; while (f && fscanf(f, "%x", &b) == 1) gold.push_back(b); if (f) fclose(f); }
	struct Acc { char k; int reg; int val; };
	std::vector<Acc> regs;
	{ FILE *f = fopen((dir + "/regs.txt").c_str(), "r"); char k; unsigned r, v;
	  while (f && fscanf(f, " %c %x %x", &k, &r, &v) == 3) regs.push_back({k, (int)r, (int)v}); if (f) fclose(f); }
	// the clip: ReadAddr and length from the LAST $1808/$1809 writes around $180D=08 and =10
	int start_byte = -1, len_bytes = -1, lo = 0, hi = 0;
	for (auto &a : regs) {
		if (a.k != 'W') continue;
		if (a.reg == 8) lo = a.val;
		if (a.reg == 9) hi = a.val;
		if (a.reg == 0xD && (a.val & 0x08) && start_byte < 0) start_byte = (hi << 8) | lo;
		if (a.reg == 0xD && (a.val & 0x10)) len_bytes = (hi << 8) | lo;
	}
	printf("loaded RAM bytes=%zu golden nibbles=%zu regs=%zu clip=%04x+%04x cdram_traffic=%d ab_contention=%d\n",
	       ram.size(), gold.size(), regs.size(), start_byte, len_bytes, g_cdram, g_ab);

	// reset / sdram init (same sequence as sim/sdram/tb_sdram.cpp)
	top->rst_n = 0; top->sdram_init = 1; top->pre_sel = 1; top->pre_req = 0;
	top->ext_wr_n = 1; top->ext_rd_n = 1; top->cd_ram_rd = 0; top->cd_ram_wr = 0;
	top->ram_a_req = 0; top->ram_a_rd_n = 1; top->ram_b_req = 0;
	for (int i = 0; i < 100; i++) sdram_cyc();
	top->sdram_init = 0;
	for (int i = 0; i < 20000; i++) sdram_cyc();

	// preload the clip region (+ a margin) byte k -> nibble 2k high, 2k+1 low, at ADPCM base
	const uint32_t ADPCM_BASE = 0x080000;
	int bad_writes = 0, wrote = 0;
	for (int k = start_byte - 8; k < start_byte + len_bytes + 8; k++) {
		int kb = k & 0xFFFF;
		uint8_t b = ram[kb];
		if (!port_c_write(ADPCM_BASE + 2 * kb,     (b >> 4) & 15)) bad_writes++;
		if (!port_c_write(ADPCM_BASE + 2 * kb + 1,  b       & 15)) bad_writes++;
		wrote += 2;
	}
	printf("preloaded %d nibbles through sdram.sv port C, %d failed\n", wrote, bad_writes);
	top->pre_sel = 0;
	for (int i = 0; i < 50; i++) sdram_cyc();

	top->rst_n = 0;
	for (int i = 0; i < 20; i++) cyc();
	top->rst_n = 1;
	for (int i = 0; i < 500; i++) cyc();

	// checker state
	bool armed = false, finished = false;
	int p_slot = 0, p_req = 0, p2_req = 0, p_di = 0, p_a = 0;
	long got = 0, matched = 0, extra = 0, first_bad = -1, idle = 0, after_end = 0, start_addr = -1;
	const long EXTRA_CYC = 600000, STALL_CYC = 3000000;

	// Port-C access classification: did WAIT rise while the arbiter held REQ? An access that
	// completes with WAIT never seen went through sdram.sv's line-cache HIT path and the
	// arbiter's SETTLE_HIT timeout -- the path no hand-written model had exercised.
	long acc_hit = 0, acc_miss = 0; int acc_prev_req = 0; bool acc_wait_seen = false;
	auto observe = [&]() {                    // runs once per clk_pce edge, pre-edge values
		traffic_before_edge();
		if (armed && !finished) {
			if (top->arb_req) { if (top->ram_c_wait) acc_wait_seen = true; }
			if (acc_prev_req && !top->arb_req) { if (acc_wait_seen) acc_miss++; else acc_hit++; }
			if (!acc_prev_req && top->arb_req) acc_wait_seen = false;
			acc_prev_req = top->arb_req;
			idle++;
			int slot = top->adpcm_slot;
			if (slot != p_slot && p_slot == 3 && p_req && p2_req) {
				idle = 0;
				if (got == 0) start_addr = p_a;
				if (got < (long)gold.size()) {
					if (p_di == gold[got]) matched++; else if (first_bad < 0) first_bad = got;
				} else extra++;
				got++;
				fprintf(pcm_out, "%d\n", (int16_t)top->ad_s);
			}
			if (got >= (long)gold.size()) after_end++;
			if ((got >= (long)gold.size() && after_end >= EXTRA_CYC) || idle >= STALL_CYC) finished = true;
		}
		p2_req = p_req; p_slot = top->adpcm_slot; p_req = top->adpcm_req;
		p_a = top->adpcm_a; p_di = top->adpcm_di;
	};
	auto run = [&](int n) { for (int i = 0; i < n; i++) { observe(); cyc(); } };

	for (auto &a : regs) {
		// line the strobe up with a CPU_CE edge, as the GHDL testbench does
		while (true) { observe(); if (cpu_ce_div == 5) break; cyc(); }
		top->ext_a = (0xFF << 13) | (0x18 << 8) | a.reg;
		if (a.k == 'R') top->ext_rd_n = 0;
		else {
			int v = a.val;
			if (fast && a.reg == 0xE) v = 0x0F;
			top->ext_di = v; top->ext_wr_n = 0;
			if (a.reg == 0xD && (v & 0x20)) armed = true;
		}
		cyc();
		top->ext_wr_n = 1; top->ext_rd_n = 1;
		if (g_cpu_fetches > 0) {
			// N sequential fetches from CD-RAM, each held until the arbiter answers
			for (int f = 0; f < g_cpu_fetches; f++) {
				top->cd_ram_a = 0x210000 | ((0x100 + f) & 0x3FFFF); top->cd_ram_rd = 1;
				int guard = 0;
				do { observe(); cyc(); } while (!top->cd_ram_rdy && ++guard < 100000);
				observe(); cyc();
				top->cd_ram_rd = 0;
				for (int i = 0; i < 5; i++) { observe(); cyc(); }   // CPU cycle without memory access
			}
		} else {
			run(300);
		}
	}
	while (!finished) run(1000);
	fprintf(pcm_out, "%d\n", (int16_t)top->ad_s);
	fclose(pcm_out);

	printf("RESULT golden=%zu consumed=%ld matched=%ld first_mismatch_at=%ld played_past_end=%ld start_nibble_addr=0x%05lX\n",
	       gold.size(), got, matched, first_bad, extra, start_addr < 0 ? 0 : start_addr);
	printf("  port C accesses during playback: %ld cache HITS (WAIT never rose), %ld misses\n", acc_hit, acc_miss);
	if (idle >= STALL_CYC) printf("  STOPPED: no nibble consumed for STALL_CYC cycles\n");
	printf("%s\n", (got == (long)gold.size() && matched == (long)gold.size() && extra == 0) ? "PASS" :
	       (matched == (long)gold.size() && extra == 1 ? "FAIL (known: 1-nibble overrun only)" : "FAIL"));
	delete top;
	return 0;
}
