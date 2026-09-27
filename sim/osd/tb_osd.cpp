// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Romain Tisserand
//
// OSD end to end under the exact lock: every displayed pixel of the OSD is compared with
// the ideal 256 x 224 grid stretched over the screen, X = (cx - x_start) * 256 / act_w and
// Y = cy * 224 / 480, using dpb_stub.v's pattern. The pipeline delay between the raster
// position and rgb is found, not assumed: the best of several candidates is reported.
#include "Vtb_osd_top.h"
#include "Vtb_osd_top___024root.h"
#include "verilated.h"
#include <cstdio>
static const int SRC_LINE_CLK = 2730, SRC_LINES = 263, SRC_ACTIVE = 242, SRC_PIXELS = 341;
static bool lit(int X, int Y) { return (X & 7) == ((((X >> 3) + (Y >> 3)) + (Y & 7)) & 7); }
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    auto *t = new Vtb_osd_top;
    long long t_pce = 0, t_pix = 0, src_clk = 0, n = 0;
    int frames = 0, prev_cy = -1;
    const int ND = 8;                 // candidate delays 0..7 pixels
    long bad[ND] = {0}, checked = 0;
    int hist_cx[16] = {0}, hist_cy[16] = {0}, hist_ox[16] = {0}, hist_oy[16] = {0}, hp = 0;
    long badA[ND] = {0}, checkedA = 0, mapoff = 0, mapchk = 0, xoff[7] = {0}, yoff = 0; int badrow[256] = {0}, badcol[256] = {0};
    t->resetn = 0;
    while (frames < 12) {
        if (t_pce <= t_pix) {
            t->clk = 0; t->eval();
            int x = src_clk % SRC_LINE_CLK, y = (src_clk / SRC_LINE_CLK) % SRC_LINES;
            t->video_hs = x < 64; t->video_hbl = (x < 100) || (x >= 100 + SRC_PIXELS * 8);
            t->video_vbl = y >= SRC_ACTIVE; t->video_vs = (y >= SRC_ACTIVE + 3) && (y < SRC_ACTIVE + 6);
            t->video_ce = (x % 8) == 0; t->video_r = t->video_g = t->video_b = 0;
            t->resetn = n > 100;
            t->clk = 1; t->eval(); src_clk++; n++; t_pce += 22;
        } else {
            t->clk_pixel = 0; t->eval(); t->clk_pixel = 1; t->eval();
            auto *r = t->rootp;
            int cx = r->tb_osd_top__DOT__u__DOT__cx, cy = r->tb_osd_top__DOT__u__DOT__cy_dbg;
            int xs = r->tb_osd_top__DOT__u__DOT__x_start, aw = r->tb_osd_top__DOT__u__DOT__act_w;
            int rgb = r->tb_osd_top__DOT__u__DOT__rgb;
            bool shown = (rgb & 0xffffff) != 0;
            int ox = r->tb_osd_top__DOT__ox, oy = r->tb_osd_top__DOT__oy;
            static int ld = 0;
            if (cy >= 524 && cx >= 854 && ld < 10) { ld++; printf("LEADIN cy=%d cx=%d osd_line=%d oy=%d osd_n=%d\n", cy, cx, (int)r->tb_osd_top__DOT__u__DOT__osd_line, oy, (int)r->tb_osd_top__DOT__u__DOT__osd_n); }
            hist_cx[hp & 15] = cx; hist_cy[hp & 15] = cy; hist_ox[hp & 15] = ox; hist_oy[hp & 15] = oy; hp++;
            // (B) mapping: the coordinate requested for pixel cx (2 clocks ahead) vs the ideal grid
            if (frames >= 8 && cy < 480 && cx >= xs && cx < xs + aw - 2) {
                int Y = cy * 224 / 480;
                mapchk++; if (oy != Y) yoff++;
                static int ydbg = 0;
                if (oy != Y && cx == 300 && ydbg == 0) printf("DBG x_start=%d frameW=%d frameH=%d osd_start=%d\n", xs, (int)r->tb_osd_top__DOT__u__DOT__frameWidth, (int)r->tb_osd_top__DOT__u__DOT__frameHeight, (int)r->tb_osd_top__DOT__u__DOT__osd_start);
                if (oy != Y && cx == 300 && ydbg < 2) { ydbg++; printf("YDBG frame=%d cy=%d oy=%d ideal=%d\n", frames, cy, oy, Y); }
                for (int k = 0; k < 7; k++) { int X = (cx - 3 + k - xs) * 256 / aw; if (cx - 3 + k < xs) X = -1; if (ox != X) xoff[k]++; }
            }
            if (frames >= 8 && cy < 480) {
                // (A) textdisp: did it draw what it was asked for, d clocks earlier?
                for (int d = 0; d < ND; d++) {
                    int qx = hist_ox[(hp - 1 - d) & 15], qy = hist_oy[(hp - 1 - d) & 15];
                    int qcx = hist_cx[(hp - 1 - d) & 15];
                    if (qcx < xs || qcx >= xs + aw) continue;
                    if (qx >= 92 && qx < 164 && qy >= 201 && qy < 215) continue;   // logo
                    if (lit(qx, qy) != shown) { badA[d]++; if (d == 3) { badrow[qy]++; badcol[qx & 7]++; } }
                    if (d == 0) checkedA++;
                }
                for (int d = 0; d < ND; d++) {
                    int pcx = hist_cx[(hp - 1 - d) & 15], pcy = hist_cy[(hp - 1 - d) & 15];
                    if (pcy >= 480 || pcx < xs + 1 || pcx >= xs + aw - 1) continue;
                    int X = (pcx - xs) * 256 / aw, Y = pcy * 224 / 480;
                    if (lit(X, Y) != shown) bad[d]++;
                }
                checked++;
            }
            if (cy == 0 && prev_cy != 0) frames++;
            prev_cy = cy; t_pix += 35;
        }
    }
    int bA = 0; for (int d = 1; d < ND; d++) if (badA[d] < badA[bA]) bA = d;
    printf("(A) textdisp vs requested: checked=%ld best delay=%d mismatches=%ld (%.3f%%)\n", checkedA, bA, badA[bA], 100.0 * badA[bA] / checkedA);
    int bk = 0; for (int k = 1; k < 7; k++) if (xoff[k] < xoff[bk]) bk = k;
    printf("(B) y vs cy*224/480: off=%ld of %ld | x vs ideal, best shift %d: off=%ld\n", yoff, mapchk, bk - 3, xoff[bk]);
    printf("    (A) bad by font column x%%8:"); for (int i = 0; i < 8; i++) printf(" %d", badcol[i]); printf("\n    rows with errors:");
    int shown_rows = 0; for (int i = 0; i < 256 && shown_rows < 20; i++) if (badrow[i]) { printf(" y%d:%d", i, badrow[i]); shown_rows++; } printf("\n");
    int best = 0; for (int d = 1; d < ND; d++) if (bad[d] < bad[best]) best = d;
    printf("OSD pixels checked=%ld  best delay=%d  mismatches=%ld (%.3f%%)\n", checked, best, bad[best], 100.0 * bad[best] / checked);
    delete t; return 0;
}
