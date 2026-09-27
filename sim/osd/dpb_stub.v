// Behavioural stand-in for gowin_dpb_menu, registered read on port B. Test contents:
// character cell (trow, col) holds (col + trow) & 31; font row r of char k is 1 << ((k + r) & 7).
// So OSD pixel (X, Y) is lit exactly when X%8 == ((X/8 + Y/8) + Y%8) % 8 -- it depends on
// both coordinates, so a wrong x OR a wrong y shows up.
module gowin_dpb_menu(input clka, reseta, ocea, cea, input [10:0] ada, input wrea, input [7:0] dina, output [7:0] douta,
                      input clkb, resetb, oceb, ceb, input [10:0] adb, input wreb, input [7:0] dinb, output reg [7:0] doutb);
  assign douta = 8'd0;
  always @(posedge clkb) begin
    if (adb[10] == 1'b0) doutb <= {3'b0, adb[4:0] + adb[9:5]};                  // char = col + trow
    else doutb <= 8'd1 << ((adb[9:3] + adb[2:0]) & 7);                          // font row
  end
endmodule
