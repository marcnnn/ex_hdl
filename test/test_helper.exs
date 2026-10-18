# :verilator   - co-simulation, needs verilator in PATH
# :elixir_types - law suites against Elixir's own type system
#                 (run with `mix test --only elixir_types`, see test/types/README.md)
exclude = [elixir_types: true]

exclude =
  if System.find_executable("verilator"), do: exclude, else: [{:verilator, true} | exclude]

ExUnit.start(exclude: exclude)
