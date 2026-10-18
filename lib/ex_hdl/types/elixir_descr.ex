defmodule ExHdl.Types.ElixirDescr do
  @moduledoc """
  `ExHdl.Types.SetAlgebra` adapter over Elixir's own type representation,
  `Module.Types.Descr`.

  `Module.Types.Descr` is compiler-internal and may change between Elixir
  releases; this adapter only uses its set operations. Static types only
  (no `dynamic()`).

  Membership: a concrete value is checked through its most precise type
  (`value_type/1`). Descr cannot tell integers apart, so every integer has
  type `integer()`: in Descr's model all integers are one point.
  """
  @behaviour ExHdl.Types.SetAlgebra

  alias Module.Types.Descr, as: D

  @impl true
  defdelegate none(), to: D
  @impl true
  defdelegate term(), to: D
  @impl true
  defdelegate union(a, b), to: D
  @impl true
  defdelegate intersection(a, b), to: D
  @impl true
  defdelegate difference(a, b), to: D
  @impl true
  defdelegate negation(a), to: D
  @impl true
  defdelegate empty?(a), to: D
  @impl true
  defdelegate subtype?(a, b), to: D
  @impl true
  defdelegate equal?(a, b), to: D
  @impl true
  defdelegate to_quoted_string(a), to: D

  @impl true
  def leaf({:atom, atoms}), do: D.atom(atoms)
  def leaf({:tuple, elems}), do: D.tuple(Enum.map(elems, &ExHdl.Types.Expr.build(&1, __MODULE__)))
  def leaf({:int, _lo, _hi}), do: D.integer()

  def leaf(name) when name in [:integer, :float, :binary, :atom, :empty_list, :none, :term],
    do: apply(D, name, [])

  @impl true
  def member?(type, value), do: D.subtype?(value_type(value), type)

  @doc "The most precise Descr type of a concrete value."
  def value_type(v) when is_integer(v), do: D.integer()
  def value_type(v) when is_float(v), do: D.float()
  def value_type(v) when is_atom(v), do: D.atom([v])
  def value_type(v) when is_binary(v), do: D.binary()
  def value_type([]), do: D.empty_list()

  def value_type(v) when is_tuple(v),
    do: v |> Tuple.to_list() |> Enum.map(&value_type/1) |> D.tuple()
end
