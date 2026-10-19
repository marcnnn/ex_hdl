# :verilator   - co-simulation, needs verilator in PATH
# :elixir_types - law suites against Elixir's own type system
#                 (run with `mix test --only elixir_types`, see test/types/README.md)
# :gnuradio_live - runs GNU Radio during the test (native or podman)
#                  (run with `mix test --only gnuradio_live`)
# :dvbt - DVB-T comparison against gr-dtv reference data (tens of seconds)
# :dvbt_live - DVB-T end to end against gr-dtv's receiver (podman)
exclude = [elixir_types: true, gnuradio_live: true, dvbt: true, dvbt_live: true]

exclude =
  if System.find_executable("verilator"), do: exclude, else: [{:verilator, true} | exclude]

ExUnit.start(exclude: exclude)
