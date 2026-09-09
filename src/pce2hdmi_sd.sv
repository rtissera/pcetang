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
	output [2:0] tmds_d_p,

	// Debug probe for the VTOTAL servo below, read out over the board's opcode-9 RTL
	// trace channel. dbg_out_frame_tog is a 1-bit toggle (one flip per OUTPUT frame) so
	// the board can count output frames in its own clk_pce domain across a clean 1-bit
	// crossing; the other two are slow buses snapshotted once per output frame.
	output       dbg_out_frame_tog,
	output [9:0] dbg_vs_cy,
	output [7:0] dbg_vtotal_extra
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

//
// ==================== Audio ====================
//
// clk_audio was previously tied to clk_pixel, which is why there was no sound at all.
// Despite the name, hdmi2 never uses this as a clock -- every consumer edge-detects it
// in the clk_pixel domain:
//     always_ff @(posedge clk_pixel) if (clk_audio & ~clk_audio_old) ...
// (audio_clock_regeneration_packet.sv:28-31, packet_picker.sv:71-72; the one
// `posedge clk_audio` in the tree is commented out). So tying it to clk_pixel made that
// edge fire every other pixel clock -- an effective sample rate of ~37 MHz instead of
// 48 kHz, which puts the HDMI audio clock regeneration wildly out and produces silence.
//
// It only has to be a STROBE at the sample rate, so no divided clock net is needed.
// DERIVED from CLKFRQ, never hardcoded. This constant went stale twice as the Console
// 60K pixel clock was retuned, and then a hardcoded 1549 (right for that board's
// 74.375 MHz) silently broke the other two: Nano 20K and Primer 25K instantiate this
// module with NO generic map, so they run the defaults -- CLKFRQ = 27000 kHz -- and
// 27e6/1549 is 17.4 kHz, not 48 kHz. Deriving it from the parameter each board already
// passes correctly makes that class of mistake impossible:
//   Console 60K  74375 kHz / 48000 = 1549.47 -> 1549 -> 48.02 kHz  (+0.03%)
//   Nano/Primer  27000 kHz / 48000 =  562.50 ->  562 -> 48.04 kHz  (+0.09%)
// Both are far inside what the HDMI ACR N/CTS mechanism absorbs.
localparam int AUDIO_DIV = (CLKFRQ * 1000) / AUDIO_RATE;
logic [11:0] audio_div_cnt = 12'd0;
logic clk_audio;
always_ff @(posedge clk_pixel) begin
	if (audio_div_cnt == AUDIO_DIV-1) audio_div_cnt <= 12'd0;
	else                              audio_div_cnt <= audio_div_cnt + 1'b1;
