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
// ==================== 4:3 aspect ====================
//
// The PC Engine displays 4:3 regardless of which dot clock it is in -- 256, 341 and 512
// wide all map to the same 4:3 screen -- and the Bresenham stretch below already handles
// that correctly by mapping whatever width was captured into a fixed rectangle. Only the
// rectangle was wrong: it was the full 1280, so the picture came out at roughly 16:9.
//
// The height is MEASURED rather than assumed, for the same reason the VTOTAL loop
// measures: huc6260's DISP_LINES is 242 or 231 depending on RVBL, so any hardcoded width
// is wrong by 5% in the other mode. One source line lasts 2730/42.857e6 s and one output
// line 1650/74.375e6 s, a ratio of 2.8713, so 242 active source lines occupy 694.9 output
// lines and the matching 4:3 width is 926.6. Counting output lines while the source is in
// its active area gives that height directly, and the width follows as height * 4/3.
//
// This changes only WHERE pixels are drawn. cx/cy, frame_height, the VTOTAL servo, the
// packet sequencers and the audio path are all untouched, so HDMI lock cannot regress.
// Set ASPECT_4_3 to 0 to get the previous full-width stretch back.
localparam bit ASPECT_4_3 = 1'b1;

reg  [10:0] x_start = 11'd0;
reg  [10:0] x_stop  = 11'(SCREEN_WIDTH);
reg  [10:0] act_w   = 11'(SCREEN_WIDTH);   // Bresenham denominator
reg  [10:0] act_h   = 11'd695;             // measured, seeded with the 242-line value

// video_vbl is low over the source's active area (huc6260 clears VBL_FF at the first
// active line). Cross it into clk_pixel and count output lines across that window.
reg  vbl_meta, vbl_sync, vbl_prev;
reg  [10:0] act_cnt = 11'd0;
reg  [9:0]  cy_rv;
// The read side shows the most recently COMPLETED source line, so at the instant the
// source's active area opens the buffer still holds the PREVIOUS frame's last line for
// about one source line. Delaying the vertical gate by 3 output lines drops that stale
// strip from the top and keeps the real last line at the bottom, instead of the ~25-line
// smear of the final line that used to run to the bottom of the frame.
reg  [2:0] vact_sr = 3'b0;
// FAIL-SAFE. If video_vbl never toggles -- core held in reset, a mode with no active
// area, anything unexpected -- act_cnt stays 0, the computed width collapses to 0 and
// the vertical gate never opens, i.e. a black screen with no way to reach the OSD. So
// the window only narrows once a PLAUSIBLE height has been measured, and until then the
// old full-width behaviour stands. A blank screen is the one failure mode that would
// cost the user the menu, so it must not be reachable from a measurement going wrong.
localparam int ACT_H_MIN = 300;
localparam int ACT_H_MAX = 780;
reg  aspect_valid = 1'b0;
wire v_active = (ASPECT_4_3 && aspect_valid) ? vact_sr[2] : 1'b1;

