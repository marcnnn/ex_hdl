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
| CPU reference vs GNU Radio 3.10: shared cases in `test/dsp_cases/*.json`, per-sample bounds and SNR | done |
| Nx-to-SystemVerilog, retiming, `accelerator` DSL | planned |
| Google Highway CPU backend | planned |
| openXC7 bitstream builder, Zynq runtime | planned |

## Development

```sh
mix test                      # unit and property tests; co-simulation if verilator is in PATH
mix test --only verilator     # co-simulation only
mix test --only elixir_types  # law suites against Elixir's type system, see test/types/README.md
mix ex_hdl.gen.sv MyApp.Protocol --out hdl/generated
mix test --only gnuradio_live # run the DSP cases against live GNU Radio (native or rootless podman)
scripts/gnuradio_golden.sh    # regenerate test/fixtures/gnuradio/ after changing a case
```

### DSP cases

Each file in `test/dsp_cases/` describes one test once: input signal,
parameters, the ExHdl kernel call, the GNU Radio block chain and the
expected accuracy with its reasoning. `test/gnuradio/golden.py` runs it
through GNU Radio, `test/gnuradio_reference_test.exs` through ExHdl, and the
outputs are compared sample by sample. Adding a case is adding a JSON file
and running `scripts/gnuradio_golden.sh`; stale reference data fails the
tests.

Requires Elixir 1.18+, and Verilator 5 for co-simulation.
