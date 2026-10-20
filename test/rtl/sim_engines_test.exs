defmodule ExHdl.RTL.SimEnginesTest do
  @moduledoc """
  The compiled simulator engine against the interpreter: every signal of
  the hierarchy agrees after every poke and every event, on random
  statement trees and on the example designs (memories, two clocks,
  black-box models, asynchronous resets).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties
  use ExHdl.RTL

  alias ExHdl.RTL.{Builder, Examples, Expr, Module, Sim}
  alias ExHdl.Test.{RTLDesigns, RTLGen}

  @regs [a: {:u, 8}, c: {:s, 8}, f: {:u, 1}]
  @outs [y0: {:u, 8}, y1: {:s, 8}]

  # -- random statement trees (as in StmtPropertyTest) ------------------------------------

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

          clauses =
            for {vs, body} <- cases,
                vs != [],
                do: {fn -> vs end, fn -> run(body, handles, types) end}

          clauses =
            if default,
              do: clauses ++ [{:default, fn -> run(default, handles, types) end}],
              else: clauses

          Builder.switch(sel, clauses)
      end
    end
  end

  defp design(sync_stmts, comb_stmts, kind) do
    require ExHdl.RTL

    ExHdl.RTL.module "engine_fuzz_#{kind}" do
      ExHdl.RTL.domain(:sys, reset_kind: kind)

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

  property "random statement trees: compiled and interpreted engines agree on every signal" do
    check all(
            sync_stmts <- stmts(Keyword.keys(@regs), 2),
            comb_stmts <- stmts(Keyword.keys(@outs), 2),
            kind <- member_of([:sync, :async]),
            seed <- integer(0..10_000),
            max_runs: 40
          ) do
      m = design(sync_stmts, comb_stmts, kind)
      assert_engines(m, stimulus(m, 40, seed))
    end
  end

  # -- example designs --------------------------------------------------------------------

  test "examples, memories, two clocks, black-box models" do
    designs = [
      {Examples.counter(8), []},
      {Examples.crc32(), []},
      {Examples.skid_buffer(), []},
      {Examples.burst_fsm(4), []},
      {Examples.burst_fsm(5, encoding: :one_hot), []},
      {Examples.ram(width: 16, depth: 16, init: [1, 2, 3]), []},
      {Examples.pulse_counter(), [clocks: [a: [period: 10], b: [period: 15, phase: 5]]]},
      {RTLDesigns.async_fifo(), [clocks: [w: [period: 7], r: [period: 10, phase: 3]]]},
      {RTLDesigns.tdp_ram(), []},
      {RTLDesigns.delay_top(3), []}
    ]

    for {m, opts} <- designs, seed <- 1..3 do
      assert_engines(m, stimulus(m, 150, seed), opts)
    end
  end

  test "a second Sim.new of the same design reuses the compiled code" do
    m = Examples.crc32()
    a = Sim.new(m, engine: :compiled)
    b = Sim.new(m, engine: :compiled)
    assert a.prog.mod == b.prog.mod
    # a rebuilt, equal module too
    assert Sim.new(Examples.crc32(), engine: :compiled).prog.mod == a.prog.mod
  end

  test ":auto interprets small designs and compiles large ones" do
    assert Sim.new(Examples.counter(8)).engine == ExHdl.RTL.Sim.Interp

    # a long chain of 32-bit operations: well above the threshold
    big =
      module "big_chain" do
        d = input(:d, 32)
        y = output(:y, 32, reset: 0)

        x =
          Enum.reduce(1..400, d, fn i, acc ->
            add_wrap(bxor(acc, const(rem(i * 2_654_435_761, 0x100000000), 32)), d)
          end)

        sync :sys do
          y <~ x
        end
      end

    assert Sim.new(big).engine == ExHdl.RTL.Sim.Compiler
  end

  # -- helpers ----------------------------------------------------------------------------

  defp stimulus(m, n, seed) do
    :rand.seed(:exsss, {seed, 7, 11})
    resets = for p <- m.ports, p.role == :reset, do: p.name

    for i <- 0..(n - 1) do
      data =
        for p <- Module.data_inputs(m), into: %{} do
          r = Expr.range(p.type)
          {p.name, Enum.random(r)}
        end

      rst = if i < 2 or :rand.uniform(40) == 1, do: 0, else: 1
      Enum.reduce(resets, data, &Map.put(&2, &1, rst))
    end
  end

  defp assert_engines(m, stimulus, opts \\ []) do
    a = Sim.new(m, [engine: :interpret] ++ opts)
    b = Sim.new(m, opts)
    ids = a.flat.sigs |> Map.keys() |> Enum.sort()
    same!(a, b, ids, m, "after new")

    Enum.reduce(Enum.with_index(stimulus), {a, b}, fn {ins, i}, {a, b} ->
      a = Sim.poke(a, ins)
      b = Sim.poke(b, ins)
      same!(a, b, ids, m, "event #{i} after poke")
      a = Sim.step(a)
      b = Sim.step(b)
      same!(a, b, ids, m, "event #{i} after the edge")
      {a, b}
    end)
  end

  defp same!(a, b, ids, m, where) do
    diffs =
      for id <- ids,
          Sim.peek(a, id) != Sim.peek(b, id),
          do: {id, Sim.peek(a, id), Sim.peek(b, id)}

    assert diffs == [],
           "#{m.name} #{where}: interpreted vs compiled #{inspect(Enum.take(diffs, 5))}"

    for {path, mem} <- a.flat.mems, addr <- 0..(min(mem.depth, 64) - 1) do
      assert Sim.peek_memory(a, path, addr) == Sim.peek_memory(b, path, addr),
             "#{m.name} #{where}: memory #{path}[#{addr}]"
    end
  end
end
