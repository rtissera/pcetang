// PCE video to HDMI converter -- first cut, 2026-08-26.
//
// New file, not a port -- PCE's HuC6260 VCE outputs raw 9-bit RGB (VIDEO_R/G/B, 3 bits
// each) directly, no palette-index step like NES's PPU, and pce_top.vhd exposes no
// pre-counted cycle/scanline like nestang's PPU wrapper does -- x/y position here is
// derived from VIDEO_CE (dot-clock enable pulse) gated by VIDEO_HBL/VIDEO_VBL
// (blanking), reset on VIDEO_HS/VIDEO_VS edges. Structurally the same idea as
// nand2mario's nes2hdmi.sv (BRAM frame buffer written in the core clock domain, read
// back with fixed-point nearest-neighbor scaling in the HDMI pixel clock domain), not
// copied from it -- the capture side is genuinely different.
//
// KNOWN FIRST-CUT LIMITATION: frame buffer is sized for PCE's most common 256x224 mode.
// Real PCE hardware also has 336- and 512-dot horizontal modes and taller vertical
// modes some games use -- those will crop/alias here, not corrupt or crash. Widening
// this is real follow-up work once something is on screen at all, not done here.
//
// NOT VERIFIED ON HARDWARE. First `gw_sh` attempt is the point of this file existing at
// this stage -- a clean synthesis is not the same as a correct picture.

`timescale 1ns / 1ps

module pce2hdmi (
	input clk,          // PCE core clock (CLK into pce_top.vhd)
	input resetn,

	// pce_top.vhd video signals, direct
	input [2:0] video_r,
	input [2:0] video_g,
	input [2:0] video_b,
	input       video_ce,   // dot-clock enable: video_r/g/b valid this cycle
	input       video_hs,
	input       video_vs,
	input       video_hbl,
	input       video_vbl,

	// overlay interface (OSD)
	input overlay,
	output [7:0] overlay_x,
	output [7:0] overlay_y,
	input [14:0] overlay_color, // BGR5

	// video clocks
	input clk_pixel,
	input clk_5x_pixel,

	// output signals
	output       tmds_clk_n,
	output       tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p
);

localparam FRAMEWIDTH  = 1280;
localparam FRAMEHEIGHT = 720;
localparam VIDEOID     = 4;
localparam VIDEO_REFRESH = 60.0;
localparam CLKFRQ = 74250;
localparam AUDIO_BIT_WIDTH = 16;
localparam AUDIO_RATE = 48000;

wire [9:0] cy, frameHeight;
wire [10:0] cx, frameWidth;

//
// Capture: pce_top's own clk domain. video_hs/vs reset the active-area counters;
// video_ce + not(hbl/vbl) gates a real pixel write.
//
localparam CAP_WIDTH  = 256;
localparam CAP_HEIGHT = 224;
localparam MEM_DEPTH  = CAP_WIDTH * CAP_HEIGHT;

logic [8:0] mem [0:MEM_DEPTH-1];    // 9-bit raw RGB (3/3/3), no palette step needed
logic [15:0] mem_portA_addr;
logic [8:0]  mem_portA_wdata;
logic        mem_portA_we;

wire [15:0] mem_portB_addr;
logic [8:0] mem_portB_rdata;

always_ff @(posedge clk) begin
	if (mem_portA_we) mem[mem_portA_addr] <= mem_portA_wdata;
end
always_ff @(posedge clk_pixel) begin
	mem_portB_rdata <= mem[mem_portB_addr];
end

reg [8:0] cap_x, cap_y;
reg video_hs_r, video_vs_r;
always @(posedge clk) begin
	video_hs_r <= video_hs;
	video_vs_r <= video_vs;
	mem_portA_we <= 1'b0;

	if (video_vs & ~video_vs_r) begin              // new frame
		cap_y <= 0;
	end
	if (video_hs & ~video_hs_r) begin              // new line
		cap_x <= 0;
		if (~video_vbl && cap_y < CAP_HEIGHT - 1) cap_y <= cap_y + 1;
	end
	if (video_ce && ~video_hbl && ~video_vbl) begin
		if (cap_x < CAP_WIDTH) begin
			mem_portA_addr <= cap_y * CAP_WIDTH + cap_x;
			mem_portA_wdata <= {video_r, video_g, video_b};
			mem_portA_we <= 1'b1;
			cap_x <= cap_x + 1;
		end
	end
end

//
// Scale CAP_WIDTHxCAP_HEIGHT to 1280x720, 4:3 windowed -- same fixed-point approach as
// nand2mario's nes2hdmi.sv (Bresenham-style scaling counters), sized for this capture.
//
reg [23:0] rgb;
reg active;
reg [$clog2(CAP_WIDTH)-1:0] xx;
reg [$clog2(CAP_HEIGHT)-1:0] yy;
reg [10:0] xcnt, ycnt;
reg [9:0] cy_r;
assign mem_portB_addr = yy * CAP_WIDTH + xx;
assign overlay_x = xx;
assign overlay_y = yy;
localparam XSTART = (1280 - 960) / 2;
localparam XSTOP  = (1280 + 960) / 2;

always @(posedge clk_pixel) begin
	reg active_t;
	reg [10:0] xcnt_next, ycnt_next;
	xcnt_next = xcnt + CAP_WIDTH;
	ycnt_next = ycnt + CAP_HEIGHT;

	active_t = 0;
	if (cx == XSTART - 1) begin active_t = 1; active <= 1; end
	else if (cx == XSTOP - 1) begin active_t = 0; active <= 0; end

	if (active_t | active) begin
		xcnt <= xcnt_next;
		if (xcnt_next >= 960) begin xcnt <= xcnt_next - 960; xx <= xx + 1; end
	end

	cy_r <= cy;
	if (cy[0] != cy_r[0]) begin
		ycnt <= ycnt_next;
		if (ycnt_next >= 720) begin ycnt <= ycnt_next - 720; yy <= yy + 1; end
	end

	if (cx == 0) begin xx <= 0; xcnt <= 0; end
	if (cy == 0) begin yy <= 0; ycnt <= 0; end
end

// 9-bit RGB (3/3/3) -> 24-bit, bit-replication expansion (r3,r3,r3[2:1]), not a palette
always @(posedge clk_pixel) begin
	if (active) begin
		if (overlay)
			rgb <= {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};
		else
			rgb <= { {mem_portB_rdata[8:6]}, {mem_portB_rdata[8:6]}, mem_portB_rdata[8:7],
			         {mem_portB_rdata[5:3]}, {mem_portB_rdata[5:3]}, mem_portB_rdata[5:4],
			         {mem_portB_rdata[2:0]}, {mem_portB_rdata[2:0]}, mem_portB_rdata[2:1] };
	end else
		rgb <= 24'h101010;
end

// Silent audio for this first cut -- PCE's PSG_SL/SR + CDDA_SL/SR + ADPCM_S mixing into
// one stereo pair is real, separate work, not done here.
logic clk_audio = 0;
reg [15:0] audio_sample_word [1:0];
initial begin audio_sample_word[0] = 0; audio_sample_word[1] = 0; end

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
