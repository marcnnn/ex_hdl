# ExHdl

Elixir-to-FPGA co-design for the Xilinx Zynq-7020: packet protocols and
fixed-point stream kernels written once in Elixir, run as software and
generated as SystemVerilog, bit-identical.

## The library family

| Library | Scope |
|---|---|
| [nx_fixed](../nx_fixed) | number formats, fixed-point primitives, range analysis and width check for Nx |
| [nx_simd](../nx_simd) | Nx compiler to native code for integer and quantized graphs |
| [ex_sdr](../ex_sdr) | radio building blocks (DSP, channel coding, OFDM), DVB-T, GNU Radio comparisons |
| **ex_hdl** (this one) | hardware: protocol DSL, SystemVerilog, scheduling and timing, co-simulation |
| [elixir_type_laws](../elixir_type_laws) | set-theoretic laws checked against Elixir's type system |

## Status

| Area | State |
|---|---|
| `ExHdl.Protocol`: `defpacket` DSL, BEAM codecs, AXI4-Stream parser/emitter in SystemVerilog | done |
| Verilator co-simulation (`ExHdl.Sim.Verilator`) | done |
| Stateful streams: recurrence analysis, `ii:`/`channels:`, Zynq timing model (`ExHdl.DSP.analyze_scan/3`, on top of nx_fixed's width check) | done |
| Stream kernels to SystemVerilog (`ExHdl.Backends.SystemVerilog.Scan`): AXI4-Stream module per kernel, bit-identical with the Nx reference | done |
| FIRs as transposed DSP48E1 chains with pre-adder folding, running sums, delay lines in LUT RAM / block RAM (`ExHdl.Backends.SystemVerilog.Fir`) | done |
| Blocks from `%NxFixed.Block{}` descriptions (`ExHdl.Block`), variable-rate outputs; 46 ex_sdr stream blocks co-simulated | done |
| Resource estimates with Yosys `synth_xilinx` (`ExHdl.Synth.Yosys`, `mix ex_hdl.gen.sv --synth`) | done |
| Retiming, `accelerator` DSL | planned |
| openXC7 bitstream builder, Zynq runtime | planned |

## Development

```sh
mix test                      # unit and property tests; co-simulation if verilator is in PATH
mix test --only verilator     # co-simulation only
mix test --only yosys         # resource checks
mix ex_hdl.gen.sv MyApp.Protocol --out hdl/generated
mix ex_hdl.gen.sv MyApp.Kernels --out hdl/generated --synth   # stream kernels, ex_hdl_kernels/0
```

## Stream kernels in hardware

A kernel `step(sample, state, params..., opts) -> {output, next_state}`
written against `NxFixed.Num` goes through nx_fixed's width check (every
value gets a proven integer range), the recurrence analysis and schedule
(`ExHdl.DSP.analyze_scan/3`) and the SystemVerilog backend:

```elixir
{:ok, design} =
  ExHdl.DSP.scan_to_sv(&ExSdr.DSP.Blocks.one_pole/4, [s, s, s, [format: q15]],
    state: 1, ii: :auto, name: "one_pole", param_names: ["alpha"])
```

The module has AXI4-Stream input and output, one port per parameter
plus `p_load`, signals of their proven widths, DSP48E1 multiplies, block
RAM or LUT ROM tables and the state register closing the loop. One clock
enable drives the whole pipeline; it comes from a two-entry output buffer,
so no ready path is combinational. `p_load` captures new parameter values,
which apply once the samples accepted before have left the pipeline.
Feedback loops longer than one cycle run with `ii: n` (one sample every n
cycles) or `channels: n` (n interleaved streams at one sample per cycle).

Structures recognised on the lowered kernel (`ExHdl.Backends.SystemVerilog.Fir`),
from value keys `{delay, base}` that see through the kernel's delay line:

  * dot products of constant taps with one signal at several delays: a
    transposed DSP48E1 chain (post-adder, partial sums advance once per
    sample), symmetric or antisymmetric taps folded through the pre-adder,
    zero taps without multiplier; `fir: :tree` keeps the adder tree
  * equal taps (moving averages): a running sum with the delayed input
    from a memory
  * a take with a data-dependent index into a delay line (convolutional
    interleaver): a memory of the line's input, LUT RAM or block RAM
  * outputs that are the input many samples back (delay blocks): a memory

`ExHdl.Block.scan_to_sv/2` generates a `%NxFixed.Block{}` of kind `:stream`
directly (sample templates from the block's item type and format). Blocks
with `rate: {:variable, max}` get `max` output lanes and a count; the
output buffer sends the valid ones one per beat. test/support/block_cases.ex
lists the co-simulated ex_sdr blocks, one line each.

Yosys `synth_xilinx` for Q15 instances (synthesis only, no I/O buffers,
no timing); latency includes the output buffer:

| Kernel | latency | ii | LUT | FF | DSP48E1 | RAMB18 |
|---|---|---|---|---|---|---|
| ddc (NCO with 1024-entry table, mixer, gain) | 10 | 1 | 224 | 143 | 6 | 1 |
| fir_complex (31 taps, I and Q), adder tree | 10 | 1 | 1324 | 2284 | 50 | 0 |
| fir_complex, DSP chain | 5 | 1 | 45 | 969 | 26 | 0 |
| fir_filter_fff, 63-tap low-pass, adder tree | 11 | 1 | 1212 | 3149 | 46 | 0 |
| fir_filter_fff, 63-tap low-pass, DSP chain | 5 | 1 | 28 | 1417 | 25 | 0 |
| fir_filter_ccf, 63-tap low-pass, adder tree | 11 | 1 | 2414 | 6283 | 92 | 0 |
| fir_filter_ccf, 63-tap low-pass, DSP chain | 5 | 1 | 45 | 2825 | 50 | 0 |
| one_pole | 6 | 5 | 67 | 80 | 1 | 0 |
| one_pole, `channels: 5` | 6 | 1 | 128 | 195 | 1 | 0 |
| moving_average_ff, 1024 | 4 | 1 | 60 | 88 | 0 | 1 |
| delay, 600 samples | 2 | 1 | 30 | 42 | 0 | 1 |
| convolutional interleaver, I = 12, M = 17 | 6 | 1 | 58 | 73 | 1 | 2 |

The FIR chains' remaining flip-flops are the kernel's delay line (needed
by the pre-adder) and the partial sums of zero taps.

The sibling libraries are path dependencies (`../nx_fixed`, and
`../ex_sdr` for integration tests); `scripts/checkout_siblings.sh` clones
them. Requires Elixir 1.18+ and Verilator 5 for co-simulation.
