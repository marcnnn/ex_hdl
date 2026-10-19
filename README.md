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
| Stream kernels to SystemVerilog (`ExHdl.Backends.SystemVerilog.Scan`): AXI4-Stream module per kernel, bit-identical with the Nx reference (ex_sdr's ddc, fir_complex, one_pole co-simulated) | done |
| Resource estimates with Yosys `synth_xilinx` (`ExHdl.Synth.Yosys`, `mix ex_hdl.gen.sv --synth`) | done |
| Retiming, DSP cascades for FIR adder trees, `accelerator` DSL | planned |
| openXC7 bitstream builder, Zynq runtime | planned |

## Development

```sh
mix test                      # unit and property tests; co-simulation if verilator is in PATH
mix test --only verilator     # co-simulation only
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

The module has AXI4-Stream input and output (backpressure through one
clock enable for the whole pipeline), one port per parameter, signals of
their proven widths, DSP48E1 multiplies, block RAM or LUT ROM tables and
the state register closing the loop. Feedback loops longer than one cycle
run with `ii: n` (one sample every n cycles) or `channels: n` (n
interleaved streams at one sample per cycle).

Yosys `synth_xilinx` for the Q15 instances (synthesis only, no I/O
buffers, no timing):

| Kernel | latency | ii | LUT | FF | DSP48E1 | RAMB18 |
|---|---|---|---|---|---|---|
| ddc (NCO with 1024-entry table, mixer, gain) | 9 | 1 | 179 | 89 | 6 | 1 |
| fir_complex (31 taps, I and Q) | 9 | 1 | 1318 | 2279 | 50 | 0 |
| one_pole | 5 | 5 | 39 | 58 | 1 | 0 |
| one_pole, `channels: 5` | 5 | 1 | 96 | 173 | 1 | 0 |

The FIR's adder trees are fabric adders; mapping them onto DSP48E1
cascades (and folding symmetric taps) is the next step.

The sibling libraries are path dependencies (`../nx_fixed`, and
`../ex_sdr` for integration tests); `scripts/checkout_siblings.sh` clones
them. Requires Elixir 1.18+ and Verilator 5 for co-simulation.
