// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Romain Tisserand
// Verilator test for iosys_bl616's save-RAM interface (SAVE_IF=1).
// Drives real UART bit timing into uart_rx, models the dual-port backup RAM on port B,
// decodes uart_tx, and checks: restore (0x11), dump (0x12 -> 0x0A), the change notice
// (0x0B) and its re-arming after a dump.
#include "Viosys_bl616.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <deque>
static Viosys_bl616 *t; static uint64_t cyc = 0;
static uint8_t mem[2048];                 // port B model of the dual-port RAM
static const int BIT = 21;                // 42.7 MHz / 2 Mbaud
static std::deque<uint8_t> rxq;           // bytes the FPGA transmitted
static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL: " __VA_ARGS__); printf("\n"); fails++; } } while (0)

// tx decoder state
static int tx_bit = -1, tx_cnt = 0; static uint8_t tx_byte = 0;
static void tick() {
    t->clk = 0; t->eval();
    // registered read, write on the same edge (read-before-write, like the RTL process)
    uint16_t a = t->sv_addr & 2047;
    uint8_t q = mem[a];
    if (t->sv_we) mem[a] = t->sv_din;
    t->clk = 1; t->eval();
    t->sv_q = q; t->eval();
    cyc++;
    // decode uart_tx (8N1)
    if (tx_bit < 0) { if (!t->uart_tx) { tx_bit = 0; tx_cnt = BIT + BIT/2; tx_byte = 0; } }
    else if (--tx_cnt == 0) {
        if (tx_bit < 8) { tx_byte |= (t->uart_tx ? 1 : 0) << tx_bit; tx_bit++; tx_cnt = BIT; }
        else { rxq.push_back(tx_byte); tx_bit = -1; }
    }
}
static void run(int n) { while (n--) tick(); }
static void send_byte(uint8_t b) {
    t->uart_rx = 0; run(BIT);
    for (int i = 0; i < 8; i++) { t->uart_rx = (b >> i) & 1; run(BIT); }
    t->uart_rx = 1; run(BIT * 2);
}
static void send_frame(const std::vector<uint8_t>& payload) {   // payload = cmd + params
    send_byte(0xAA); send_byte(payload.size() >> 8); send_byte(payload.size() & 0xff);
    for (uint8_t b : payload) send_byte(b);
}
// pull the next frame of a given type out of rxq (skipping others, e.g. joypad)
static bool get_frame(uint8_t want, std::vector<uint8_t>& out, int timeout) {
    for (int w = 0; w < timeout; w++) {
        while (rxq.size() >= 4 && rxq[0] != 0xAA) rxq.pop_front();
        if (rxq.size() >= 4) {
            size_t len = (rxq[1] << 8) | rxq[2];
            if (rxq.size() >= 3 + len) {
                uint8_t type = rxq[3];
                std::vector<uint8_t> f(rxq.begin() + 4, rxq.begin() + 3 + len);
                rxq.erase(rxq.begin(), rxq.begin() + 3 + len);
                if (type == want) { out = f; return true; }
                continue;
            }
        }
        run(100);
    }
    return false;
}
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    t = new Viosys_bl616;
    t->uart_rx = 1; t->resetn = 0; t->joy1 = 0; t->joy2 = 0; t->sv_core_we = 0;
    for (int i = 0; i < 2048; i++) mem[i] = 0xEE;
    run(50); t->resetn = 1; run(2000);
    rxq.clear();

    // 1. restore: four 0x11 blocks with a distinct pattern per block
    for (int blk = 0; blk < 4; blk++) {
        std::vector<uint8_t> p = {0x11, 0x00, (uint8_t)blk};
        for (int i = 0; i < 512; i++) p.push_back((uint8_t)(blk * 64 + i * 7));
        send_frame(p);
    }
    run(200);
    int bad = 0;
    for (int blk = 0; blk < 4; blk++)
        for (int i = 0; i < 512; i++) if (mem[blk * 512 + i] != (uint8_t)(blk * 64 + i * 7)) {
            if (bad < 8) printf("  restore blk %d byte %d: got %02x want %02x\n", blk, i, mem[blk*512+i], (uint8_t)(blk*64+i*7));
            bad++; }
    CHECK(bad == 0, "restore: %d of 2048 bytes wrong in the RAM", bad);
    std::vector<uint8_t> f;
    CHECK(!get_frame(0x0B, f, 50), "restore must NOT raise the change notice (only core writes do)");

    // 2. dump block 2 back
    send_frame({0x12, 0x00, 0x02});
    CHECK(get_frame(0x0A, f, 20000), "no 0x0A reply to a block request");
    if (f.size() == 514) {
        CHECK(f[0] == 0 && f[1] == 2, "reply block id %02x%02x, want 0002", f[0], f[1]);
        int bd = 0; for (int i = 0; i < 512; i++) if (f[2 + i] != (uint8_t)(2 * 64 + i * 7)) {
            if (bd < 8) printf("  dump byte %d: got %02x want %02x (next want %02x)\n", i, f[2+i], (uint8_t)(2*64+i*7), (uint8_t)(2*64+(i+1)*7));
            bd++; }
        CHECK(bd == 0, "dump: %d of 512 bytes differ from what was restored", bd);
    } else CHECK(false, "0x0A payload %zu bytes, want 514", f.size());

    // 3. a core write raises exactly one notice
    t->sv_core_we = 1; tick(); t->sv_core_we = 0;
    CHECK(get_frame(0x0B, f, 5000), "core write did not raise 0x0B");
    t->sv_core_we = 1; tick(); t->sv_core_we = 0;
    CHECK(!get_frame(0x0B, f, 300), "second write while still dirty must not re-notify");

    // 4. dumping block 0 cleans it; the next write notifies again
    send_frame({0x12, 0x00, 0x00});
    CHECK(get_frame(0x0A, f, 20000), "no reply for block 0");
    t->sv_core_we = 1; tick(); t->sv_core_we = 0;
    CHECK(get_frame(0x0B, f, 5000), "write after a block-0 dump must notify again");

    printf("%s  (%llu cycles)\n", fails ? "FAILED" : "PASS: save-RAM restore, dump, notice, re-arm", (unsigned long long)cyc);
    delete t; return fails ? 1 : 0;
}
