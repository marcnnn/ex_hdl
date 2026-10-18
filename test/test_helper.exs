# :verilator   - co-simulation, needs verilator in PATH
# :elixir_types - law suites against Elixir's own type system
#                 (run with `mix test --only elixir_types`, see test/types/README.md)
# :gnuradio_live - runs GNU Radio during the test (native or podman)
#                  (run with `mix test --only gnuradio_live`)
exclude = [elixir_types: true, gnuradio_live: true]

exclude =
  if System.find_executable("verilator"), do: exclude, else: [{:verilator, true} | exclude]

ExUnit.start(exclude: exclude)
