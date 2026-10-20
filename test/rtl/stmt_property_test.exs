defmodule ExHdl.RTL.StmtPropertyTest do
  @moduledoc """
  Random comb and sync blocks (nested if/switch over random expressions,
  registers feeding back) simulate identically in the BEAM and Verilator.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExHdl.RTL.{Builder, Cosim, Expr, Sim}
  alias ExHdl.Test.RTLGen

  @moduletag :verilator
  @moduletag timeout: 900_000

  # Registers replace the inputs a, c and f, so expressions read state.
  @regs [a: {:u, 8}, c: {:s, 8}, f: {:u, 1}]
  @outs [y0: {:u, 8}, y1: {:s, 8}]

  defp stmts(targets, depth) do
    assign = tuple({constant(:assign), member_of(targets), RTLGen.ast()})

    if depth == 0 do
      list_of(assign, min_length: 1, max_length: 3)
    else
      sub = stmts(targets, depth - 1)

      list_of(
        one_of([
          assign,
          tuple({constant(:if), RTLGen.ast(), sub, sub}),
          tuple(
            {constant(:switch), RTLGen.ast(),
             list_of(tuple({uniq_list_of(integer(0..3), min_length: 1, max_length: 2), sub}),
               max_length: 3
             ), one_of([constant(nil), sub])}
          )
        ]),
        min_length: 1,
        max_length: 3
      )
    end
  end

  defp fit(e, {s, w}) do
    e = if s == :s, do: Expr.as_signed(e), else: Expr.as_unsigned(e)
    Expr.resize(e, w)
  end

  defp run(stmts, handles, types) do
    for s <- stmts do
      case s do
        {:assign, t, ast} ->
          Builder.assign(handles[t], fit(RTLGen.build(ast, handles), types[t]))

        {:if, c, a, b} ->
          Builder.if_(
            Expr.reduce_or(RTLGen.build(c, handles)),
            fn -> run(a, handles, types) end,
            fn -> run(b, handles, types) end
          )

        {:switch, subj, cases, default} ->
          sel = RTLGen.build(subj, handles) |> Expr.as_unsigned() |> Expr.resize(2)

          {cases, _} =
            Enum.map_reduce(cases, [], fn {vs, body}, seen -> {{vs -- seen, body}, seen ++ vs} end)

          cases = Enum.reject(cases, &(elem(&1, 0) == []))

          clauses =
            for {vs, body} <- cases, do: {fn -> vs end, fn -> run(body, handles, types) end}

          clauses =
            if default,
              do: clauses ++ [{:default, fn -> run(default, handles, types) end}],
              else: clauses

          Builder.switch(sel, clauses)
      end
    end
  end

  defp design(sync_stmts, comb_stmts) do
    require ExHdl.RTL

    ExHdl.RTL.module "stmt_fuzz" do
      inputs =
        for {n, t} <- RTLGen.inputs(),
            not Keyword.has_key?(@regs, n),
            into: %{},
            do: {n, ExHdl.RTL.input(n, t)}

      regs = for {n, t} <- @regs, into: %{}, do: {n, ExHdl.RTL.reg(:"r#{n}", t, reset: 0)}
      outs = for {n, t} <- @outs, into: %{}, do: {n, ExHdl.RTL.output(n, t)}

      for {n, t} <- @regs do
        q = ExHdl.RTL.output(:"q#{n}", t)
        Builder.assign(q, regs[n])
      end

      handles = Map.merge(inputs, regs)
      Builder.sync(nil, fn -> run(sync_stmts, handles, Map.new(@regs)) end)

      Builder.comb(fn ->
        for {n, _} <- @outs, do: Builder.assign(outs[n], 0)
        run(comb_stmts, Map.merge(handles, outs), Map.new(@outs))
      end)
    end
  end

  defp stimulus(n, seed) do
    vectors = RTLGen.random_inputs() |> StreamData.seeded(seed) |> Enum.take(n)

    vectors
    |> Enum.with_index()
    |> Enum.map(fn {v, i} ->
      v |> Map.drop(Keyword.keys(@regs)) |> Map.put(:rst_n, if(i < 2, do: 0, else: 1))
    end)
  end

  property "random statement trees: BEAM and Verilator agree" do
    check all(
            sync_stmts <- stmts(Keyword.keys(@regs), 2),
            comb_stmts <- stmts(Keyword.keys(@outs), 2),
            seed <- integer(0..10_000),
            max_runs: 4
          ) do
      m = design(sync_stmts, comb_stmts)
      Sim.new(m)
      Cosim.assert_equivalent(m, stimulus(120, seed))
    end
  end
end
