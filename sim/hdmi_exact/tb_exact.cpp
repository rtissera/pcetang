// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Romain Tisserand
//
// Exact-lock (mode 200) phase test for pce2hdmi_sd.sv: does the picture come back after the
// source frame restarts at a different phase, as it does when a second game is loaded?
//
// Clocks are the Console 60K exact-lock ones, from one 940.625 MHz VCO: clk_pce = VCO/22,
// clk_pixel = VCO/35, so 2730 clk_pce = 1716 clk_pixel = two 858-pixel output lines. Time is
// kept in VCO periods, so the ratio is exact. Every source line carries its own 9-bit number
// (r,g,b = 3 bits each); each output frame the visible 480 rows are decoded and scored:
// a good frame shows >= 236 distinct source lines, in order, starting within 4 of line 0.
//
// From frame JUMP_AT, at the next source vblank line 250, the source is stalled for STALL
// clk_pce cycles (scored from 3 output frames after the source restarts): a core reset/reload, which freezes the source inside vblank and restarts it
// with the same active height, so nothing about the picture's size changes.
// Usage: tb_exact [frames] [jump_at] [stall]
#include "Vpce2hdmi_sd.h"
#include "Vpce2hdmi_sd___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <set>

static const int SRC_LINE_CLK = 2730, SRC_LINES = 263, SRC_PIXELS = 341;
static const int SRC_ACTIVE = getenv("SRC_ACTIVE") ? atoi(getenv("SRC_ACTIVE")) : 242;

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    int frames_wanted = argc > 1 ? atoi(argv[1]) : 12;
    int jump_at       = argc > 2 ? atoi(argv[2]) : 5;
    long stall        = argc > 3 ? atol(argv[3]) : 0;
    auto *dut = new Vpce2hdmi_sd;
    long long t_pce = 0, t_pix = 0, src_clk = 0, pce_edges = 0;
    long stall_left = 0; bool jumped = false; int resumed_frame = -1;
    dut->resetn = 0; dut->overlay = 0; dut->overlay_color = 0;

    int out_frames = 0, prev_cy = -1, bad_frames_after = 0, good_frames_after = 0, vresets = 0;
    std::set<int> seen; int first_src = -1, last_src = -1; bool ordered = true;
    int cur_line_src = -1;
    int osd_first_x = -1, osd_last_x = -1, osd_steps = 0, osd_prev_x = -1, osd_y0 = -1, osd_y479 = -1, osd_ymax = -1, osd_ymono = 1, osd_prev_y = -1;
    int osd_edge_lo = -1, osd_edge_hi = -1;

    while (out_frames < frames_wanted) {
        if (t_pce <= t_pix) {
            dut->clk = 0; dut->eval();
            if (!jumped && out_frames >= jump_at && stall > 0 && (src_clk / SRC_LINE_CLK) % SRC_LINES == 250 && src_clk % SRC_LINE_CLK == 0) { stall_left = stall; jumped = true; }
            int x = src_clk % SRC_LINE_CLK;
            int y = (src_clk / SRC_LINE_CLK) % SRC_LINES;
            dut->video_hs  = (x < 64);
            dut->video_hbl = (x < 100) || (x >= 100 + SRC_PIXELS * 8);
            dut->video_vbl = (y >= SRC_ACTIVE);
            dut->video_vs  = (y >= SRC_ACTIVE + 3) && (y < SRC_ACTIVE + 6);
            dut->video_ce  = ((x % 8) == 0) && !stall_left;
            int v = y & 511;
            dut->video_r = (v >> 6) & 7; dut->video_g = (v >> 3) & 7; dut->video_b = v & 7;
            dut->resetn = (pce_edges > 100);
            dut->clk = 1; dut->eval();
            if (stall_left) { if (--stall_left == 0) resumed_frame = out_frames; } else src_clk++;
            pce_edges++; t_pce += 22;
        } else {
            dut->clk_pixel = 0; dut->eval();
            dut->clk_pixel = 1; dut->eval();
            auto *r = dut->rootp;
            if (r->pce2hdmi_sd__DOT__vreset) vresets++;
            if (out_frames == 4) {
                int ox = r->pce2hdmi_sd__DOT__osd_x, oy = r->pce2hdmi_sd__DOT__osd_y;
                int cxx = r->pce2hdmi_sd__DOT__cx, cyy = r->pce2hdmi_sd__DOT__cy_dbg;
                int xs = r->pce2hdmi_sd__DOT__x_start, xe = r->pce2hdmi_sd__DOT__x_stop;
                if (cyy == 200) {
                    if (cxx == xs) osd_edge_lo = ox;
                    if (cxx == xe - 1) osd_edge_hi = ox;
                    if (cxx >= xs && cxx < xe) { if (osd_first_x < 0) osd_first_x = ox; if (ox != osd_prev_x && osd_prev_x >= 0) osd_steps++; osd_prev_x = ox; osd_last_x = ox; }
                }
                if (cxx == 100 && cyy < 480) {
                    if (cyy == 0) osd_y0 = oy;
                    if (cyy == 479) osd_y479 = oy;
                    if (oy > osd_ymax) osd_ymax = oy;
                    if (osd_prev_y >= 0 && cyy > 0 && oy < osd_prev_y) osd_ymono = 0;
                    osd_prev_y = oy;
                }
            }
            int cy = r->pce2hdmi_sd__DOT__cy_dbg;
            int cx = r->pce2hdmi_sd__DOT__cx;
            // sample the middle of each visible line
            if (cx == 429 && cy < 480) {
                int rgb = r->pce2hdmi_sd__DOT__rgb;
                bool lit = r->pce2hdmi_sd__DOT__active && r->pce2hdmi_sd__DOT__v_active;
                if (lit) {
                    int R = (rgb >> 21) & 7, G = (rgb >> 13) & 7, B = (rgb >> 5) & 7;
                    int s = (R << 6) | (G << 3) | B;
                    if (first_src < 0) first_src = s;
                    if (last_src >= 0 && s < last_src) ordered = false;
                    last_src = s; seen.insert(s);
                }
            }
            if (cy == 0 && prev_cy != 0) {             // output frame boundary
                if (out_frames >= 2) {
                    bool good = seen.size() >= (size_t)(SRC_ACTIVE - 6) && ordered && first_src >= 0 && first_src <= 4;
                    printf("act_h=%d aspect=%d armed=%d | frame %2d%s: distinct=%3zu first=%3d last=%3d ordered=%d vresets=%d %s\n",
                           (int)r->pce2hdmi_sd__DOT__act_h, (int)r->pce2hdmi_sd__DOT__aspect_valid, (int)r->pce2hdmi_sd__DOT__phase_armed, out_frames, (jumped && out_frames == jump_at) ? "*" : " ",
                           seen.size(), first_src, last_src, ordered, vresets, good ? "GOOD" : "BAD");
                    if (jumped && resumed_frame >= 0 && out_frames > resumed_frame + 2) { if (good) good_frames_after++; else bad_frames_after++; }
                }
                seen.clear(); first_src = last_src = -1; ordered = true; out_frames++;
            }
            prev_cy = cy;
            t_pix += 35;
        }
    }
    printf("OSD x: first %d last %d steps %d | OSD y: at cy0 %d at cy479 %d max %d monotonic %d | x at window edges %d..%d\n",
           osd_first_x, osd_last_x, osd_steps, osd_y0, osd_y479, osd_ymax, osd_ymono, osd_edge_lo, osd_edge_hi);
    printf("RESULT stall=%ld: after-jump good=%d bad=%d vresets=%d\n", stall, good_frames_after, bad_frames_after, vresets);
    delete dut;
    return 0;
}
