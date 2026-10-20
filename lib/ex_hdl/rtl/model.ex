defmodule ExHdl.RTL.Model do
  @moduledoc """
  Elixir simulation model of a black box (`ExHdl.RTL.black_box/3`, option
  `model:`).

  `inputs` maps every data and reset input port (atom) to its value
  (signed ports as negative integers when negative). `outputs/2` must
  return a value for every output port; it may only depend on the inputs
  listed in the port's `comb_from:`. `clock/3` runs on the rising edge of
  the clock of `domain` (a domain of the black box), with the inputs
  sampled before the edge, and returns the next state.

      defmodule Delay do
        @behaviour ExHdl.RTL.Model
        def init(_params), do: 0
        def outputs(q, _inputs), do: %{q: q}
        def clock(:sys, _q, inputs), do: inputs.d
      end
  """

  @callback init(params :: keyword()) :: term()
  @callback outputs(state :: term(), inputs :: %{atom() => integer()}) :: %{atom() => integer()}
  @callback clock(domain :: atom(), state :: term(), inputs :: %{atom() => integer()}) :: term()
end
