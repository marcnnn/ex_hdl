# :verilator - co-simulation, needs verilator in PATH
# :yosys - resource checks, needs yosys in PATH
exclude =
  [verilator: "verilator", yosys: "yosys"]
  |> Enum.reject(fn {_tag, exe} -> System.find_executable(exe) end)
  |> Enum.map(fn {tag, _} -> {tag, true} end)

ExUnit.start(exclude: exclude)
