defmodule ExHdl.Types.Minimize do
  @moduledoc """
  Delta debugging for law violations.

  Given a law, an algebra and a failing environment of type expressions,
  repeatedly replaces subexpressions by one of their children or by a
  simpler leaf, keeping every step that still fails, until no single step
  helps. Runs on whatever Elixir version executes it, so a case found on one
  release is minimized against that release's `Module.Types.Descr`.
  """

  alias ExHdl.Types.Laws

  @leaf_rank %{none: 0, term: 1, integer: 2, atom: 3, binary: 4, float: 5, empty_list: 6}

  @doc """
  `failing?` decides whether an environment still shows the problem.
  Returns the minimized environment.
  """
  def minimize(env, failing?) do
    case Enum.find(candidates(env), failing?) do
      nil -> env
      smaller -> minimize(smaller, failing?)
    end
  end

  @doc "Predicate for a law that should hold but does not."
  def violates(name, alg, budget_ms \\ 5_000) do
    prop = Keyword.fetch!(Laws.all(), name)

    fn env ->
      task = Task.async(fn -> Laws.holds?(prop, alg, env) end)

      case Task.yield(task, budget_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, false} -> true
        _ -> false
      end
    end
  end

  @doc "Predicate for a law whose evaluation takes longer than `budget_ms`."
  def slow(name, alg, budget_ms) do
    prop = Keyword.fetch!(Laws.all(), name)

    fn env ->
      task = Task.async(fn -> Laws.holds?(prop, alg, env) end)
      Task.yield(task, budget_ms) == nil and Task.shutdown(task, :brutal_kill) == nil
    end
  end

  @doc "Size of an environment: expression nodes, then leaf complexity."
  def cost(env) do
    steps = Map.get(env, :rewrite, [])

    types =
      env |> Map.drop([:v, :rewrite]) |> Map.values() |> Enum.map(&cost_expr/1) |> Enum.sum()

    types + Enum.sum(Enum.map(steps, fn {path, _rule, x} -> 10 + length(path) + cost_expr(x) end))
  end

  defp cost_expr({op, a, b}) when op in [:union, :intersection, :difference],
    do: 10 + cost_expr(a) + cost_expr(b)

  defp cost_expr({:negation, a}), do: 10 + cost_expr(a)
  defp cost_expr({:tuple, elems}), do: 10 + Enum.sum(Enum.map(elems, &cost_expr/1))
  defp cost_expr({:atom, atoms}), do: 7 + length(atoms)
  defp cost_expr({:int, _, _}), do: 8
  defp cost_expr(leaf), do: Map.fetch!(@leaf_rank, leaf)

  # Single-step simplifications of the environment, smallest first.
  defp candidates(env) do
    base = cost(env)

    type_steps =
      for {var, expr} <- env, var not in [:v, :rewrite], smaller <- simplify(expr) do
        Map.put(env, var, smaller)
      end

    # Rewrite steps stay rewrites: drop a step, shorten its path, or
    # simplify its free type. Equivalence of a and b is kept by construction.
    steps = Map.get(env, :rewrite, [])

    rewrite_steps =
      for {{path, rule, x}, i} <- Enum.with_index(steps),
          new <-
            [nil] ++
              Enum.map(1..length(path)//1, &{Enum.drop(path, -&1), rule, x}) ++
              Enum.map(simplify(x), &{path, rule, &1}) do
        Map.put(
          env,
          :rewrite,
          if(new, do: List.replace_at(steps, i, new), else: List.delete_at(steps, i))
        )
      end

    (type_steps ++ rewrite_steps)
    |> Enum.filter(&(cost(&1) < base))
    |> Enum.sort_by(&cost/1)
  end

  defp simplify(expr), do: Enum.uniq(replacements(expr) ++ inner(expr))

  # Replace the whole node.
  defp replacements({op, a, b}) when op in [:union, :intersection, :difference],
    do: [a, b | leaves()]

  defp replacements({:negation, a}), do: [a | leaves()]
  defp replacements({:tuple, _}), do: leaves()

  defp replacements({:atom, [_ | _] = atoms}),
    do: [:atom | for(x <- atoms, atoms != [x], do: {:atom, atoms -- [x]})] ++ leaves()

  defp replacements(_leaf), do: leaves()

  # Simplify one child in place.
  defp inner({op, a, b}) when op in [:union, :intersection, :difference],
    do: Enum.map(simplify(a), &{op, &1, b}) ++ Enum.map(simplify(b), &{op, a, &1})

  defp inner({:negation, a}), do: Enum.map(simplify(a), &{:negation, &1})

  defp inner({:tuple, elems}) do
    for {elem, i} <- Enum.with_index(elems),
        smaller <- simplify(elem),
        do: {:tuple, List.replace_at(elems, i, smaller)}
  end

  defp inner(_), do: []

  defp leaves, do: Map.keys(@leaf_rank)
end
