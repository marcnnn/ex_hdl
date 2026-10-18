defmodule ExHdl.Types.Refined do
  @moduledoc """
  Prototype of integer refinement types on top of Elixir's type system.

  A type is Elixir's `Module.Types.Descr` with the `integer()` part taken
  out and replaced by an `ExHdl.Types.IntSet`, so `0..65535`, `-32767..32767`
  or `non_neg_integer() or -1` are types of their own. Operations work
  componentwise, which is sound because `integer()` is disjoint from every
  other basic type.

  Limitation: only top-level integers are refined. Integers inside tuples,
  lists or maps stay plain `integer()`; refining those needs support inside
  Descr itself.

  `erase/1` maps back to plain Descr. The test suite checks that erasure is
  a sound over-approximation, which is the property an upstream integration
  would have to keep.
  """
  @behaviour ExHdl.Types.SetAlgebra

  alias ExHdl.Types.{ElixirDescr, IntSet}
  alias Module.Types.Descr, as: D

  defstruct [:descr, :int]

  @type t :: %__MODULE__{descr: term(), int: IntSet.t()}

  @impl true
  def none, do: %__MODULE__{descr: D.none(), int: IntSet.none()}
  @impl true
  def term, do: %__MODULE__{descr: D.difference(D.term(), D.integer()), int: IntSet.integer()}

  @impl true
  def leaf({:int, _, _} = leaf), do: integer(IntSet.leaf(leaf))
  def leaf(:integer), do: integer(IntSet.integer())
  def leaf(:term), do: term()
  def leaf(:none), do: none()
  def leaf(other), do: from_descr(ElixirDescr.leaf(other))

  @doc "Lifts a plain Descr type (its integer part becomes all integers)."
  def from_descr(descr) do
    int =
      if D.empty?(D.intersection(descr, D.integer())), do: IntSet.none(), else: IntSet.integer()

    %__MODULE__{descr: D.difference(descr, D.integer()), int: int}
  end

  @doc "An integer-only type."
  def integer(set) when is_list(set), do: %__MODULE__{descr: D.none(), int: set}

  @doc "Forgets the refinement: the plain Descr type that contains this one."
  def erase(%__MODULE__{descr: d, int: i}),
    do: if(IntSet.empty?(i), do: d, else: D.union(d, D.integer()))

  @impl true
  def union(a, b),
    do: %__MODULE__{descr: D.union(a.descr, b.descr), int: IntSet.union(a.int, b.int)}

  @impl true
  def intersection(a, b),
    do: %__MODULE__{
      descr: D.intersection(a.descr, b.descr),
      int: IntSet.intersection(a.int, b.int)
    }

  @impl true
  def difference(a, b),
    do: %__MODULE__{descr: D.difference(a.descr, b.descr), int: IntSet.difference(a.int, b.int)}

  @impl true
  def negation(a),
    do: %__MODULE__{
      descr: D.difference(D.negation(a.descr), D.integer()),
      int: IntSet.negation(a.int)
    }

  @impl true
  def empty?(a), do: D.empty?(a.descr) and IntSet.empty?(a.int)

  @impl true
  def subtype?(a, b), do: D.subtype?(a.descr, b.descr) and IntSet.subtype?(a.int, b.int)

  @impl true
  def equal?(a, b), do: D.equal?(a.descr, b.descr) and IntSet.equal?(a.int, b.int)

  @impl true
  def member?(a, v) when is_integer(v), do: IntSet.member?(a.int, v)
  def member?(a, v), do: ElixirDescr.member?(a.descr, v)

  @impl true
  def to_quoted_string(a) do
    parts =
      [
        if(D.empty?(a.descr), do: nil, else: D.to_quoted_string(a.descr)),
        if(IntSet.empty?(a.int), do: nil, else: IntSet.to_quoted_string(a.int))
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: "none()", else: Enum.join(parts, " or ")
  end
end
