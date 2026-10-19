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
| Nx-to-SystemVerilog, retiming, `accelerator` DSL | planned |
| openXC7 bitstream builder, Zynq runtime | planned |

## Development

```sh
mix test                      # unit and property tests; co-simulation if verilator is in PATH
mix test --only verilator     # co-simulation only
mix ex_hdl.gen.sv MyApp.Protocol --out hdl/generated
```

The sibling libraries are path dependencies (`../nx_fixed`, and
`../ex_sdr` for integration tests); `scripts/checkout_siblings.sh` clones
them. Requires Elixir 1.18+ and Verilator 5 for co-simulation.
