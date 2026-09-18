// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Romain Tisserand
//
// Does the scandoubler ever show two different SOURCE lines inside one OUTPUT line?
//
// Every source line is filled with a single distinct value, so a correctly buffered output line
// must be constant from its first pixel to its last. A change mid-line means the writer got into
// the buffer the reader was reading -- the "scrambled line by line" seen on real hardware.
//
// Real clocks, Console 60K: clk_pce 42.857 MHz, clk_pixel 74.375 MHz, source 2730 clk_pce per
// line and 263 lines per frame (242 active), output raster 1650x750.
#include "Vpce2hdmi_sd.h"
#include "Vpce2hdmi_sd___024root.h"
#include "verilated.h"
#include <cstdio>
#include <map>

static const double T_PCE = 1.0 / 42.857e6, T_PIX = 1.0 / 74.375e6;
static const int SRC_LINE_CLK = 2730, SRC_LINES = 263, SRC_ACTIVE = 242, SRC_PIXELS = 341;

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    auto *dut = new Vpce2hdmi_sd;
    double t_pce = 0, t_pix = 0;
    long long pce_clk = 0;
    int src_x = 0, src_y = 0;
    int frames_wanted = argc > 1 ? atoi(argv[1]) : 3;

    dut->resetn = 0; dut->overlay = 0; dut->overlay_color = 0;
    int tears = 0, out_lines = 0, prev_cy = -1, line_val = -1; bool line_dirty = false;
    std::map<int,int> shown;          // source value -> how many output lines showed it
    std::map<int,int> tear_cy;        // where in the frame the torn lines are
    int last_frame = 0, frames = 0;

    while (frames < frames_wanted) {
        if (t_pce <= t_pix) {                       // ---- clk_pce edge: the source side
            dut->clk = 0; dut->eval();
            int x = pce_clk % SRC_LINE_CLK;
            src_y = (pce_clk / SRC_LINE_CLK) % SRC_LINES;
            dut->video_hs  = (x < 64);
            dut->video_hbl = (x < 100) || (x >= 100 + SRC_PIXELS * 8);
            dut->video_vbl = (src_y >= SRC_ACTIVE);
            dut->video_ce  = ((x % 8) == 0);
            // one distinct value per source line, in the low 3 bits of each channel
            int v = (src_y % 7) + 1;
            dut->video_r = v; dut->video_g = v; dut->video_b = v;
            dut->video_vs = (src_y >= SRC_ACTIVE + 3) && (src_y < SRC_ACTIVE + 6);
            dut->resetn = (pce_clk > 100);
            dut->clk = 1; dut->eval();
            pce_clk++; t_pce += T_PCE;
        } else {                                    // ---- clk_pixel edge: the display side
            dut->clk_pixel = 0; dut->eval();
            dut->clk_pixel = 1; dut->eval();
            int cy = dut->rootp->pce2hdmi_sd__DOT__cy_dbg;
            int active = dut->rootp->pce2hdmi_sd__DOT__active;
            int val = dut->rootp->pce2hdmi_sd__DOT__sd_rdata & 7;
            if (cy != prev_cy) {                    // new output line
                // Skip the first frame: the buffers start empty, so its lines are not
                // representative of steady state.
                if (frames >= 1) {
                    if (line_dirty) { tears++; tear_cy[prev_cy]++; }
                    if (line_val > 0) shown[line_val]++;
                    out_lines++;
                }
                if (cy == 0 && prev_cy > 0) frames++;
                prev_cy = cy; line_val = -1; line_dirty = false;
            }
            // Zeros are buffer entries never written yet (Verilator zero-init) and the
            // blanking margins of a short source line -- they are not evidence of tearing.
            if (active && val != 0) {
                if (line_val < 0) line_val = val;
                else if (val != line_val) line_dirty = true;
            }
            t_pix += T_PIX;
        }
    }
    printf("output lines: %d   TORN lines (two source lines inside one output line): %d (%.1f%%)\n",
           out_lines, tears, out_lines ? 100.0 * tears / out_lines : 0.0);
    std::map<int,int> dist;
    for (auto &kv : shown) dist[kv.second]++;
    printf("output lines per source value: ");
    for (auto &kv : dist) printf("%d->%dx  ", kv.first, kv.second);
    printf("\n");
    if (!tear_cy.empty()) {
        int lo = tear_cy.begin()->first, hi = tear_cy.rbegin()->first;
        printf("torn output lines span cy=%d..%d; first 12: ", lo, hi);
        int n = 0;
        for (auto &kv : tear_cy) { if (n++ >= 12) break; printf("%d ", kv.first); }
        printf("\n");
        int in_active = 0;
        for (auto &kv : tear_cy) if (kv.first < 720) in_active += kv.second;
        printf("of %d torn lines, %d are inside the 720 active output lines\n", tears, in_active);
    }
    printf("%s\n", tears == 0 ? "PASS: no line ever showed two source lines" : "FAIL: torn lines present");
    delete dut;
    return tears == 0 ? 0 : 1;
}
