defmodule ExHdl.Num.Fixed do
  @moduledoc """
  A fixed-point value: an integer tensor `t` whose real value is
  `t / 2^frac`. `frac` is known while tracing (it is not a tensor), so every
  operation can compute the binary point of its result at compile time.
  """
  @derive {Nx.Container, containers: [:t], keep: [:frac]}
  defstruct [:t, :frac]

  @type t :: %__MODULE__{t: Nx.Tensor.t(), frac: non_neg_integer()}
end
