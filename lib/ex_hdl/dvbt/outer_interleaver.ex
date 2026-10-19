defmodule ExHdl.DVBT.OuterInterleaver do
  @moduledoc """
  Convolutional (Forney) byte interleaver, I = 12 branches, M = 17
  (ETSI EN 300 744, 4.3.3). Branch j delays by j * M bytes when
  interleaving and by (I - 1 - j) * M bytes when deinterleaving; bytes
  cycle through the branches, the sync byte of each 204-byte packet always
  through branch 0. The end-to-end delay is I * (I - 1) * M = 2244 bytes.

  The FIFOs start filled with zeros, as in a freshly reset receiver.
  """
  @i 12
  @m 17

  def interleave(bytes), do: run(bytes, fn j -> j * @m end)
  def deinterleave(bytes), do: run(bytes, fn j -> (@i - 1 - j) * @m end)

  @doc "Total delay in bytes of interleaver + deinterleaver."
  def delay, do: @i * (@i - 1) * @m

  defp run(bytes, depth) do
    fifos =
      for j <- 0..(@i - 1), into: %{}, do: {j, :queue.from_list(List.duplicate(0, depth.(j)))}

    {out, _} =
      bytes
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.map_reduce(fifos, fn {b, n}, fifos ->
        j = rem(n, @i)
        q = :queue.in(b, fifos[j])
        {{:value, o}, q} = :queue.out(q)
        {o, Map.put(fifos, j, q)}
      end)

    :binary.list_to_bin(out)
  end
end
