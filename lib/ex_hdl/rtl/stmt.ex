defmodule ExHdl.RTL.Stmt do
  @moduledoc false
  # Statement trees of comb/sync blocks:
  #   {:assign, target, expr}
  #   {:if, cond, then_stmts, else_stmts}
  #   {:switch, subject, [{[const_expr], stmts}], default_stmts | nil}

  alias ExHdl.RTL.Expr

  def targets(stmts), do: stmts |> do_targets([]) |> Enum.reverse() |> Enum.uniq()

  defp do_targets(stmts, acc) do
    Enum.reduce(stmts, acc, fn
      {:assign, t, _}, acc ->
        [t | acc]

      {:if, _, a, b}, acc ->
        do_targets(b, do_targets(a, acc))

      {:switch, _, cases, d}, acc ->
        cases
        |> Enum.reduce(acc, fn {_, s}, acc -> do_targets(s, acc) end)
        |> then(&do_targets(d || [], &1))
    end)
  end

  @doc "Keeps only assignments to `keep` (a MapSet), dropping empty control structures."
  def slice(stmts, keep) do
    Enum.flat_map(stmts, fn
      {:assign, t, _} = s ->
        if MapSet.member?(keep, t), do: [s], else: []

      {:if, c, a, b} ->
        case {slice(a, keep), slice(b, keep)} do
          {[], []} -> []
          {a, b} -> [{:if, c, a, b}]
        end

      {:switch, subj, cases, d} ->
        cases = Enum.map(cases, fn {vs, s} -> {vs, slice(s, keep)} end)
        d = d && slice(d, keep)

        if Enum.all?(cases, &(elem(&1, 1) == [])) and (d == nil or d == []),
          do: [],
          else: [{:switch, subj, cases, d}]
    end)
  end

  @doc "Signals read by the statements (conditions and right-hand sides)."
  def reads(stmts), do: stmts |> do_reads([]) |> Enum.uniq()

  defp do_reads(stmts, acc) do
    Enum.reduce(stmts, acc, fn
      {:assign, _, e}, acc ->
        Expr.reads(e, acc)

      {:if, c, a, b}, acc ->
        do_reads(b, do_reads(a, Expr.reads(c, acc)))

      {:switch, subj, cases, d}, acc ->
        acc = Expr.reads(subj, acc)
        acc = Enum.reduce(cases, acc, fn {_, s}, acc -> do_reads(s, acc) end)
        do_reads(d || [], acc)
    end)
  end

  @doc "All expressions of the statements (conditions, subjects, right-hand sides)."
  def exprs(stmts) do
    Enum.flat_map(stmts, fn
      {:assign, _, e} -> [e]
      {:if, c, a, b} -> [c | exprs(a) ++ exprs(b)]
      {:switch, s, cases, d} -> [s | Enum.flat_map(cases, &exprs(elem(&1, 1)))] ++ exprs(d || [])
    end)
  end

  @doc "Maps every expression with `f`."
  def map_exprs(stmts, f) do
    Enum.map(stmts, fn
      {:assign, t, e} ->
        {:assign, t, f.(e)}

      {:if, c, a, b} ->
        {:if, f.(c), map_exprs(a, f), map_exprs(b, f)}

      {:switch, s, cases, d} ->
        {:switch, f.(s), Enum.map(cases, fn {vs, st} -> {Enum.map(vs, f), map_exprs(st, f)} end),
         d && map_exprs(d, f)}
    end)
  end

  @doc "True if every path through the statements assigns `t`."
  def covers?(stmts, t) do
    Enum.any?(stmts, fn
      {:assign, ^t, _} ->
        true

      {:assign, _, _} ->
        false

      {:if, _, a, b} ->
        covers?(a, t) and covers?(b, t)

      {:switch, subj, cases, d} ->
        Enum.all?(cases, &covers?(elem(&1, 1), t)) and
          if d, do: covers?(d, t), else: full?(subj, cases)
    end)
  end

  defp full?(subj, cases) do
    n = cases |> Enum.flat_map(&elem(&1, 0)) |> Enum.uniq() |> length()
    n == Bitwise.bsl(1, Expr.width(subj))
  end
end
