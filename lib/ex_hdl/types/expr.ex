defmodule ExHdl.Types.Expr do
  @moduledoc """
  Version-independent type expressions.

  Types are generated and stored symbolically and only built into a concrete
  representation by an algebra (`build/2`). This keeps test cases portable
  across Elixir releases (whose `Module.Types.Descr` internals differ) and
  printable as plain Elixir code (`to_code/2`).

  Leaves: `:integer`, `:float`, `:binary`, `:atom`, `:empty_list`, `:none`,
  `:term`, `{:atom, [atom]}`, `{:tuple, [expr]}`, `{:int, lo, hi}` (bounds may
  be `:neg_inf`/`:pos_inf`). Operations: `{:union, a, b}`,
  `{:intersection, a, b}`, `{:difference, a, b}`, `{:negation, a}`.
  """

  @type t :: term()

  @ops [:union, :intersection, :difference]

  @doc "Builds the expression with the algebra's operations and `leaf/1`."
  def build({op, a, b}, alg) when op in @ops, do: apply(alg, op, [build(a, alg), build(b, alg)])
  def build({:negation, a}, alg), do: alg.negation(build(a, alg))
  def build(leaf, alg), do: alg.leaf(leaf)

  @doc """
  Elixir source that builds the expression. With `:descr`, the code only
  uses `Module.Types.Descr` (aliased as `D`); otherwise it calls
  `alg.leaf/1` and the algebra functions on a variable `alg`.
  """
  def to_code({op, a, b}, mode) when op in @ops,
    do: "#{prefix(mode)}.#{op}(#{to_code(a, mode)}, #{to_code(b, mode)})"

  def to_code({:negation, a}, mode), do: "#{prefix(mode)}.negation(#{to_code(a, mode)})"
  def to_code(leaf, :descr), do: descr_leaf(leaf)
  def to_code(leaf, :alg), do: "alg.leaf(#{inspect(leaf)})"

  defp prefix(:descr), do: "D"
  defp prefix(:alg), do: "alg"

  defp descr_leaf({:atom, atoms}), do: "D.atom(#{inspect(atoms)})"

  defp descr_leaf({:tuple, elems}),
    do: "D.tuple([#{Enum.map_join(elems, ", ", &to_code(&1, :descr))}])"

  defp descr_leaf({:int, _, _}), do: "D.integer()"
  defp descr_leaf(name) when is_atom(name), do: "D.#{name}()"
end
