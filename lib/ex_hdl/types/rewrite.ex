defmodule ExHdl.Types.Rewrite do
  @moduledoc """
  Semantics-preserving rewrites of `ExHdl.Types.Expr` type expressions.

  Every rewrite denotes the same set of values, so any algebra must treat
  the result as equal to the input (and give equal results under every
  operation). Used for metamorphic testing of type implementations: it
  catches results that depend on how a type was built rather than on what
  it denotes.
  """

  @doc "Applies rewrite number `rule` at the root of `e`, with `x` as a free type."
  def apply_rule(e, rule, x) do
    case {rule, e} do
      {0, _} -> {:negation, {:negation, e}}
      {1, _} -> {:union, e, :none}
      {2, _} -> {:intersection, e, :term}
      {3, _} -> {:difference, e, :none}
      {4, _} -> {:union, e, e}
      {5, _} -> {:intersection, e, e}
      {6, _} -> {:difference, :term, {:negation, e}}
      # absorption: e or (e and x) = e,  e and (e or x) = e
      {7, _} -> {:union, e, {:intersection, e, x}}
      {8, _} -> {:intersection, e, {:union, e, x}}
      # e = (e and x) or (e and not x)
      {9, _} -> {:union, {:intersection, e, x}, {:difference, e, x}}
      # De Morgan and commutativity on compound expressions
      {10, {:union, a, b}} -> {:negation, {:intersection, {:negation, a}, {:negation, b}}}
      {10, {:intersection, a, b}} -> {:negation, {:union, {:negation, a}, {:negation, b}}}
      {11, {op, a, b}} when op in [:union, :intersection] -> {op, b, a}
      {12, {:difference, a, b}} -> {:intersection, a, {:negation, b}}
      {13, {:negation, {:negation, a}}} -> a
      _ -> e
    end
  end

  def rule_count, do: 14

  @doc "Applies `rule` at the node reached by `path` (indexes into children)."
  def apply_at(e, [], rule, x), do: apply_rule(e, rule, x)

  def apply_at({op, a, b}, [0 | path], rule, x) when op in [:union, :intersection, :difference],
    do: {op, apply_at(a, path, rule, x), b}

  def apply_at({op, a, b}, [_ | path], rule, x) when op in [:union, :intersection, :difference],
    do: {op, a, apply_at(b, path, rule, x)}

  def apply_at({:negation, a}, [_ | path], rule, x), do: {:negation, apply_at(a, path, rule, x)}

  def apply_at({:tuple, elems}, [i | path], rule, x) when elems != [] do
    i = rem(i, length(elems))
    {:tuple, List.update_at(elems, i, &apply_at(&1, path, rule, x))}
  end

  def apply_at(e, _path, rule, x), do: apply_rule(e, rule, x)
end
