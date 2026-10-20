defmodule ExHdl do
  @moduledoc """
  Elixir-to-FPGA co-design framework.

  Milestone 1 (implemented): `ExHdl.Protocol` packet DSL with generated BEAM
  codecs, SystemVerilog AXI4-Stream parser/emitter
  (`ExHdl.Backends.SystemVerilog.Protocol`) and Verilator co-simulation
  (`ExHdl.Sim.Verilator`).

  RTL layer: `ExHdl.RTL` (module DSL), `ExHdl.Backends.SystemVerilog.RTL`,
  `ExHdl.RTL.Sim`, `ExHdl.RTL.Cosim`, `ExHdl.RTL.CDC`. Design note:
  `docs/rtl_dsl.md`.
  """
end
