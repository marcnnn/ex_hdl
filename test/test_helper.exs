# :verilator - co-simulation, needs verilator in PATH
# :yosys - resource checks, needs yosys in PATH
# :cc - compiles generated C headers, needs cc in PATH
# :pnr - place and route with nextpnr-xilinx, slow; mix test --include pnr (needs podman and the
#        exhdl-pnr image, see priv/pnr/Containerfile)
exclude =
  [verilator: "verilator", yosys: "yosys", cc: "cc"]
  |> Enum.reject(fn {_tag, exe} -> System.find_executable(exe) end)
  |> Enum.map(fn {tag, _} -> {tag, true} end)
  |> Keyword.put(:pnr, true)

ExUnit.start(exclude: exclude)
