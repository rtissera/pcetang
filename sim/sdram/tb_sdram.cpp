// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Romain Tisserand
//
// Does sdram.sv lose a port-C write when ports A and B contend?
//
// Port C carries CD-RAM. sdram.sv's own header states the priority chain is
// refresh > A > B > C, so C is the LOWEST priority client, and on hardware the system
// card writes ~61 KB of game code through it while the VDC (A) and ROM (B) are live.
// The board's 256 KiB CD-RAM self-test sweeps with the core HALTED -- no A traffic, no B
// traffic -- so it passes (0 bad) whether or not this failure mode exists. This is the
// test that can actually see it.
//
// Phase 1  port C alone, write then read back.        Sanity: the model and the
//                                                     controller agree at all.
// Phase 2  port C writes with A and B hammering.      The question under test.
// Phase 3  read every phase-2 address back, quiet.    Separates "write was lost" from
//                                                     "read returned the wrong thing".
#include <verilated.h>
#include "Vtb_sdram_top.h"
#include <cstdio>
#include <cstdlib>
#include <map>
#include <vector>

static Vtb_sdram_top *dut;
static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static void tick() {
	dut->clk = 0; dut->eval();
	dut->clk = 1; dut->eval();
	main_time++;
}

// CD-RAM window base used by the board (CDRAM_SDRAM_BASE in pcetang_console60k_cd.vhd)
static const uint32_t CDRAM_BASE = 0x040000;
static const uint32_t AC_BASE    = 0x200000;   // port A traffic lives elsewhere
static const uint32_t ROM_BASE   = 0x400000;   // port B

