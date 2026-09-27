// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Romain Tisserand
//
// Stand-in for hdmi.sv in exact-lock mode 200 (858 x 526): only the raster counters matter to
// pce2hdmi_sd.sv, and `vreset` loads them to 0,0 as the real core does.
module hdmi #(
    parameter VIDEO_ID_CODE = 200, parameter DVI_OUTPUT = 0, parameter VIDEO_REFRESH_RATE = 60,
    parameter IT_CONTENT = 1, parameter AUDIO_RATE = 48000, parameter AUDIO_BIT_WIDTH = 16,
    parameter START_X = 0, parameter START_Y = 0
) (
    input clk_pixel_x5, input clk_pixel, input clk_audio, input reset, input vreset,
    input [7:0] vtotal_extra,
    input [23:0] rgb, input [AUDIO_BIT_WIDTH-1:0] audio_sample_word [1:0],
    output [2:0] tmds, output tmds_clock,
    output reg [10:0] cx = 0, output reg [9:0] cy = 0,
    output [10:0] frame_width, output [9:0] frame_height
);
    localparam W = 858, H = 526;
    assign frame_width = W; assign frame_height = H;
    assign tmds = 3'b0; assign tmds_clock = 1'b0;
    always @(posedge clk_pixel) begin
        if (reset || vreset) begin cx <= 0; cy <= 0; end
        else if (cx == W - 1) begin cx <= 0; cy <= (cy == H - 1) ? 10'd0 : cy + 10'd1; end
        else cx <= cx + 11'd1;
    end
endmodule

module ELVDS_OBUF (output O, output OB, input I);
    assign O = I; assign OB = ~I;
endmodule