// height * 4/3, rounded. 21845/16384 = 1.333313, so the error is under a tenth of a pixel.
wire [26:0] w_mul  = {16'b0, act_h} * 27'd21845 + 27'd8192;
wire [11:0] w_calc = w_mul[25:14];

always_ff @(posedge clk_pixel) begin
	reg [10:0] w_clamped;
	vbl_meta <= video_vbl;
	vbl_sync <= vbl_meta;
	vbl_prev <= vbl_sync;
	cy_rv    <= cy;

	if (cy != cy_rv) vact_sr <= {vact_sr[1:0], ~vbl_sync};

	if (vbl_prev & ~vbl_sync)              // source active area opens
		act_cnt <= 11'd0;
	else if (~vbl_sync && cy != cy_rv)     // count output lines across it
		act_cnt <= act_cnt + 11'd1;

	if (~vbl_prev & vbl_sync) begin        // closes: latch the height, if it is sane
		if (act_cnt >= 11'(ACT_H_MIN) && act_cnt <= 11'(ACT_H_MAX)) begin
			act_h        <= act_cnt;
			aspect_valid <= 1'b1;
		end else
			aspect_valid <= 1'b0;
	end

	// Recompute the window once per frame, so it is stable while a frame is being drawn.
	if (cx == frameWidth - 1'b1 && cy == frameHeight - 1'b1) begin
		if (ASPECT_4_3 && aspect_valid) begin
			w_clamped = (w_calc > 12'(SCREEN_WIDTH)) ? 11'(SCREEN_WIDTH) : w_calc[10:0];
			act_w   <= w_clamped;
			x_start <= (11'(SCREEN_WIDTH) - w_clamped) >> 1;
			x_stop  <= ((11'(SCREEN_WIDTH) - w_clamped) >> 1) + w_clamped;
		end else begin
			act_w   <= 11'(SCREEN_WIDTH);
			x_start <= 11'd0;
			x_stop  <= 11'(SCREEN_WIDTH);
		end
	end
end

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
	if (cx == x_start) begin active_t = 1; active <= 1; end
	else if (cx == x_stop) begin active_t = 0; active <= 0; end

	if (active_t | active) begin
		xcnt_next = xcnt + cur_line_width;
		xcnt <= xcnt_next;
		if (xcnt_next >= act_w) begin
			xcnt <= xcnt_next - act_w;
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
	if (active & v_active) begin
		if (overlay)
			rgb <= {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};
		else
			rgb <= { sd_rdata[8:6], sd_rdata[8:6], sd_rdata[8:7],
			         sd_rdata[5:3], sd_rdata[5:3], sd_rdata[5:4],
			         sd_rdata[2:0], sd_rdata[2:0], sd_rdata[2:1] };
	end else
		// Pillarbox/letterbox bars are DISPLAYED, unlike the blanking this used to fill,
		// so 0x101010 would show as grey pillars. They have to be real black.
		rgb <= ASPECT_4_3 ? 24'h000000 : 24'h101010;
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
// ============================ VTOTAL LOCK ============================
//
// CONFIRMED ON REAL HARDWARE, 2026-09-10: the sink accepts a 755-line vertical total.
// A build with vtotal_extra hard-wired to 5 produced a stable picture whose roll slowed
// from 2.4 s to 78.5 s, exactly as predicted. That closes the one question the trace
// data could not answer, and it retires the earlier "VTOTAL modulation is dead" verdict
// -- what had actually been tested was a saturating controller bang-banging 750<->760
// every frame, which is simply unstable timing, not evidence about a steady 755.
//
// The rate is a fixed rational, measured three independent ways to four figures:
//     closed form   (263*2730 clk_pce vs 1650 clk_pixel)   755.1587 lines
//     vs_cy creep, free-running 750-line raster            755.131
//     vs_cy creep, static 755-line raster                  755.160
// Both PLLs divide the SAME 50 MHz crystal (clk_pce = 1200/28, clk_pixel = 743.75/10),
// so there is no thermal term -- but the loop below never assumes any of that. It
// measures, so a title that selects huc6260's 262-line branch (END_LINE depends on
// CR(2), which is the GAME's choice) retunes automatically. Hardcoding 263 would not.
//
// WHY A CONTROL LOOP AND NOT A CONSTANT: the needed height is fractional. 755 leaves
// 0.16 lines/frame, which is the 78.5 s crawl actually observed. The pixel clock cannot
// absorb it either -- exact lock at 755 lines wants 74.35937 MHz, and with MDIV
// quantised to eighths the nearest realisable value is 74.375, i.e. where we already
// are. So the fraction has to be dithered in the raster: 755 lines with 0.16 of frames
// at 756.
//
// CONTROL LAW. Plant: e[k+1] = e[k] + S - L[k], with S the source frame length in
// output lines and L[k] = 750 + extra[k]. A pure integrator, so a PI controller with
// the fractional part sigma-delta dithered:
//
//     ctrl  = I + Kp*e                    (16.8 fixed point, units of output lines)
//     I    += Ki*e                        Ki = 1/256, Kp = 1/8
//     extra = int(ctrl) + sigma_delta_carry(frac(ctrl))
//
// Closed loop z^2 + (Kp + Ki - 2)z + (1 - Kp): roots 0.948 / 0.923, stable, settling in
// well under a second. Running the sigma-delta on the WHOLE control value rather than
// on I alone matters: e is quantised to whole lines, so a bare proportional term is
// dead for |e| < 8 and the loop would limit-cycle a few lines instead of locking.
//
// Two guards that are not optional:
//   - anti-windup: I is clamped to the same range as extra, or a long pull-in charges I
//     far past the clamp and the loop overshoots on the way back.
//   - slew limit of one line per frame on the applied value, so the sink never sees the
//     abrupt multi-line jumps that blanked it before. The steady-state dither is itself
//     a +-1 step, so this costs the loop nothing.
//
// PHASE TARGET. Rate lock alone freezes the picture wherever it happens to sit, which
// is not a fix. `out_line_pair` drives only the OSD; the video read side always shows
// the most recently COMPLETED source line, so one source line occupies 2730/42.857e6 /
// (1650/74.375e6) = 2.871 output lines and the 242 active source lines fill 695 of the
// 720 active output lines by themselves. (The "484 doubled lines centered in 480"
// comment further up is stale -- it describes the 480p configuration this board no
// longer uses.) So the target is near the TOP of the frame, not mid-screen: the source
// active area should start about one source line (~3 output lines) before output line
// 0, offset by half the 25-line slack to centre the picture.
// AUTHORITY IS BOUNDED, AND THAT BOUND IS THE WHOLE POINT (2026-09-10, real hardware).
// With the clamp at [0,12] the loop locked correctly -- traced vs_cy held VT_PHASE_TARGET
// exactly -- but the display went black for ~2 s a few seconds after boot, then recovered
// and stayed good. Signal was never lost, so this was the sink RE-ACQUIRING, not a link
// drop. The trace says why: during pull-in the loop parks vtotal_extra at its low clamp
// (samples 1..11 of the heartbeat, vtotal_extra = 0) for over a second, the sink locks to
// that 750-line timing, and the loop then settles at 755. A 5-line move is a 0.66% frame
// rate change -- far enough for a PC monitor (stricter than a TV) to re-acquire.
//
// The fix is not a better control law, it is less authority. The steady-state dither
// between 755 and 756 runs continuously and never blanks anything, which proves a 1-line
// change is below the sink's re-acquire threshold; only the large excursion crosses it.
// So the applied value is clamped to an ABSOLUTE band about the expected height rather
// than to the full range, and the integral's anti-windup is clamped to the same band so
// it cannot charge past what the output can express.
//
// [752,758] is +-3 lines, i.e. a worst-case 0.4% deviation against the 0.66% that failed.
// Simulated across every starting phase in 25-line steps: worst acquisition 213 frames
// (3.5 s), steady state exactly {5,6}, and a source switching to huc6260's 262-line
// branch still re-locks in 74 frames. Widening to +-4 buys ~0.4 s of acquisition and
// costs margin against the failure above; narrowing to +-2 keeps {5,6} but can no longer
// reach a 262-line source at all. The gains stay as they were -- raising Kp speeds
// acquisition but widens the steady state to three values, which is the one thing worth
// protecting here.
localparam int VT_LO           = 2;    // extra in [2,8] -> VTOTAL in [752,758]
localparam int VT_HI           = 8;
localparam int VT_PHASE_TARGET = 9;    // output cy the source's active start should sit on

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
reg       vs_seen   = 1'b0;
reg [7:0] vtotal_extra = 8'd5;                        // applied value, slew limited
reg signed [23:0] vt_i = 24'sd1321;                   // 16.8 fixed point, seeded 5.16
reg [7:0] vt_frac = 8'd0;                             // sigma-delta accumulator
reg out_frame_tog = 1'b0;
reg [9:0] vs_cy_snap = 10'd0;

always_ff @(posedge clk_pixel) begin
	reg signed [12:0] e;
	reg signed [12:0] raw;
	reg signed [23:0] ctrl, i_next;
	reg signed [16:0] tgt;
	reg [8:0]         sd_sum;

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
			// Phase error about the target, wrapped signed so a source that starts just
			// BEFORE the output frame reads as a small negative error rather than a
			// nearly-full-frame positive one.
			raw = $signed({3'b0, vs_cy}) - $signed(13'(VT_PHASE_TARGET));
			if (raw < 13'sd0)
				raw = raw + $signed({3'b0, frameHeight});
			e = (raw > $signed({4'b0, frameHeight[9:1]}))
			      ? raw - $signed({3'b0, frameHeight})
			      : raw;

			// PI, then sigma-delta the fractional part of the whole control value.
			ctrl   = vt_i + ($signed({{11{e[12]}}, e}) <<< 5);   // Kp = 32/256 = 1/8
			sd_sum = {1'b0, vt_frac} + {1'b0, ctrl[7:0]};
			vt_frac <= sd_sum[7:0];
			tgt    = $signed(ctrl[23:8]) + $signed({16'b0, sd_sum[8]});

			if (tgt < $signed(17'(VT_LO)))      tgt = $signed(17'(VT_LO));
			else if (tgt > $signed(17'(VT_HI))) tgt = $signed(17'(VT_HI));

			// One line per frame, so the sink never sees an abrupt jump.
			if      ($signed({9'b0, vtotal_extra}) < tgt) vtotal_extra <= vtotal_extra + 8'd1;
			else if ($signed({9'b0, vtotal_extra}) > tgt) vtotal_extra <= vtotal_extra - 8'd1;

			// Integral with anti-windup, clamped to the same authority as the output.
			i_next = vt_i + $signed({{11{e[12]}}, e});  // Ki = 1/256
			if (i_next < $signed(24'(VT_LO <<< 8)))      i_next = $signed(24'(VT_LO <<< 8));
			else if (i_next > $signed(24'(VT_HI <<< 8))) i_next = $signed(24'(VT_HI <<< 8));
			vt_i <= i_next;
		end
		vs_seen <= 1'b0;
		out_frame_tog <= ~out_frame_tog;   // one flip per output frame
		vs_cy_snap    <= vs_cy;            // snapshot at the same instant the servo acts
	end
end

assign dbg_out_frame_tog = out_frame_tog;
assign dbg_vs_cy         = vs_cy_snap;
assign dbg_vtotal_extra  = vtotal_extra;   // the APPLIED value, not an idle computation

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
        .vtotal_extra(vtotal_extra),
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
