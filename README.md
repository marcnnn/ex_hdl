# ExHdl

Elixir-to-FPGA co-design for the Xilinx Zynq-7020: packet protocols and
fixed-point DSP kernels written once in Elixir, compiled to bit-identical
software and SystemVerilog hardware.

## Status

| Area | State |
|---|---|
| `ExHdl.Protocol`: `defpacket` DSL, BEAM codecs, AXI4-Stream parser/emitter in SystemVerilog | done |
| Verilator co-simulation (`ExHdl.Sim.Verilator`) | done |
| Fixed-point DSP: dataflow IR, range analysis (`ExHdl.Passes.WidthCheck`), primitives (NCO, complex mixer, FIR with constant taps, rounding shifts), checked Nx reference compiler | done |
| Stateful streams: recurrence analysis, `ii:`/`channels:`, Zynq timing model (`ExHdl.DSP.analyze_scan`) | done |
| Format-generic algorithms (`ExHdl.Num`, `ExHdl.DSP.Blocks`): one definition, float reference or fixed point (`q(bits, frac)`) | done |
| GNU Radio 3.10 comparison: float instance vs GNU Radio, fixed-point variants vs float instance | done |
| Nx-to-SystemVerilog, retiming, `accelerator` DSL | planned |
| CPU: compiled block loop (EXLA) and Highway SIMD NIF for Q15 blocks, bit-identical; see `docs/cpu_backend.md` | done |
| `ExHdl.SIMD.Compiler`: native code generated from integer `defn` graphs (Nx compiler, like EXLA) | done |
| Quantized ML: int8 fully connected layer with TFLite semantics (`ExHdl.ML.Quantized`) | first block |
| DVB-T transmitter and receiver, stage by stage and end to end against gr-dtv; see `docs/dvbt.md` | reference implementation |
| DVB-T transmitter and receiver (2k), compared with GNU Radio gr-dtv stage by stage and end to end; see `docs/dvbt.md` | reference implementation |
| openXC7 bitstream builder, Zynq runtime | planned |

## Development

```sh
mix test                      # unit and property tests; co-simulation if verilator is in PATH
mix test --only verilator     # co-simulation only
mix test --only elixir_types  # law suites against Elixir's type system, see test/types/README.md
mix ex_hdl.gen.sv MyApp.Protocol --out hdl/generated
mix test --only dvbt          # DVB-T against gr-dtv reference data
mix test --only gnuradio_live # run the DSP cases against live GNU Radio (native or rootless podman)
scripts/gnuradio_golden.sh    # regenerate test/fixtures/gnuradio/ after changing a case
```

### DSP cases

Each file in `test/dsp_cases/` describes one test once: input signal,
parameters, the `ExHdl.DSP.Blocks` block, the GNU Radio block chain, and
expectations with their reasoning for two layers:

1. `float_vs_gnuradio`: the block's float instance against GNU Radio
   (is the algorithm right?)
2. `fixed_vs_float`: each fixed-point variant (`bits`, `frac`, `rounding`,
   `lut_bits`) against the float instance (what does the format cost?)

`test/gnuradio/golden.py` runs the GNU Radio side, `test/gnuradio_reference_test.exs`
the ExHdl side; outputs are compared sample by sample. Adding a case or a
format variant is editing JSON and running `scripts/gnuradio_golden.sh`;
stale reference data fails the tests.

Requires Elixir 1.18+, a C++17 compiler, `make` and `curl` (the SIMD NIF
fetches Google Highway on first build), and Verilator 5 for co-simulation.

```sh
MIX_ENV=test mix run scripts/bench_cpu.exs   # CPU throughput per implementation
MIX_ENV=test mix run scripts/bench_ml.exs    # int8 dense layer: generated code vs EXLA
```
