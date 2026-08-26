// PCE video to HDMI via a line-doubling scandoubler -- new sibling to pce2hdmi.sv, not a
// replacement. Used only by pcetang_console60k_cd.vhd's video path (see
// docs/OVERHEAD.md sections 5-7 for the full real research and measurement history
// behind this file). Does NOT touch pce2hdmi.sv, the three tracked Phase 1 board tops,
// or any file under src/hdmi2/ -- the shared `hdmi` core already supports
// VIDEO_ID_CODE=2 (720x480p60) unmodified (Nano 20K already uses it), so this stays
// fully additive.
//
// WHY THIS EXISTS: pce2hdmi.sv's full-frame capture buffer measured ~19-33 real BSRAM
// blocks (docs/OVERHEAD.md section 1 and the Console 60K legal-stub A/B: 115/118 at
// 256x224 vs 82/118 at 64x64, same 16KB-ADPCM baseline). A 2-line ping-pong buffer
// (this file) measures ~1 block by construction (2*1024 entries x 9 bits = 18432 bits
// = one 18Kbit BSRAM block), freeing enough real capacity for full 64KB ADPCM_DRAM
// fidelity instead of the reduced 16KB build.
//
// WHY A FIXED OUTPUT CLOCK WORKS DESPITE PCE'S VARIABLE DOT CLOCK: read huc6260.vhd
// directly (docs/OVERHEAD.md section 6) -- H_CNT/V_CNT (and therefore real-world
// scanline/frame duration) are driven purely by the master clock and are the same
// regardless of DOTCLOCK (256/336/512-wide modes); DOTCLOCK only changes how often
// CLKEN pulses within that fixed window. A buffer indexed by CLKEN pulses, read back
// at one fixed output rate, needs no per-mode reconfiguration -- including mid-frame
// mode switches, since each line's real captured width is measured and stretched
// independently (below), not assumed constant.
//
// REAL PRECEDENT: MiSTle-Dev/FPGA-Companion's MiSTeryNano (same Tang board family --
// Console 60K, Primer 25K, Mega 138K) uses exactly this line-doubling technique for
// Atari ST (src/misc/scandoubler.v, a 2-line ping-pong buffer, real source read
// directly). This file is not a port of that RTL -- PCE's variable dot clock needs the
// per-line width tracking below, which Atari ST's simpler fixed-mode video doesn't --
// but the core idea (line-rate doubling instead of full-frame capture-and-scale) is
// the same, verified real, working technique on this same board family.
//
// NOT VERIFIED ON HARDWARE OR IN SIMULATION. This project has no video simulation
// environment; real gw_sh only proves synthesis/timing/resource closure, not a correct
// picture -- same caveat as pce2hdmi.sv's own first cut.

