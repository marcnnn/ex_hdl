defmodule ExHdl.DVBT.Convolutional do
  @moduledoc """
  DVB-T inner code (ETSI EN 300 744, 4.3.4): `ExHdl.Comm.Convolutional`
  with K = 7, G1 = 171 (output X), G2 = 133 (output Y), punctured to 2/3,
  3/4, 5/6 or 7/8 (table 2; transmitted order X1 Y1 Y2 X3 ...).
  """
  alias ExHdl.Comm.Convolutional, as: CC

  # {X pattern, Y pattern} per code rate (EN 300 744, table 2)
  @puncture %{
    {1, 2} => [[1], [1]],
    {2, 3} => [[1, 0], [1, 1]],
    {3, 4} => [[1, 0, 1], [1, 1, 0]],
    {5, 6} => [[1, 0, 1, 0, 1], [1, 1, 0, 1, 0]],
    {7, 8} => [[1, 0, 0, 0, 1, 0, 1], [1, 1, 1, 1, 0, 1, 0]]
  }

  def rates, do: Map.keys(@puncture)

  @doc "The code for a rate."
  def code(rate),
    do:
      CC.new(
        constraint_length: 7,
        polynomials: [0o171, 0o133],
        puncture: Map.fetch!(@puncture, rate)
      )

  def encode(bits, rate \\ {1, 2}), do: CC.encode(code(rate), bits)
  def decode(bits, rate \\ {1, 2}, opts \\ []), do: CC.decode(code(rate), bits, opts)

  def decode_binary(bits, rate \\ {1, 2}, opts \\ []),
    do: CC.decode_binary(code(rate), bits, opts)

  def depunctured_binary(bits, rate), do: CC.depunctured_binary(code(rate), bits)

  def decode_reference(bits, rate \\ {1, 2}, opts \\ []),
    do: CC.decode_reference(code(rate), bits, opts)
end
