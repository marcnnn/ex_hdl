defmodule ExHdl.Test.TypeGen do
  @moduledoc false
  # Generators of ExHdl.Types.Expr type expressions and of values.
  use ExUnitProperties

  alias ExHdl.Types.IntSet

  # Type expressions up to LAW_DEPTH levels of operations (default 4).
  # `leaf` is a function of the remaining depth so tuples can nest.
  defp ops(leaf), do: ops(leaf, depth())

  defp ops(leaf, 0), do: leaf.(0)

  defp ops(leaf, depth) do
    child = ops(leaf, depth - 1)

    frequency([
      {1, leaf.(depth)},
      {2, map({child, child}, fn {a, b} -> {:union, a, b} end)},
      {2, map({child, child}, fn {a, b} -> {:intersection, a, b} end)},
      {2, map({child, child}, fn {a, b} -> {:difference, a, b} end)},
      {1, map(child, &{:negation, &1})}
    ])
  end

  defp depth, do: String.to_integer(System.get_env("LAW_DEPTH") || "4")

  # -- integers ------------------------------------------------------------------

  def int_leaf do
    one_of([
      bind({integer(-20..20), integer(0..10)}, fn {lo, len} -> constant({:int, lo, lo + len}) end),
      map(integer(-20..20), &{:int, &1, &1}),
      member_of([{:int, 0, :pos_inf}, {:int, 1, :pos_inf}, {:int, :neg_inf, -1}, :integer, :none])
    ])
  end

  def int_expr, do: ops(fn _ -> int_leaf() end)
  def int_value, do: integer(-25..25)

  def finite_int_set do
    bind(list_of({integer(-40..40), integer(0..12)}, min_length: 1, max_length: 4), fn ivs ->
      constant(
        ivs
        |> Enum.map(fn {lo, len} -> IntSet.range(lo, lo + len) end)
        |> Enum.reduce(&IntSet.union/2)
      )
    end)
  end

  # -- Elixir types ------------------------------------------------------------------

  defp basic_leaf do
    one_of([
      member_of([:integer, :float, :binary, :atom, :empty_list, :none, :term]),
      map(list_of(member_of([:a, :b, :c]), min_length: 1, max_length: 3), &{:atom, Enum.uniq(&1)})
    ])
  end

  # Tuples of arity 2, whose elements are themselves expressions of at most
  # depth - 2 (so nesting stays bounded).
  def descr_leaf(depth) do
    elem = if depth >= 2, do: ops(fn d -> descr_leaf(d) end, depth - 2), else: basic_leaf()

    frequency([
      {3, basic_leaf()},
      {2, map({elem, elem}, fn {x, y} -> {:tuple, [x, y]} end)}
    ])
  end

  def descr_expr, do: ops(&descr_leaf/1)

  def value do
    simple = one_of([int_value(), member_of([:a, :b, :c, :d, 1.5, "bin", []])])
    one_of([simple, map({simple, simple}, fn {x, y} -> {x, y} end)])
  end

  @doc "1 to 4 semantics-preserving rewrite steps `{path, rule, x}`."
  def rewrites(types) do
    rule = integer(0..(ExHdl.Types.Rewrite.rule_count() - 1))
    step = {list_of(integer(0..3), max_length: 6), rule, types}
    list_of(step, min_length: 1, max_length: 4)
  end

  # -- refined -------------------------------------------------------------------------

  def refined_expr, do: ops(fn d -> one_of([descr_leaf(d), int_leaf()]) end)
end
