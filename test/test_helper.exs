# :verilator - co-simulation, needs verilator in PATH
# :yosys - resource checks, needs yosys in PATH
# :cc - compiles generated C headers, needs cc in PATH
exclude =
  [verilator: "verilator", yosys: "yosys", cc: "cc"]
  |> Enum.reject(fn {_tag, exe} -> System.find_executable(exe) end)
  |> Enum.map(fn {tag, _} -> {tag, true} end)

ExUnit.start(exclude: exclude)
