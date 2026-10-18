# ExHdl

Elixir-to-FPGA co-design for the Xilinx Zynq-7020: packet protocols and
fixed-point DSP kernels written once in Elixir, compiled to bit-identical
software and SystemVerilog hardware.

## Status

| Area | State |
|---|---|
| `ExHdl.Protocol`: `defpacket` DSL, BEAM codecs, AXI4-Stream parser/emitter in SystemVerilog | done |
| Verilator co-simulation (`ExHdl.Sim.Verilator`) | done |
| Fixed-point DSP: dataflow IR, range analysis (`ExHdl.Passes.WidthCheck`), primitives, checked Nx reference compiler | done |
| Stateful streams (`stream_scan`), recurrence analysis | in progress |
| Nx-to-SystemVerilog, retiming, `accelerator` DSL | planned |
| Google Highway CPU backend | planned |
| openXC7 bitstream builder, Zynq runtime | planned |

## Development

```sh
mix test                      # unit and property tests; co-simulation if verilator is in PATH
mix test --only verilator     # co-simulation only
mix test --only elixir_types  # law suites against Elixir's type system, see test/types/README.md
mix ex_hdl.gen.sv MyApp.Protocol --out hdl/generated
```

Requires Elixir 1.18+, and Verilator 5 for co-simulation.
