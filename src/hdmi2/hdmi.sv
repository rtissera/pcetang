// Modifications copyright (c) 2026 Romain Tisserand.
// This file is derived from third-party code and is NOT original work of
// this project; only the changes made here are covered by the line above.
// See THIRD_PARTY_LICENSES.md for the upstream project, author and licence.
// Implementation of HDMI Spec v1.4a
// By Sameer Puri https://github.com/sameer

module hdmi 
#(
    // Defaults to 640x480 which should be supported by almost if not all HDMI sinks.
    // See README.md or CEA-861-D for enumeration of video id codes.
    // Pixel repetition, interlaced scans and other special output modes are not implemented (yet).
    parameter int VIDEO_ID_CODE = 1,

    // The IT content bit indicates that image samples are generated in an ad-hoc
    // manner (e.g. directly from values in a framebuffer, as by a PC video
    // card) and therefore aren't suitable for filtering or analog
    // reconstruction.  This is probably what you want if you treat pixels
    // as "squares".  If you generate a properly bandlimited signal or obtain
    // one from elsewhere (e.g. a camera), this can be turned off.
    //
    // This flag also tends to cause receivers to treat RGB values as full
    // range (0-255).
    parameter bit IT_CONTENT = 1'b1,

    // Defaults to minimum bit lengths required to represent positions.
    // Modify these parameters if you have alternate desired bit lengths.
    parameter int BIT_WIDTH = VIDEO_ID_CODE < 4 ? 10 : VIDEO_ID_CODE == 4 ? 11 : 12,
    parameter int BIT_HEIGHT = VIDEO_ID_CODE == 16 ? 11: 10,

    // A true HDMI signal sends auxiliary data (i.e. audio, preambles) which prevents it from being parsed by DVI signal sinks.
    // HDMI signal sinks are fortunately backwards-compatible with DVI signals.
    // Enable this flag if the output should be a DVI signal. You might want to do this to reduce resource usage or if you're only outputting video.
    parameter bit DVI_OUTPUT = 1'b0,

    // **All parameters below matter ONLY IF you plan on sending auxiliary data (DVI_OUTPUT == 1'b0)**

    // Specify the refresh rate in Hz you are using for audio calculations
    parameter real VIDEO_REFRESH_RATE = 59.94,

    // As specified in Section 7.3, the minimal audio requirements are met: 16-bit or more L-PCM audio at 32 kHz, 44.1 kHz, or 48 kHz.
    // See Table 7-4 or README.md for an enumeration of sampling frequencies supported by HDMI.
    // Note that sinks may not support rates above 48 kHz.
    parameter int AUDIO_RATE = 44100,

    // Defaults to 16-bit audio, the minmimum supported by HDMI sinks. Can be anywhere from 16-bit to 24-bit.
    parameter int AUDIO_BIT_WIDTH = 16,

    // Some HDMI sinks will show the source product description below to users (i.e. in a list of inputs instead of HDMI 1, HDMI 2, etc.).
    // If you care about this, change it below.
    parameter bit [8*8-1:0] VENDOR_NAME = {"Unknown", 8'd0}, // Must be 8 bytes null-padded 7-bit ASCII
    parameter bit [8*16-1:0] PRODUCT_DESCRIPTION = {"FPGA", 96'd0}, // Must be 16 bytes null-padded 7-bit ASCII
    parameter bit [7:0] SOURCE_DEVICE_INFORMATION = 8'h00, // See README.md or CTA-861-G for the list of valid codes

    // Starting screen coordinate when module comes out of reset.
    //
    // Setting these to something other than (0, 0) is useful when positioning
    // an external video signal within a larger overall frame (e.g.
    // letterboxing an input video signal). This allows you to synchronize the
    // negative edge of reset directly to the start of the external signal
    // instead of to some number of clock cycles before.
    //
    // You probably don't need to change these parameters if you are
    // generating a signal from scratch instead of processing an
    // external signal.
    parameter int START_X = 0,
    parameter int START_Y = 0
)
(
    input logic clk_pixel_x5,
    input logic clk_pixel,
    input logic clk_audio,
    // synchronous reset back to 0,0
    input logic reset,
    // PCE PORT (2026-09-21): a RASTER-ONLY reset, separate from `reset` on purpose.
    //
    // Exact-lock mode sets the phase between the source frame and the output frame by
    // slamming cx/cy back to the origin once, when the source geometry changes (see
    // pce2hdmi_sd.sv). MiSTle-Dev/c64nano drives the ordinary `reset` for this, and the
    // first attempt here copied that -- which cost 3 setup violations on Console 60K
    // (clk_pce margin +0.250% -> +0.016%). `reset` fans out to every register in this
    // file INCLUDING the serializer, and with it tied to a constant all of that reset
    // logic had been pruned; driving it live un-pruned a high-fanout net on the 300 MHz
    // TMDS clock. c64nano gets away with it because its TMDS runs at 157.5 MHz.
    //
    // This input touches cx/cy only, so `reset` stays constant-0 and everything else
    // stays pruned. It also avoids glitching the packet and serializer state mid-frame,
    // which the wide reset would have done on every geometry change.
    //
    // Defaulted so the other instantiation (pce2hdmi.sv) needs no change, same pattern
    // as vtotal_extra below.
    input logic vreset = 1'b0,

    // PCE PORT (2026-09-09): restart ONLY the raster counters, without touching the rest
    // of the module's reset network. Used to genlock the output frame to an external
    // source's VSYNC. Driving the full `reset` above does work, but asserting it at all
    // Extra blanking lines appended to the END of the frame (after VSYNC, so the sync
    // pulse itself never moves). Latched once per frame, so VTOTAL is constant for the
    // whole frame the sink is measuring.
    //
    // WHY THIS AND NOT A RASTER RESET: an earlier revision had a `sync_reset` that
    // rewound cx/cy to genlock to an asynchronous source. That is wrong. cx/cy are not
    // the only per-frame sequencer in this module -- the video guard/preamble windows
    // below key off `frame_height - 1`, and the packet picker and audio-clock
    // regeneration downstream pace themselves off the same raster. Rewinding cx/cy
    // alone desynchronises all of them from the raster they are stamping into; when the
    // rewind landed in blanking a sink tolerated one malformed island per frame, and
    // when it landed in active video the sink dropped the link entirely.
    //
    // Varying VTOTAL instead keeps every sequencer's notion of "the frame" intact --
    // frame_height below IS the effective height, so the guard/preamble windows track
    // it -- and a few extra blanking lines is an ordinary, legal thing for a source to
    // do. Defaulted so every existing instantiation is unchanged.
    input logic [7:0] vtotal_extra = 8'd0,
    input logic [23:0] rgb,
    input logic [AUDIO_BIT_WIDTH-1:0] audio_sample_word [1:0],

    // These outputs go to your HDMI port
    output logic [2:0] tmds,
    output logic tmds_clock,
    
    // All outputs below this line stay inside the FPGA
    // They are used (by you) to pick the color each pixel should have
    // i.e. always_ff @(posedge pixel_clk) rgb <= {8'd0, 8'(cx), 8'(cy)};
    output logic [BIT_WIDTH-1:0] cx = START_X,
    output logic [BIT_HEIGHT-1:0] cy = START_Y,

    // The screen is at the upper left corner of the frame.
    // 0,0 = 0,0 in video
    // the frame includes extra space for sending auxiliary data
    output logic [BIT_WIDTH-1:0] frame_width,
    output logic [BIT_HEIGHT-1:0] frame_height,
    output logic [BIT_WIDTH-1:0] screen_width,
    output logic [BIT_HEIGHT-1:0] screen_height
);

localparam int NUM_CHANNELS = 3;
logic hsync;
logic vsync;

logic [BIT_HEIGHT-1:0] frame_height_base;
logic [7:0] vtotal_extra_lat = 8'd0;
// The effective VTOTAL. Everything downstream that asks "how tall is this frame" reads
// this, so the extra lines are invisible to the rest of the module.
assign frame_height = frame_height_base + BIT_HEIGHT'(vtotal_extra_lat);

logic [BIT_WIDTH-1:0] hsync_pulse_start, hsync_pulse_size;
logic [BIT_HEIGHT-1:0] vsync_pulse_start, vsync_pulse_size;
logic invert;

// See CEA-861-D for more specifics formats described below.
generate
    case (VIDEO_ID_CODE)
        1:
        begin
            assign frame_width = 800;
            assign frame_height_base = 525;
            assign screen_width = 640;
            assign screen_height = 480;
            assign hsync_pulse_start = 16;
            assign hsync_pulse_size = 96;
            assign vsync_pulse_start = 10;
            assign vsync_pulse_size = 2;
            assign invert = 1;
            end
        2, 3:
        begin
            assign frame_width = 858;
            assign frame_height_base = 525;
            assign screen_width = 720;
            assign screen_height = 480;
            assign hsync_pulse_start = 16;
            assign hsync_pulse_size = 62;
            assign vsync_pulse_start = 9;
            assign vsync_pulse_size = 6;
            assign invert = 1;
            end
        4:
        begin
            assign frame_width = 1650;
            assign frame_height_base = 750;
            assign screen_width = 1280;
            assign screen_height = 720;
            assign hsync_pulse_start = 110;
            assign hsync_pulse_size = 40;
            assign vsync_pulse_start = 5;
            assign vsync_pulse_size = 5;
            assign invert = 0;
        end
        // PCE PORT: custom mode 200 -- "PCE exact lock", built to MiSTle-Dev/c64nano's
        // recipe rather than as a free-form custom timing.
        //
        // THE PROBLEM. Every standard mode has a pixel clock irrational against the PC
        // Engine's line rate, so the line doubler shows each source line for 2 or 3 output
        // lines in a crawling pattern (the shimmer), and the frame servo has to dither
        // VTOTAL between two integers to absorb the rest (the tremor). Both are consequences
        // of a non-integer ratio, not bugs.
        //
        // THE RECIPE, read out of c64nano/src/hdmi/hdmi.sv. Its NTSC mode is:
        //     htiming0 = { 1040, 720, 16, 62 }   vtiming0 = { 526, 480, 9, 6 }   cea0 = 2
        // That is a REAL CEA 480p active area (720x480) under the REAL VIC (2), with the
        // rate error pushed entirely into blanking and a faster-than-standard pixel clock.
        // A sink therefore sees exactly the active area and VIC it expects; only H_total
        // and the clock are off, by under 1% in line rate. That is why a non-standard
        // raster is accepted by consumer displays -- NOT because sinks tolerate arbitrary
        // timings, which was the assumption behind the first cut of this mode.
        //
        // c64nano's NTSC frame is 526 lines = 263 x 2, and 263 is ALSO the PC Engine's
        // NTSC line count. Its line rate (15.734 kHz real) is within 0.2% of PCE's 15.699.
        // The closest geometric match that exists to this core chose 480p, not 720p.
        //
        // APPLIED HERE:
        //     source line = 2730 core dots / 42.857 MHz   = 63.700 us
        //     output line =  858 pixels    / 26.8750 MHz  = 31.926 us  (ratio EXACTLY 2)
        //     V_total     = 526 = 263 x 2                 -> frame rate locks on both sides
        //     active      = 720 x 480, declared VIC 2      -> what the sink expects to see
        //
        //                     c64nano NTSC | here   | real CEA 480p60
        //     active            720x480    | 720x480| 720x480
        //     VIC                    2     |    2   |    2
        //     V_total              526     |   526  |   525
        //     H_total             1040     |   858  |   858
        //     pixel clock      32.5 MHz    | 26.8750|  27.027
        //     H blanking           31%     |   16%  |    16%
        //
        // WHY NOT x3. H_total = 1365 * ODIV_pce/ODIV_pixel. x3 cannot get below 1274, and
        // 1274 < 1280, so a standard 720p active area does not fit in the line at all --
        // the recipe above is simply unavailable there. x2 reaches 858 exactly. Both clocks are integer taps off the core's own 1200 MHz VCO
        // (console60k_pll.vhd), so this is a rational lock, not a servo chasing a beat,
        // and clk_pce is untouched.
        //
        // Sync values are c64nano's, which are themselves the standard 480p ones: front
        // porch 16, hsync 62, vsync at line 9 for 6 lines. The extra blanking all lands in
        // the back porch, exactly as it does in c64nano.
        //
        // 720x480 under VIC 2 is NON-SQUARE (displayed 4:3), so pce2hdmi_sd.sv disables its
        // own 4:3 windowing for this mode and fills all 720 pixels, letting the sink apply
        // the aspect -- the same thing real 480p hardware does.
        200:
        begin
            assign frame_width = 858;
            // The EXACT value: 526 = 263 x 2, with vtotal_extra forced to 0 for this mode
            // (see pce2hdmi_sd.sv). It was briefly a servo base instead; under an exact
            // lock a VTOTAL servo has no unique fixed point, so its sigma-delta stage
            // dithers forever and that dither IS the tremor this mode exists to remove.
            // Phase is set once by vreset instead, as c64nano's video_analyzer.v does.
            assign frame_height_base = 526;
            assign screen_width = 720;
            // 480, not the 484 the source supplies (242 active lines doubled). Cropping 4
            // lines is what buys the exact CEA active area, and c64nano makes the same
            // trade -- its "std" mode shows 480 of its own 484 and only its overscan mode
            // shows all of them.
            assign screen_height = 480;
            assign hsync_pulse_start = 16;
            assign hsync_pulse_size = 62;
            assign vsync_pulse_start = 9;
            assign vsync_pulse_size = 6;
            assign invert = 1;
        end
        16, 34:
        begin
            assign frame_width = 2200;
            assign frame_height_base = 1125;
            assign screen_width = 1920;
            assign screen_height = 1080;
            assign hsync_pulse_start = 88;
            assign hsync_pulse_size = 44;
            assign vsync_pulse_start = 4;
            assign vsync_pulse_size = 5;
            assign invert = 0;
        end
        17, 18:
        begin
            assign frame_width = 864;
            assign frame_height_base = 625;
            assign screen_width = 720;
            assign screen_height = 576;
            assign hsync_pulse_start = 12;
            assign hsync_pulse_size = 64;
            assign vsync_pulse_start = 5;
            assign vsync_pulse_size = 5;
            assign invert = 1;
        end
        19:
        begin
            assign frame_width = 1980;
            assign frame_height_base = 750;
            assign screen_width = 1280;
            assign screen_height = 720;
            assign hsync_pulse_start = 440;
            assign hsync_pulse_size = 40;
            assign vsync_pulse_start = 5;
            assign vsync_pulse_size = 5;
            assign invert = 0;
        end
        95, 105, 97, 107:
        begin
            assign frame_width = 4400;
            assign frame_height_base = 2250;
            assign screen_width = 3840;
            assign screen_height = 2160;
            assign hsync_pulse_start = 176;
            assign hsync_pulse_size = 88;
            assign vsync_pulse_start = 8;
            assign vsync_pulse_size = 10;
            assign invert = 0;
        end
    endcase
endgenerate

always_comb begin
    hsync <= invert ^ (cx >= screen_width + hsync_pulse_start && cx < screen_width + hsync_pulse_start + hsync_pulse_size);
    // vsync pulses should begin and end at the start of hsync, so special
    // handling is required for the lines on which vsync starts and ends
    if (cy == screen_height + vsync_pulse_start - 1)
        vsync <= invert ^ (cx >= screen_width + hsync_pulse_start);
    else if (cy == screen_height + vsync_pulse_start + vsync_pulse_size - 1)
        vsync <= invert ^ (cx < screen_width + hsync_pulse_start);
    else
        vsync <= invert ^ (cy >= screen_height + vsync_pulse_start && cy < screen_height + vsync_pulse_start + vsync_pulse_size);
end

// PCE PORT: mode 200 runs at 940.625/35 = 26.875 MHz. VIDEO_RATE feeds the audio clock
// regeneration (CTS/N); getting it wrong silently detunes HDMI audio, which matters here
// because CD-DA is half the point of this core.
localparam real VIDEO_RATE = (VIDEO_ID_CODE == 200 ? 26.875E6
    : VIDEO_ID_CODE == 1 ? 25.2E6
    : VIDEO_ID_CODE == 2 || VIDEO_ID_CODE == 3 ? 27.027E6
    : VIDEO_ID_CODE == 4 ? 74.25E6
    : VIDEO_ID_CODE == 16 ? 148.5E6
    : VIDEO_ID_CODE == 17 || VIDEO_ID_CODE == 18 ? 27E6
    : VIDEO_ID_CODE == 19 ? 74.25E6
    : VIDEO_ID_CODE == 34 ? 74.25E6
    : VIDEO_ID_CODE == 95 || VIDEO_ID_CODE == 105 || VIDEO_ID_CODE == 97 || VIDEO_ID_CODE == 107 ? 594E6
    : 0) * (VIDEO_REFRESH_RATE == 59.94 || VIDEO_REFRESH_RATE == 29.97 ? 1000.0/1001.0 : 1); // https://groups.google.com/forum/#!topic/sci.engr.advanced-tv/DQcGk5R_zsM

// Wrap-around pixel position counters indicating the pixel to be generated by the user in THIS clock and sent out in the NEXT clock.
always_ff @(posedge clk_pixel)
begin
    if (reset || vreset)
    begin
        cx <= BIT_WIDTH'(START_X);
        cy <= BIT_HEIGHT'(START_Y);
        vtotal_extra_lat <= 8'd0;
    end
    else
    begin
        cx <= cx == frame_width-1'b1 ? BIT_WIDTH'(0) : cx + 1'b1;
        cy <= cx == frame_width-1'b1 ? cy == frame_height-1'b1 ? BIT_HEIGHT'(0) : cy + 1'b1 : cy;
        // Sample the requested VTOTAL exactly once, on the last pixel of the frame, so
        // it can never change under the guard/preamble comparisons mid-frame.
        if (cx == frame_width-1'b1 && cy == frame_height-1'b1)
            vtotal_extra_lat <= vtotal_extra;
    end
end

// See Section 5.2
logic video_data_period = 0;
always_ff @(posedge clk_pixel)
begin
    if (reset)
        video_data_period <= 0;
    else
        video_data_period <= cx < screen_width && cy < screen_height;
end

logic [2:0] mode = 3'd1;
logic [23:0] video_data = 24'd0;
logic [5:0] control_data = 6'd0;
logic [11:0] data_island_data = 12'd0;

generate
    if (!DVI_OUTPUT)
    begin: true_hdmi_output
        logic video_guard = 1;
        logic video_preamble = 0;
        always_ff @(posedge clk_pixel)
        begin
            if (reset)
            begin
                video_guard <= 1;
                video_preamble <= 0;
            end
            else
            begin
                video_guard <= cx >= frame_width - 2 && cx < frame_width && (cy == frame_height - 1 || cy < screen_height - 1 /* no VG at end of last line */);
                video_preamble <= cx >= frame_width - 10 && cx < frame_width - 2 && (cy == frame_height - 1 || cy < screen_height - 1 /* no VP at end of last line */);
            end
        end

        // See Section 5.2.3.1
        int max_num_packets_alongside;
        logic [4:0] num_packets_alongside;
        always_comb
        begin
            max_num_packets_alongside = (frame_width - screen_width  /* VD period */ - 2 /* V guard */ - 8 /* V preamble */ - 4 /* Min V control period */ - 2 /* DI trailing guard */ - 2 /* DI leading guard */ - 8 /* DI premable */ - 4 /* Min DI control period */) / 32;
            if (max_num_packets_alongside > 18)
                num_packets_alongside = 5'd18;
            else
                num_packets_alongside = 5'(max_num_packets_alongside);
        end

        logic data_island_period_instantaneous;
        assign data_island_period_instantaneous = num_packets_alongside > 0 && cx >= screen_width + 14 && cx < screen_width + 14 + num_packets_alongside * 32;
        logic packet_enable;
        assign packet_enable = data_island_period_instantaneous && 5'(cx + screen_width + 18) == 5'd0;

        logic data_island_guard = 0;
        logic data_island_preamble = 0;
        logic data_island_period = 0;
        always_ff @(posedge clk_pixel)
        begin
            if (reset)
            begin
                data_island_guard <= 0;
                data_island_preamble <= 0;
                data_island_period <= 0;
            end
            else
            begin
                data_island_guard <= num_packets_alongside > 0 && (
                    (cx >= screen_width + 12 && cx < screen_width + 14) /* leading guard */ || 
                    (cx >= screen_width + 14 + num_packets_alongside * 32 && cx < screen_width + 14 + num_packets_alongside * 32 + 2) /* trailing guard */
                );
                data_island_preamble <= num_packets_alongside > 0 && cx >= screen_width + 4 && cx < screen_width + 12;
                data_island_period <= data_island_period_instantaneous;
            end
        end

        // See Section 5.2.3.4
        logic [23:0] header;
        logic [55:0] sub [3:0];
        logic video_field_end;
        assign video_field_end = cx == screen_width - 1'b1 && cy == screen_height - 1'b1;
        logic [4:0] packet_pixel_counter;
        packet_picker #(
            .VIDEO_ID_CODE(VIDEO_ID_CODE),
            .VIDEO_RATE(VIDEO_RATE),
            .IT_CONTENT(IT_CONTENT),
            .AUDIO_RATE(AUDIO_RATE),
            .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
            .VENDOR_NAME(VENDOR_NAME),
            .PRODUCT_DESCRIPTION(PRODUCT_DESCRIPTION),
            .SOURCE_DEVICE_INFORMATION(SOURCE_DEVICE_INFORMATION),
            // The VIC the AVI InfoFrame ADVERTISES, which is not always the internal mode
            // number. Mode 200 sends a standard 720x480 active area and declares VIC 2 for
            // it, which is the whole reason a sink accepts the non-standard blanking.
            .AVI_VIC(VIDEO_ID_CODE == 200 ? 2 : VIDEO_ID_CODE)
        ) packet_picker (.clk_pixel(clk_pixel), .clk_audio(clk_audio), .reset(reset), .video_field_end(video_field_end), .packet_enable(packet_enable), .packet_pixel_counter(packet_pixel_counter), .audio_sample_word(audio_sample_word), .header(header), .sub(sub));
        logic [8:0] packet_data;
        packet_assembler packet_assembler (.clk_pixel(clk_pixel), .reset(reset), .data_island_period(data_island_period), .header(header), .sub(sub), .packet_data(packet_data), .counter(packet_pixel_counter));


        always_ff @(posedge clk_pixel)
        begin
            if (reset)
            begin
                mode <= 3'd2;
                video_data <= 24'd0;
                control_data = 6'd0;
                data_island_data <= 12'd0;
            end
            else
            begin
                mode <= data_island_guard ? 3'd4 : data_island_period ? 3'd3 : video_guard ? 3'd2 : video_data_period ? 3'd1 : 3'd0;
                video_data <= rgb;
                control_data <= {{1'b0, data_island_preamble}, {1'b0, video_preamble || data_island_preamble}, {vsync, hsync}}; // ctrl3, ctrl2, ctrl1, ctrl0, vsync, hsync
                data_island_data[11:4] <= packet_data[8:1];
                data_island_data[3] <= cx != 0;
                data_island_data[2] <= packet_data[0];
                data_island_data[1:0] <= {vsync, hsync};
            end
        end
    end
    else // DVI_OUTPUT = 1
    begin
        always_ff @(posedge clk_pixel)
        begin
            if (reset)
            begin
                mode <= 3'd0;
                video_data <= 24'd0;
                control_data <= 6'd0;
            end
            else
            begin
                mode <= video_data_period ? 3'd1 : 3'd0;
                video_data <= rgb;
                control_data <= {4'b0000, {vsync, hsync}}; // ctrl3, ctrl2, ctrl1, ctrl0, vsync, hsync
            end
        end
    end
endgenerate

// All logic below relates to the production and output of the 10-bit TMDS code.
logic [9:0] tmds_internal [NUM_CHANNELS-1:0] /* verilator public_flat */ ;
genvar i;
generate
    // TMDS code production.
    for (i = 0; i < NUM_CHANNELS; i++)
    begin: tmds_gen
        tmds_channel #(.CN(i)) tmds_channel (.clk_pixel(clk_pixel), .video_data(video_data[i*8+7:i*8]), .data_island_data(data_island_data[i*4+3:i*4]), .control_data(control_data[i*2+1:i*2]), .mode(mode), .tmds(tmds_internal[i]));
    end
endgenerate

serializer #(.NUM_CHANNELS(NUM_CHANNELS), .VIDEO_RATE(VIDEO_RATE)) serializer(.clk_pixel(clk_pixel), .clk_pixel_x5(clk_pixel_x5), .reset(reset), .tmds_internal(tmds_internal), .tmds(tmds), .tmds_clock(tmds_clock));

endmodule
