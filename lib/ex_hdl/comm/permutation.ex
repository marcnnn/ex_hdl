defmodule ExHdl.Comm.Permutation do
  @moduledoc """
  Block permutations (bit, cell or carrier interleavers). Each table is a
  gather: output element j of a block is input element `table[j]`. With
  several tables, block i uses table `rem(i, count)` (e.g. the DVB-T symbol
  interleaver alternates between H and its inverse).
  """
  defstruct [:tables]

  @doc "From one table or a list of tables of equal size (lists or tuples)."
  def new([x | _] = table) when is_integer(x), do: new([table])

  def new(tables) do
    tables = Enum.map(tables, fn t -> if is_tuple(t), do: t, else: List.to_tuple(t) end)
    [size] = tables |> Enum.map(&tuple_size/1) |> Enum.uniq()
    for t <- tables, do: true = Enum.sort(Tuple.to_list(t)) == Enum.to_list(0..(size - 1))
    %__MODULE__{tables: tables}
  end

  @doc "From scatter tables: input element j goes to output `table[j]`."
  def scatter(tables), do: tables |> new() |> inverse()

  def size(%__MODULE__{tables: [t | _]}), do: tuple_size(t)

  def inverse(%__MODULE__{tables: tables}) do
    %__MODULE__{tables: Enum.map(tables, &invert/1)}
  end

  defp invert(t) do
    t
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
    |> List.to_tuple()
  end

  @doc "Applies to a list (whole blocks); the first block has index `first_block`."
  def apply(%__MODULE__{tables: tables} = p, list, first_block \\ 0) do
    size = size(p)
    count = length(tables)

    list
    |> Enum.chunk_every(size)
    |> Enum.with_index(first_block)
    |> Enum.flat_map(fn {block, i} ->
      block = List.to_tuple(block)
      t = Enum.at(tables, rem(i, count))
      for j <- 0..(size - 1), do: elem(block, elem(t, j))
    end)
  end

  @doc "The tables as an `s32[count][size]` tensor."
  def tensor(%__MODULE__{tables: tables}),
    do: tables |> Enum.map(&Tuple.to_list/1) |> Nx.tensor(type: :s32)

  @doc """
  Applies to the rows of a `{blocks, size}` tensor whose row r has block
  index r (usable inside `defn` via `deftransform`; `t` from `tensor/1`).
  """
  def apply_tensor(x, t) do
    {count, _} = Nx.shape(t)
    blocks = Nx.axis_size(x, 0)

    if count == 1 do
      Nx.take(x, t[0], axis: 1)
    else
      idx = Nx.take(t, Nx.remainder(Nx.iota({blocks}), count))
      Nx.take_along_axis(x, idx, axis: 1)
    end
  end
end
