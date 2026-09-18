// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Romain Tisserand
//
// Minimal stand-ins for the two modules pce2hdmi_sd.sv instantiates, so the scandoubler can be
// simulated on its own. The real hdmi core only matters here for cx/cy -- the raster position
// the read side follows -- so the stub generates exactly that, at whatever total the test asks
// for. ELVDS_OBUF is a Gowin output primitive with no simulation behaviour.
module hdmi #(
    parameter VIDEO_ID_CODE = 4, parameter DVI_OUTPUT = 0, parameter VIDEO_REFRESH_RATE = 60,
    parameter IT_CONTENT = 1, parameter AUDIO_RATE = 48000, parameter AUDIO_BIT_WIDTH = 16,
    parameter START_X = 0, parameter START_Y = 0,
    parameter FRAME_WIDTH = 1650, parameter FRAME_HEIGHT = 750
) (
    input clk_pixel_x5, input clk_pixel, input clk_audio, input reset,
    input [7:0] vtotal_extra,          // the VTOTAL servo's per-frame adjustment
    input [23:0] rgb, input [AUDIO_BIT_WIDTH-1:0] audio_sample_word [1:0],
    output [2:0] tmds, output tmds_clock,
    output reg [10:0] cx = 0, output reg [9:0] cy = 0,
    output [10:0] frame_width, output [9:0] frame_height
);
    assign frame_width  = FRAME_WIDTH;
    assign frame_height = FRAME_HEIGHT;
    assign tmds = 3'b0;
    assign tmds_clock = 1'b0;
    always @(posedge clk_pixel) begin
        if (cx == FRAME_WIDTH - 1) begin
            cx <= 0;
            cy <= (cy == FRAME_HEIGHT + vtotal_extra - 1) ? 10'd0 : cy + 10'd1;
        end else cx <= cx + 11'd1;
    end
endmodule

module ELVDS_OBUF (output O, output OB, input I);
    assign O = I; assign OB = ~I;
endmodule
