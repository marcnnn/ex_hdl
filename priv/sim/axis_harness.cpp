// ExHdl generic AXI4-Stream testbench for Verilator.
//
// Drives a top module with the port set
//   clk, rst_n, s_axis_{tdata,tkeep,tlast,tvalid,tready},
//   m_axis_{tdata,tkeep,tlast,tvalid,tready}, dropped_packets
// (bus width <= 64 bits) from a beat file and records the output beats.
//
// usage: sim <in_beats> <out_beats> <seed> <valid_pct> <ready_pct> <max_cycles>
//
// Beat files contain one beat per line: "<tdata hex> <tkeep hex> <tlast 0|1>".
// With -DEXHDL_TUSER the top also has m_axis_tuser, written as a fourth column.
// The output file ends with "dropped <n>" and "cycles <n>".
// Exit codes: 0 ok, 1 usage/io error, 2 cycle limit reached (likely deadlock).
//
// Input tvalid is randomized but obeys AXI4-Stream: once asserted it stays
// asserted with stable data until the handshake. tready is random each cycle.

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <random>
#include <vector>

#include "Vtop.h"
#include "verilated.h"

struct Beat {
    uint64_t data;
    uint64_t keep;
    int last;
};

int main(int argc, char** argv) {
    if (argc != 7) {
        std::fprintf(stderr, "usage: %s in out seed valid_pct ready_pct max_cycles\n", argv[0]);
        return 1;
    }

    std::FILE* in = std::fopen(argv[1], "r");
    if (!in) { std::perror(argv[1]); return 1; }
    std::vector<Beat> beats;
    Beat b;
    while (std::fscanf(in, "%" SCNx64 " %" SCNx64 " %d", &b.data, &b.keep, &b.last) == 3) beats.push_back(b);
    std::fclose(in);

    std::FILE* out = std::fopen(argv[2], "w");
    if (!out) { std::perror(argv[2]); return 1; }

    std::mt19937_64 rng(std::strtoull(argv[3], nullptr, 10));
    const int valid_pct = std::atoi(argv[4]);
    const int ready_pct = std::atoi(argv[5]);
    const uint64_t max_cycles = std::strtoull(argv[6], nullptr, 10);
    std::uniform_int_distribution<int> pct(0, 99);

    auto ctx = std::make_unique<VerilatedContext>();
    auto top = std::make_unique<Vtop>(ctx.get());

    auto tick = [&] {
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();
    };

    top->clk = 0;
    top->rst_n = 0;
    top->s_axis_tvalid = 0;
    top->m_axis_tready = 0;
    top->eval();
    for (int i = 0; i < 4; i++) tick();
    top->rst_n = 1;
    top->eval();

    size_t idx = 0;
    bool offering = false;
    uint64_t cycle = 0, idle = 0;
    // Drain: stop once all input is consumed and the output has been quiet
    // for a while (with tready forced high).
    const uint64_t drain_cycles = 64;

    while (true) {
        if (!offering && idx < beats.size() && pct(rng) < valid_pct) offering = true;

        const bool draining = idx >= beats.size();
        top->s_axis_tvalid = offering;
        if (offering) {
            top->s_axis_tdata = beats[idx].data;
            top->s_axis_tkeep = beats[idx].keep;
            top->s_axis_tlast = beats[idx].last;
        }
        top->m_axis_tready = draining || pct(rng) < ready_pct;
        top->eval();

        const bool in_hs = top->s_axis_tvalid && top->s_axis_tready;
        const bool out_hs = top->m_axis_tvalid && top->m_axis_tready;
        if (out_hs) {
#ifdef EXHDL_TUSER
            std::fprintf(out, "%" PRIx64 " %" PRIx64 " %d %d\n", (uint64_t)top->m_axis_tdata,
                         (uint64_t)top->m_axis_tkeep, (int)top->m_axis_tlast,
                         (int)top->m_axis_tuser);
#else
            std::fprintf(out, "%" PRIx64 " %" PRIx64 " %d\n", (uint64_t)top->m_axis_tdata,
                         (uint64_t)top->m_axis_tkeep, (int)top->m_axis_tlast);
#endif
        }

        tick();
        cycle++;

        if (in_hs) { offering = false; idx++; }

        if (draining && !out_hs) {
            if (++idle >= drain_cycles) break;
        } else {
            idle = 0;
        }
        if (cycle >= max_cycles) {
            std::fprintf(out, "dropped %" PRIu64 "\ncycles %" PRIu64 "\n",
                         (uint64_t)top->dropped_packets, cycle);
            std::fclose(out);
            std::fprintf(stderr, "cycle limit reached at input beat %zu of %zu\n", idx, beats.size());
            return 2;
        }
    }

    std::fprintf(out, "dropped %" PRIu64 "\ncycles %" PRIu64 "\n", (uint64_t)top->dropped_packets, cycle);
    std::fclose(out);
    top->final();
    return 0;
}