`timescale 1ns / 1ps

module pce2hdmi_sd #(
	parameter MAX_LINE_SAMPLES = 540,  // DISP_CLOCKS(2160)/min CLKEN divisor(4, 512-wide
	                                    // mode) -- real max from huc6260.vhd, not guessed
	parameter VIDEOID       = 2,       // CEA-861 720x480p60 -- shared hdmi core, unmodified
	parameter VIDEO_REFRESH = 60.0,
	parameter CLKFRQ        = 27000,   // kHz
	parameter SCREEN_WIDTH  = 720,
	parameter SCREEN_HEIGHT = 480
) (
	input clk,          // PCE core clock (CLK into pce_top.vhd), source/write domain
	input resetn,

	// pce_top.vhd video signals, direct -- same ports pce2hdmi.sv already consumes
	input [2:0] video_r,
	input [2:0] video_g,
	input [2:0] video_b,
	input       video_ce,   // dot-clock enable: video_r/g/b valid this cycle
	input       video_hs,
	input       video_vs,
	input       video_hbl,
	input       video_vbl,

	// overlay interface (OSD) -- kept for interface parity with pce2hdmi.sv; the
	// overlay coordinate space here is the doubled 720x480 output, not a captured
	// framebuffer's own coordinates (there is no framebuffer to index).
	input overlay,
	output [7:0] overlay_x,
	output [7:0] overlay_y,
	input [14:0] overlay_color, // BGR5

	// video clocks -- output/read domain, genuinely asynchronous to clk (real CDC,
	// same class of crossing pce2hdmi.sv's own dual-port mem_portA/mem_portB already
	// has, and the same clk_pce/clk_pixel asynchronous SDC group already declared for
	// every board's real, proven .sdc file)
	input clk_pixel,
	input clk_5x_pixel,

	// pce_top.vhd audio outputs, direct -- observability test only (2026-08-26): makes
	// PSG/CDDA/ADPCM real, live logic instead of dead-code-swept, so this file's real
	// BSRAM/Logic cost can be measured on a design that isn't silent. Summed, not
	// mixed correctly -- see docs/ARCHITECTURE.md's audio-observability section.
	input signed [15:0] psg_sl, psg_sr, cdda_sl, cdda_sr, adpcm_s,

	output       tmds_clk_n,
	output       tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p
);

localparam AUDIO_BIT_WIDTH = 16;
localparam AUDIO_RATE = 48000;
localparam LINE_ABITS = $clog2(MAX_LINE_SAMPLES);   // 10 bits for 540

wire [9:0] cy, frameHeight;
wire [10:0] cx, frameWidth;

//
// ==================== Write side: clk (clk_pce) domain ====================
//
// 2-line ping-pong buffer, ~1 BSRAM block (2 * 2**LINE_ABITS entries x 9 bits =
// 2*1024*9 = 18432 bits = one 18Kbit block). Indexed by a per-line sample counter
// (video_ce pulses within the active window), not by raw master-clock position --
// keeps the buffer small regardless of DOTCLOCK mode.
//
logic [8:0] sd_buffer [0:2*(2**LINE_ABITS)-1];   // 9-bit raw RGB (3/3/3), no palette
logic wr_line_toggle;
logic [LINE_ABITS-1:0] wr_cnt;
logic [LINE_ABITS-1:0] line_width [0:1];   // real captured sample count per buffer line,
                                            // latched at end of each source line -- this
                                            // is what lets mid-frame DOTCLOCK changes
                                            // (huc6260.vhd's real, live-reconfigurable
                                            // DOTCLOCK register) come through correctly:
                                            // each line is stretched by its OWN real
                                            // width, not a fixed assumption.

reg video_hs_r, video_vs_r;
always_ff @(posedge clk) begin
	video_hs_r <= video_hs;
	video_vs_r <= video_vs;

	if (video_hs & ~video_hs_r) begin              // new line
		line_width[wr_line_toggle] <= wr_cnt;      // latch this line's real sample count
		wr_line_toggle <= ~wr_line_toggle;
		wr_cnt <= 0;
	end else if (video_ce && ~video_hbl && ~video_vbl) begin
		if (wr_cnt < MAX_LINE_SAMPLES - 1) begin
			sd_buffer[{wr_line_toggle, wr_cnt}] <= {video_r, video_g, video_b};
			wr_cnt <= wr_cnt + 1'b1;
		end
	end
end

//
// ==================== Read side: clk_pixel domain ====================
//
// hdmi_inst below generates its own cx/cy for the full 720x480p60 raster (including
// blanking) -- same pattern pce2hdmi.sv already uses. Active window: real PCE active
// area (242 lines doubled = 484) is centered/cropped into the standard's 480 active
// lines (4-line real, documented, harmless overage -- see docs/OVERHEAD.md section 6's
// geometry check). Horizontal: each pair of output lines reads the SAME captured
// source line twice (line_toggle_out held for 2 output lines) -- real line-doubling,
// not vertical scaling -- and each source line's real captured width (line_width[])
// drives a Bresenham-style horizontal stretch to fill the active window, the same
// fixed-point technique pce2hdmi.sv already uses, just with a runtime-variable source
// width instead of a compile-time constant.
//
localparam XSTART = 0;
localparam XSTOP  = SCREEN_WIDTH;

// 2-flop synchronizer for the cross-clock-domain toggle bit -- wr_line_toggle changes
// once per source scanline (~15.7kHz), read here at clk_pixel (27MHz, ~1700 cycles of
// margin per source line) -- standard synchronizer discipline, not optional. The
// line_width[] array itself only needs to be stable by the time wr_line_toggle_sync
// settles, which it is given that same margin.
reg wr_line_toggle_meta, wr_line_toggle_sync;
always_ff @(posedge clk_pixel) begin
	wr_line_toggle_meta <= wr_line_toggle;
	wr_line_toggle_sync <= wr_line_toggle_meta;
end

reg [23:0] rgb;
reg active;
reg [LINE_ABITS-1:0] sx;                 // current source sample index within the line
reg [10:0] xcnt;
reg [9:0] out_line_pair;                 // output line / 2 -- which real source line
reg line_toggle_rd;
reg [LINE_ABITS-1:0] cur_line_width;     // latched from line_width[] at the start of
                                          // each output line pair -- CDC-crossed as a
                                          // slow-changing bus, same discipline as
                                          // vram0_cache's own registered crossings.
reg [9:0] cy_r;

wire [LINE_ABITS:0] mem_rd_addr = {line_toggle_rd, sx};
logic [8:0] sd_rdata;
always_ff @(posedge clk_pixel) sd_rdata <= sd_buffer[mem_rd_addr];

assign overlay_x = sx[7:0];
assign overlay_y = out_line_pair[7:0];

always @(posedge clk_pixel) begin
	reg active_t;
	reg [10:0] xcnt_next;

	active_t = 0;
	if (cx == XSTART) begin active_t = 1; active <= 1; end
	else if (cx == XSTOP) begin active_t = 0; active <= 0; end

	if (active_t | active) begin
		xcnt_next = xcnt + cur_line_width;
		xcnt <= xcnt_next;
		if (xcnt_next >= SCREEN_WIDTH) begin
			xcnt <= xcnt_next - SCREEN_WIDTH;
			sx <= sx + 1'b1;
		end
	end

	cy_r <= cy;
	if (cy != cy_r) begin
		// One real source line is read out over 2 output lines (line-doubling).
		// wr_line_toggle_sync just flipped to start writing the NEXT line, so the most
		// recently COMPLETED line is ~wr_line_toggle_sync -- read that one.
		if (cy[0] == 1'b0) begin
			line_toggle_rd  <= ~wr_line_toggle_sync;
			cur_line_width  <= line_width[~wr_line_toggle_sync];
			out_line_pair   <= out_line_pair + 1'b1;
		end
	end

	if (cx == 0) begin sx <= 0; xcnt <= 0; end
	if (cy == 0) begin out_line_pair <= 0; end
end

// 9-bit RGB (3/3/3) -> 24-bit, bit-replication expansion (r3,r3,r3[2:1]), not a
// palette step -- same technique pce2hdmi.sv uses for its default COLOR_BITS=3 case.
always @(posedge clk_pixel) begin
	if (active) begin
		if (overlay)
			rgb <= {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};
		else
			rgb <= { sd_rdata[8:6], sd_rdata[8:6], sd_rdata[8:7],
			         sd_rdata[5:3], sd_rdata[5:3], sd_rdata[5:4],
			         sd_rdata[2:0], sd_rdata[2:0], sd_rdata[2:1] };
	end else
		rgb <= 24'h101010;
end

// Observability wiring, not a real mixer -- summed with wraparound, no clipping, no
// real resampling to AUDIO_RATE. Enough to make PSG/CDDA/ADPCM live logic for a real
// gw_sh resource measurement; audio correctness is unstarted work (see
// docs/ARCHITECTURE.md).
logic clk_audio;
assign clk_audio = clk_pixel;
reg [15:0] audio_sample_word [1:0];
always_ff @(posedge clk_audio) begin
	audio_sample_word[0] <= psg_sl + cdda_sl + adpcm_s;
	audio_sample_word[1] <= psg_sr + cdda_sr + adpcm_s;
end

logic[2:0] tmds;
wire tmdsClk;

hdmi #( .VIDEO_ID_CODE(VIDEOID),
        .DVI_OUTPUT(0),
        .VIDEO_REFRESH_RATE(VIDEO_REFRESH),
        .IT_CONTENT(1),
        .AUDIO_RATE(AUDIO_RATE),
        .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
        .START_X(0),
        .START_Y(0) )
hdmi_inst( .clk_pixel_x5(clk_5x_pixel),
        .clk_pixel(clk_pixel),
        .clk_audio(clk_audio),
        .rgb(rgb),
        .reset(0),
        .audio_sample_word(audio_sample_word),
        .tmds(tmds),
        .tmds_clock(tmdsClk),
        .cx(cx),
        .cy(cy),
        .frame_width(frameWidth),
        .frame_height(frameHeight) );

ELVDS_OBUF tmds_bufds [3:0] (
	.I({clk_pixel, tmds}),
	.O({tmds_clk_p, tmds_d_p}),
	.OB({tmds_clk_n, tmds_d_n})
);

endmodule
