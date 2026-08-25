# SPDX-License-Identifier: GPL-3.0-or-later

# Tang Primer 25K, pcetang Phase 1. Same clock/PLL math as Console 60K's Phase 1 (same
# GW5A PLLA primitive, same real measured constraints) -- see that board's .sdc header.
# clk_sdram (120 MHz off the same console60k_pll instance) is a fourth domain here,
# unlike Console 60K where it's unused -- not separately declared below since
# NECTang's own primer25k_core_test.sdc doesn't constrain it either (inherits from
# whatever default/derived constraint the tool infers); revisit if timing closure on
# that domain turns out to need it.

create_clock -name clk -period 20.000 [get_ports {clk}]

create_generated_clock -name clk_pce -source [get_ports {clk}] -master_clock clk -divide_by 7 -multiply_by 6 [get_nets {clk_pce}]

create_generated_clock -name clk_pixel -source [get_ports {clk}] -master_clock clk -divide_by 2 -multiply_by 3 [get_nets {clk_pixel}]

create_generated_clock -name clk_5x_pixel -source [get_ports {clk}] -master_clock clk -divide_by 2 -multiply_by 15 [get_nets {clk_5x_pixel}]

set_clock_groups -asynchronous -group [get_clocks {clk_pce}] -group [get_clocks {clk_pixel clk_5x_pixel}]
