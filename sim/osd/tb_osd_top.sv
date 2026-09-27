// pce2hdmi_sd (exact lock, mode 200) with the OSD on, wired to the real textdisp.v.
module tb_osd_top(input clk, clk_pixel, resetn, input [2:0] video_r, video_g, video_b,
                  input video_ce, video_hs, video_vs, video_hbl, video_vbl);
  wire [7:0] ox, oy; wire [14:0] oc;
  wire tcn, tcp; wire [2:0] tdn, tdp; wire ft; wire [9:0] vcy; wire [7:0] vte;
  pce2hdmi_sd #(.VIDEOID(200), .CLKFRQ(26875)) u (
    .clk(clk), .resetn(resetn), .video_r(video_r), .video_g(video_g), .video_b(video_b),
    .video_ce(video_ce), .video_hs(video_hs), .video_vs(video_vs), .video_hbl(video_hbl), .video_vbl(video_vbl),
    .overlay(1'b1), .overlay_x(ox), .overlay_y(oy), .overlay_color(oc),
    .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0),
    .psg_sl(16'd0), .psg_sr(16'd0), .cdda_sl(16'd0), .cdda_sr(16'd0), .adpcm_s(16'd0),
    .tmds_clk_n(tcn), .tmds_clk_p(tcp), .tmds_d_n(tdn), .tmds_d_p(tdp),
    .dbg_out_frame_tog(ft), .dbg_vs_cy(vcy), .dbg_vtotal_extra(vte));
  textdisp #(.COLOR_LOGO(15'h7fff)) t (.clk(clk_pixel), .hclk(clk_pixel), .resetn(resetn),
    .x(ox), .y(oy), .color(oc), .reg_char_we(4'b0), .reg_char_di(32'b0));
endmodule