// One port-C access. RD_n is INVERTED on this controller: RD_n=1 means WRITE
// (sdram.sv:572 `we <= RAM_C_RD_n`). That inversion is the polarity bug already fixed in
// the board top level; the testbench must follow the module's real convention, not the
// intuitive one, or it tests nothing.
static int c_access(uint32_t addr, bool is_write, uint8_t din, uint8_t *dout,
                    bool keep_ab_busy, int timeout = 4000) {
	dut->RAM_C_ADDR = addr;
	dut->RAM_C_RD_n = is_write ? 1 : 0;
	dut->RAM_C_DI   = din;
	dut->RAM_C_REQ  = 1;
	int n = 0;
	// WAIT rises while the access is in flight and falls when it completes.
	while (n < timeout) {
		if (keep_ab_busy) {
			dut->RAM_A_REQ = 1;
			dut->RAM_A_ADDR = AC_BASE + ((n * 2) & 0xFFFF);
			dut->RAM_A_RD_n = 1;           // port A convention: 1 = read on this port
			dut->RAM_B_REQ = !dut->RAM_B_REQ;
			dut->RAM_B_ADDR = ROM_BASE + ((n * 3) & 0xFFFF);
			dut->RAM_B_WE = 0;
		}
		tick(); n++;
		if (n > 2 && !dut->RAM_C_WAIT) break;
	}
	if (dout) *dout = dut->RAM_C_DO;
	dut->RAM_C_REQ = 0;
	tick();
	return n >= timeout ? -1 : n;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	dut = new Vtb_sdram_top;

	dut->init = 1; dut->RAM_A_REQ = 0; dut->RAM_B_REQ = 0; dut->RAM_C_REQ = 0;
	dut->RAM_A_RD_n = 1; dut->RAM_B_WE = 0; dut->RAM_C_RD_n = 1;
	dut->RAM_A_ADDR = dut->RAM_B_ADDR = dut->RAM_C_ADDR = 0;
	dut->RAM_A_DI = dut->RAM_B_DI = dut->RAM_C_DI = 0;
	for (int i = 0; i < 100; i++) tick();
	dut->init = 0;
	for (int i = 0; i < 20000; i++) tick();   // controller's own init sequence

	const int N = 2048;                        // one sector's worth
	std::map<uint32_t, uint8_t> expect;

	// ---------------- Phase 1: port C alone ----------------
	int p1_bad = 0, p1_to = 0; long p1_cyc = 0; int p1_n = 0;
	for (int i = 0; i < 256; i++) {
		uint32_t a = CDRAM_BASE + i;
		uint8_t  v = (uint8_t)(i ^ 0x5A);
		int r = c_access(a, true, v, nullptr, false);
		if (r < 0) { p1_to++; continue; }
		p1_cyc += r; p1_n++;
		expect[a] = v;
	}
	for (int i = 0; i < 256; i++) {
		uint32_t a = CDRAM_BASE + i; uint8_t got = 0;
		if (c_access(a, false, 0, &got, false) < 0) { p1_to++; continue; }
		if (got != expect[a]) {
			if (p1_bad < 8) printf("  P1 MISMATCH a=0x%06X wrote=%02X read=%02X\n",
			                       a, expect[a], got);
			p1_bad++;
		}
	}
	printf("PHASE 1 (port C alone):      %d mismatches, %d timeouts of 256\n", p1_bad, p1_to);
	if (p1_bad || p1_to) {
		printf("  -> model/controller disagree with no contention at all; phases 2-3 are\n"
		       "     not interpretable until this is 0/0. Fix the harness, not the RTL.\n");
		delete dut; return 2;
	}

	// ---------------- Phase 2: port C under A+B contention ----------------
	std::vector<uint32_t> addrs;
	int p2_to = 0, p2_rb = 0; long p2_cyc = 0; int p2_n = 0;
	for (int i = 0; i < N; i++) {
		uint32_t a = CDRAM_BASE + 0x1000 + i;
		uint8_t  v = (uint8_t)((i * 7) ^ 0x3C);
		int r = c_access(a, true, v, nullptr, true);
		if (r < 0) { p2_to++; continue; }
		p2_cyc += r; p2_n++;
		expect[a] = v; addrs.push_back(a);
	}
	// CONTENTION CHECK. A negative result ("no writes lost") means nothing unless port C
	// was actually made to wait. If these two averages are equal, ports A and B were not
	// contending and phases 2-3 tested the same quiet path as phase 1.
	double a1 = p1_n ? (double)p1_cyc / p1_n : 0, a2 = p2_n ? (double)p2_cyc / p2_n : 0;
	printf("PHASE 2 (C writes, A+B busy): %d timeouts of %d writes issued\n", p2_to, N);
	printf("  contention check: port C took %.1f cycles/access quiet vs %.1f with A+B busy"
	       " (%.2fx)%s\n", a1, a2, a1 > 0 ? a2 / a1 : 0.0,
	       (a2 <= a1 * 1.05) ? "   <-- NOT CONTENDING, result is meaningless" : "");

	// ---------------- Phase 3: quiet read-back ----------------
	int p3_bad = 0, p3_to = 0, poison = 0;
	for (uint32_t a : addrs) {
		uint8_t got = 0;
		if (c_access(a, false, 0, &got, false) < 0) { p3_to++; continue; }
		if (got != expect[a]) {
			// the model returns a per-address poison pattern for a cell never written
			uint8_t pois = (uint8_t)(((a & 0x3FFF) ^ 0xA5A5) & 0xFF);
			if (got == pois) poison++;
			if (p3_bad < 12) printf("  P3 MISMATCH a=0x%06X wrote=%02X read=%02X%s\n",
			                        a, expect[a], got, got == pois ? "  (NEVER WRITTEN)" : "");
			p3_bad++;
		}
		p2_rb++;
	}
	printf("PHASE 3 (quiet read-back):   %d mismatches of %d (%d never written), %d timeouts\n",
	       p3_bad, p2_rb, poison, p3_to);

	printf("\nRESULT: %s\n", (p3_bad == 0 && p2_to == 0 && p3_to == 0)
		? "sdram.sv did NOT lose a port-C write under A+B contention."
		: "sdram.sv LOST port-C data under contention -- see mismatches above.");
	delete dut;
	return (p3_bad || p2_to || p3_to) ? 1 : 0;
}
