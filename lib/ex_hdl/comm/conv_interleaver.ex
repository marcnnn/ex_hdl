defmodule ExHdl.Comm.ConvInterleaver do
  @moduledoc """
  Convolutional (Forney) symbol interleaver with `branches` I and unit
  delay `depth` M: symbols cycle through the branches, branch j delays by
  j * M symbols when interleaving and by (I - 1 - j) * M when
  deinterleaving, so the pair delays every symbol by I * (I - 1) * M.
  The delay lines start filled with zeros. Byte symbols (binaries).
  """
  defstruct [:branches, :depth]

  def new(opts),
    do: %__MODULE__{
      branches: Keyword.fetch!(opts, :branches),
      depth: Keyword.fetch!(opts, :depth)
    }

  @doc "Delay of interleaver + deinterleaver in symbols."
  def delay(%__MODULE__{branches: i, depth: m}), do: i * (i - 1) * m

  @doc "Option `:native` as in `ExHdl.Comm.Scrambler.apply/3`."
  def interleave(c, bytes, opts \\ []), do: run(c, bytes, false, opts)
  def deinterleave(c, bytes, opts \\ []), do: run(c, bytes, true, opts)

  defp run(%__MODULE__{branches: i, depth: m}, bytes, inverse?, opts) do
    if Keyword.get_lazy(opts, :native, &ExHdl.SIMD.available?/0) do
      ExHdl.SIMD.NIF.conv_interleave(bytes, i, m, inverse?)
    else
      depth = fn j -> if inverse?, do: (i - 1 - j) * m, else: j * m end

      fifos =
        for j <- 0..(i - 1), into: %{}, do: {j, :queue.from_list(List.duplicate(0, depth.(j)))}

      {out, _} =
        bytes
        |> :binary.bin_to_list()
        |> Enum.with_index()
        |> Enum.map_reduce(fifos, fn {b, n}, fifos ->
          j = rem(n, i)
          {{:value, o}, q} = :queue.out(:queue.in(b, fifos[j]))
          {o, Map.put(fifos, j, q)}
        end)

      :binary.list_to_bin(out)
    end
  end
end
