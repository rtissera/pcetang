// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Romain Tisserand
//
// Does textdisp.v draw the right font pixel when x advances every 2-3 pixel clocks, as it
// does under the 480p exact lock (256 OSD pixels across 720)? The character buffer holds
// char c in column c; font byte for char k is (1 << (k % 8)), so the lit pixel of cell c
// is exactly x % 8 == c % 8. Every x value is checked on the clock its colour appears
// (two clocks after x, the documented latency).
`timescale 1ns/1ps
module tb;
logic clk = 0; always #5 clk = ~clk;
logic [7:0] x = 0, y = 8'd9;
wire [14:0] color;
textdisp #(.COLOR_LOGO(15'h7fff)) dut(.clk(clk), .hclk(clk), .resetn(1'b1), .x(x), .y(y), .color(color),
                                       .reg_char_we(4'b0), .reg_char_di(32'b0));
int acc = 0, bad = 0, checked = 0;
logic [7:0] xq [0:2];
initial begin
  for (int i = 0; i < 3; i++) xq[i] = 0;
  repeat (5) @(posedge clk);
  for (int f = 0; f < 3; f++) begin
    x = 0; acc = 0;
    for (int cyc = 0; cyc < 720; cyc++) begin
      @(posedge clk);
      xq[2] = xq[1]; xq[1] = xq[0]; xq[0] = x;
      if (f > 0 && cyc > 4 && cyc < 715) begin
        automatic logic [7:0] xe = xq[2];
        automatic bit lit = (xe[2:0] == xe[5:3]);          // char c = xe>>3, lit bit c%8
        automatic bit shown = (color != 15'd0);
        checked++;
        if (lit != shown) bad++;
      end
      // the wrapper's stepping: 256 steps across 720 clocks
      if (acc + 256 >= 720) begin acc = acc + 256 - 720; x = x + 1; end else acc = acc + 256;
    end
  end
  $display("textdisp @ 256/720: checked=%0d bad=%0d", checked, bad);
  $finish;
end
endmodule
