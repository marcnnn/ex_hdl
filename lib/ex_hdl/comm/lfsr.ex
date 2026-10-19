defmodule ExHdl.Comm.LFSR do
  @moduledoc """
  Fibonacci linear feedback shift register.

  Stages are numbered 1..`length` from the input side. Each step the
  feedback (XOR of the `taps` stages) shifts in at stage 1; the step output
  is either the feedback (`output: :feedback`, the usual additive
  scrambler, e.g. DVB `1 + x^14 + x^15` = taps `[14, 15]`) or the last
  stage before the shift (`output: :last`).

  `seed` gives the initial stages as an integer, stage 1 as the most
  significant of `length` bits (as standards print them).
  """
  import Bitwise

  defstruct [:length, :taps, :output, :state]

  def new(opts) do
    length = Keyword.fetch!(opts, :length)
    taps = Keyword.fetch!(opts, :taps)
    true = Enum.all?(taps, &(&1 in 1..length))

    %__MODULE__{
      length: length,
      taps: Enum.map(taps, &(length - &1)),
      output: Keyword.get(opts, :output, :feedback),
      state: Keyword.fetch!(opts, :seed)
    }
  end

  @doc "One step: `{bit, lfsr}`."
  def step(%__MODULE__{state: s, taps: taps, length: n} = r) do
    fb = Enum.reduce(taps, 0, &bxor(&2, s >>> &1 &&& 1))
    out = if r.output == :feedback, do: fb, else: s &&& 1
    {out, %{r | state: s >>> 1 ||| fb <<< (n - 1)}}
  end

  @doc "`count` output bits: `{bits, lfsr}`."
  def bits(r, count) do
    {bits, r} = Enum.map_reduce(List.duplicate(nil, count), r, fn _, r -> step(r) end)
    {bits, r}
  end

  @doc "`count` bytes of output, the first bit as MSB: `{binary, lfsr}`."
  def bytes(r, count) do
    {bits, r} = bits(r, 8 * count)
    {for(<<b::8 <- for(x <- bits, into: <<>>, do: <<x::1>>)>>, into: <<>>, do: <<b>>), r}
  end
end
