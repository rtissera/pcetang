#!/bin/sh
# Verilator test of iosys_bl616's save-RAM interface. Real UART bit timing in and out, a
# model of the dual-port backup RAM on port B. Exit status is the verdict.
set -e
cd "$(dirname "$0")"
sed -E '/ASSERTION_ERROR PARAMETER_OUT_OF_RANGE/d' ../../src/iosys/uart_fixed.v > uart_sim.v  # verilator rejects that compile-time assert trick
rm -rf obj_dir
verilator --cc --exe --build -j 4 -Wno-fatal -DSIM -GSAVE_IF=1 -GFREQ=42755682 \
    --top-module iosys_bl616 ../../src/iosys/iosys_bl616.v uart_sim.v tb_saveram.cpp -o tb
./obj_dir/tb