end
// One clk_pixel cycle high per period: exactly one rising edge per sample, which is all
// the consumers look for.
assign clk_audio = (audio_div_cnt == 12'd0);

// Sampled on the strobe rather than clocked by it. psg_sl/sr are continuous values in
// the clk_pce domain, so this is a multi-bit crossing taken without a handshake: a
// sample straddling a PSG update can be momentarily wrong. That is a fraction of one
// sample at 48 kHz and inaudible, and the alternative (a full handshake per sample) is
// not worth the logic here -- but it is a real approximation, not a clean crossing.
// Summed with wraparound and no clipping, unchanged from before; with NO_CD=1 the cdda
// and adpcm terms are hard zero, so today this is PSG only.
reg [15:0] audio_sample_word [1:0];
always_ff @(posedge clk_pixel) begin
	if (clk_audio) begin
		audio_sample_word[0] <= psg_sl + cdda_sl + adpcm_s;
		audio_sample_word[1] <= psg_sr + cdda_sr + adpcm_s;
	end
end

logic[2:0] tmds;
wire tmdsClk;

//
// ==================== Frame-rate genlock (VTOTAL servo) ====================
//
// Without any lock the output raster free-runs and the source's frame slips past it
// continuously -- that is the rolling picture. The roll rate measures the rate error
// directly: at 74.375 MHz the output frame is 2.28 lines/frame shorter than the core's,
// = 137 lines/s, = 750/137 = 5.5 s for a full roll, which is exactly the period seen on
// hardware. Nothing else in the video path fixes this: the read side below latches
// `line_toggle_rd <= ~wr_line_toggle_sync`, i.e. it always shows whichever source line
// just finished, so the line buffer ALREADY absorbs the phase error line-by-line. The
// roll IS that slip. Only matching the frame PERIOD can hold the picture still.
//
// WHAT WAS TRIED AND WHY IT FAILED: restarting hdmi.sv's cx/cy on the source VSYNC.
// That forces the period, but cx/cy are not the only per-frame sequencer -- the video
// guard/preamble windows key off `frame_height - 1`, and the packet picker and audio
// clock regeneration pace off the same raster. Rewinding cx/cy alone left all of those
// stamping packets into a raster they no longer agreed with. Landing in blanking, the
// sink tolerated one malformed data island per frame (picture locked/dropped/re-locked);
// landing in active video it was a protocol violation and the sink dropped the link
// entirely (no signal at all). Chasing the pixel clock to make the reset land in
// blanking was treating the symptom.
//
// WHAT THIS DOES INSTEAD: leave the raster free-running and standard, and stretch the
// frame by a few BLANKING lines so its period matches the source's. hdmi.sv's
// `vtotal_extra` is added to frame_height itself, latched once per frame, so every
// sequencer in that module still sees one consistent, well-formed frame -- there is no
// reset anywhere and no mid-frame discontinuity. A VTOTAL of 750..760 is an ordinary
// thing for a source to send.
//
// REFERENCE EDGE: the falling edge of video_vbl -- huc6260.vhd drives VBL low exactly at
// V_CNT = TOP_BL_LINES, the first active line, once per frame. So "source active starts"
// is the event, and the target is output cy == 0, "output active starts". No guessing at
// the source's blanking length, and it tracks RVBL's 242/262-line switch for free.
//
// CONTROL LAW: err = (output cy when the source's active area started), taken as signed
// about the frame. Output frame period = 750 + extra lines; source period = 750 + m
// lines with m the (unknown, clock-dependent) mismatch. Setting extra = clamp(err,0,MAX)
// gives err_next = err + m - extra = m -- deadbeat, and the steady state is err = m,
// about 2 output lines. It self-calibrates: m never appears as a constant, so retuning
// the pixel clock cannot invalidate this the way it invalidated AUDIO_DIV twice.
// Pull-in from worst case (half a frame) takes 375/(MAX-m) ~ 47 frames, under a second.
localparam int VT_MAX_EXTRA = 10;

// 2026-09-09: the servo COMPUTES but does not ACT. Hardware evidence (debug.log's last
// 32 heartbeats from the black-screen run) proves the core was alive and emitting frames
// at 60.0 Hz with the VDC being written hard, so the black picture is the output raster,
// and the only thing that changed there is VTOTAL modulation. Driving hdmi.sv with a
// constant 0 restores the exact standard 750-line raster that is the only configuration
// on this board ever seen to put a picture on the screen, while the servo keeps running
// and reporting through dbg_vtotal_extra.
//
// So one run answers both questions at once:
//   picture returns (rolling ~5.5 s) -> VTOTAL modulation itself is what blanked the
//                                       sink; that approach is dead, go to a full
//                                       framebuffer (BSRAM is 67/118, 51 blocks free).
//   still black                      -> the fault is NOT the modulation but the
//                                       frame_height rewrite or something else entirely,
//                                       and the traced vs_cy/out-frame counts say which.
// Set to 1 to re-enable modulation once the above is settled.
localparam bit VT_SERVO_ACTS = 1'b0;

// Source domain: one toggle per frame at the start of the active area.
reg vbl_r;
reg src_act_tog = 1'b0;
always_ff @(posedge clk) begin
	vbl_r <= video_vbl;
	if (vbl_r & ~video_vbl) src_act_tog <= ~src_act_tog;
end

// Pixel domain: recover that event, sample the raster position, servo once per frame.
reg tog_meta, tog_sync, tog_prev;
reg [9:0] vs_cy;
reg       vs_seen = 1'b0;
reg [7:0] vtotal_extra = 8'd0;

always_ff @(posedge clk_pixel) begin
	reg signed [11:0] err;

	tog_meta <= src_act_tog;      // clk (clk_pce) -> clk_pixel, 2-flop synchroniser
	tog_sync <= tog_meta;
	tog_prev <= tog_sync;

	if (tog_sync ^ tog_prev) begin
		vs_cy   <= cy;
		vs_seen <= 1'b1;
	end

	// End of the output frame: the one instant vtotal_extra may change.
	if (cx == frameWidth - 1'b1 && cy == frameHeight - 1'b1) begin
		if (vs_seen) begin
			// Signed distance from the target (cy == 0), wrapped about the frame, so a
			// source that starts just BEFORE the output frame reads as a small negative
			// error rather than a nearly-full-frame positive one.
			err = (vs_cy <= frameHeight[9:1]) ? $signed({2'b0, vs_cy})
			                                  : $signed({2'b0, vs_cy}) - $signed({2'b0, frameHeight});
			vtotal_extra <= (err <= 0)             ? 8'd0
			              : (err >= VT_MAX_EXTRA)  ? 8'(VT_MAX_EXTRA)
			                                       : err[7:0];
		end
		vs_seen <= 1'b0;
		out_frame_tog <= ~out_frame_tog;   // one flip per output frame
		vs_cy_snap    <= vs_cy;            // snapshot at the same instant the servo acts
	end
end

reg out_frame_tog = 1'b0;
reg [9:0] vs_cy_snap = 10'd0;
assign dbg_out_frame_tog = out_frame_tog;
assign dbg_vs_cy         = vs_cy_snap;
assign dbg_vtotal_extra  = vtotal_extra;

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
        .vtotal_extra(VT_SERVO_ACTS ? vtotal_extra : 8'd0),
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
