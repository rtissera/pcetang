// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Romain Tisserand
//
// Render what the scandoubler actually puts on the wire, as images.
//
// Drives pce2hdmi_sd with a synthetic PC Engine frame (241 active lines of 341 pixels) whose
// content is deliberately hostile to line doubling: single-pixel horizontal stripes, a fine
// checker, and a diagonal. Captures the 720p output raster for several consecutive frames and
// writes them as PPM, plus a per-pixel difference between two frames -- that difference IS the
// shimmer, since a stable picture would produce a black difference image.
#include "Vpce2hdmi_sd.h"
#include "Vpce2hdmi_sd___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static const double T_PCE = 1.0/42.857e6, T_PIX = 1.0/74.375e6;
static const int SRC_LINE_CLK = 2730, SRC_LINES = 263, SRC_ACTIVE = 241, SRC_PIXELS = 341;
static const int OUT_W = 1650, OUT_H = 800;

struct Frame { std::vector<unsigned char> px = std::vector<unsigned char>(OUT_W*OUT_H*3, 0); };

static void write_ppm(const std::string &name, const Frame &f, int x0, int y0, int w, int h) {
    FILE *fp = fopen(name.c_str(), "wb");
    fprintf(fp, "P6\n%d %d\n255\n", w, h);
    for (int y = y0; y < y0+h; y++)
        fwrite(&f.px[(y*OUT_W + x0)*3], 1, w*3, fp);
    fclose(fp);
}

// PCE source pattern: 3-bit per channel, the worst case for vertical resampling
static void src_pixel(int x, int y, int &r, int &g, int &b) {
    if (y < 8)                       { r=g=b = (x/8)%2 ? 7 : 0; }        // vertical bars
    else if (y < 120)                { r = (y%2)?7:0; g = (y%2)?7:0; b = (y%2)?7:0; } // 1px stripes
    else if (y < 180)                { int c=((x/1)+(y/1))%2; r=c?7:0; g=c?7:0; b=0; } // checker
    else                             { int d = (x - (y-180)*2); r = (d%16<8)?7:0; g=0; b=(d%16<8)?0:7; }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::string tag = argc > 1 ? argv[1] : "out";
    auto *dut = new Vpce2hdmi_sd;
    double t_pce = 0, t_pix = 0;
    long long pce_clk = 0;
    int frames = 0, prev_cy = -1;
    std::vector<Frame> caps(3);
    dut->resetn = 0; dut->overlay = 0; dut->overlay_color = 0;

    while (frames < 6) {
        if (t_pce <= t_pix) {
            dut->clk = 0; dut->eval();
            int x = pce_clk % SRC_LINE_CLK;
            int sy = (pce_clk / SRC_LINE_CLK) % SRC_LINES;
            dut->video_hs  = (x < 64);
            int px_i = (x - 100) / 8;
            dut->video_hbl = (x < 100) || (px_i >= SRC_PIXELS);
            dut->video_vbl = (sy >= SRC_ACTIVE);
            dut->video_ce  = ((x % 8) == 0);
            int r=0,g=0,b=0;
            if (px_i >= 0 && px_i < SRC_PIXELS && sy < SRC_ACTIVE) src_pixel(px_i, sy, r,g,b);
            dut->video_r = r; dut->video_g = g; dut->video_b = b;
            dut->video_vs = (sy >= SRC_ACTIVE+3) && (sy < SRC_ACTIVE+6);
            dut->resetn = (pce_clk > 100);
            dut->clk = 1; dut->eval();
            pce_clk++; t_pce += T_PCE;
        } else {
            dut->clk_pixel = 0; dut->eval();
            dut->clk_pixel = 1; dut->eval();
            int cy = dut->rootp->pce2hdmi_sd__DOT__cy_dbg;
            int cx = dut->rootp->pce2hdmi_sd__DOT__cx_dbg;
            unsigned rgb = dut->rootp->pce2hdmi_sd__DOT__rgb;
            if (cy != prev_cy) { if (cy == 0 && prev_cy > 0) frames++; prev_cy = cy; }
            if (frames >= 3 && frames < 6 && cy < OUT_H && cx < OUT_W) {
                Frame &f = caps[frames-3];
                unsigned char *p = &f.px[(cy*OUT_W + cx)*3];
                p[0] = (rgb >> 16) & 0xff; p[1] = (rgb >> 8) & 0xff; p[2] = rgb & 0xff;
            }
            t_pix += T_PIX;
        }
    }
    // crop to the visible area: the picture sits inside the 1280x720 active window
    for (int i = 0; i < 3; i++)
        write_ppm(tag + "_frame" + std::to_string(i) + ".ppm", caps[i], 180, 0, 1000, 760);
    // difference between two frames = the shimmer
    Frame d;
    long changed = 0;
    for (size_t i = 0; i < d.px.size(); i++) {
        int v = abs((int)caps[0].px[i] - (int)caps[2].px[i]);
        d.px[i] = v ? 255 : 0;
        if (v) changed++;
    }
    write_ppm(tag + "_shimmer.ppm", d, 180, 0, 1000, 760);
    printf("%s: %ld of %zu subpixels differ between frame 0 and frame 2 (%.2f%%)\n",
           tag.c_str(), changed, d.px.size(), 100.0*changed/d.px.size());
    delete dut;
    return 0;
}
