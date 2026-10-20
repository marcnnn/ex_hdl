defmodule ExHdl.RTL.ExprPropertyTest do
  @moduledoc """
  Expression semantics three ways: random expression trees built with
  ExHdl.RTL.Expr and simulated in the BEAM, the integer reference of the
  width table (ExHdl.Test.RTLGen), and the generated SystemVerilog in
  Verilator.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExHdl.RTL.{Cosim, Sim}
  alias ExHdl.Test.RTLGen

  defp expr_module(name, asts) do
    require ExHdl.RTL

    ExHdl.RTL.module name do
      handles = Map.new(RTLGen.inputs(), fn {n, t} -> {n, ExHdl.RTL.input(n, t)} end)

      for {ast, i} <- Enum.with_index(asts) do
        e = RTLGen.build(ast, handles)
        o = ExHdl.RTL.output(:"o#{i}", e.type)
        ExHdl.RTL.Builder.assign(o, e)
      end
    end
  end

  defp reference(asts, ins) do
    asts |> Enum.with_index() |> Map.new(fn {ast, i} -> {:"o#{i}", RTLGen.ref(ast, ins)} end)
  end

  property "types follow the width table" do
    check all(ast <- RTLGen.ast(), ins <- RTLGen.random_inputs(), max_runs: 500) do
      m = expr_module("types", [ast])
      {_, type} = RTLGen.ref(ast, ins)
      assert hd(ExHdl.RTL.Module.outputs(m)).type == type
    end
  end

  property "BEAM simulation equals the integer reference" do
    check all(
            asts <- list_of(RTLGen.ast(), min_length: 1, max_length: 6),
            vectors <- list_of(RTLGen.random_inputs(), min_length: 1, max_length: 6),
            max_runs: 300
          ) do
      m = expr_module("prop", asts)
      sim = Sim.new(m)

      for ins <- vectors do
        out = sim |> Sim.poke(ins) |> Sim.outputs()
        expected = Map.new(reference(asts, ins), fn {k, {v, _}} -> {k, v} end)
        assert out == expected, "inputs #{inspect(ins)}\nasts #{inspect(asts)}"
      end
    end
  end

  property "Expr.eval/3 equals the integer reference" do
    check all(ast <- RTLGen.ast(), ins <- RTLGen.random_inputs(), max_runs: 500) do
      handles = Map.new(RTLGen.inputs(), fn {n, t} -> {n, ExHdl.RTL.Expr.input_like(n, t)} end)
      e = RTLGen.build(ast, handles)
      {v, t} = RTLGen.ref(ast, ins)
      assert e.type == t
      assert ExHdl.RTL.Expr.eval(e, &Map.fetch!(ins, &1)) == v
    end
  end

  describe "Verilator" do
    @describetag :verilator
    @describetag timeout: 600_000

    test "120 fixed random expressions: BEAM, reference and Verilator agree on 300 vectors" do
      asts = RTLGen.ast() |> StreamData.resize(8) |> StreamData.seeded(1234) |> Enum.take(120)
      vectors = RTLGen.random_inputs() |> StreamData.seeded(99) |> Enum.take(300)
      m = expr_module("expr_fixed", asts)

      Cosim.assert_equivalent(m, vectors)

      {:ok, c} = Cosim.build(m)
      {:ok, rtl} = Cosim.run(c, vectors)

      for {ins, out} <- Enum.zip(vectors, rtl) do
        expected = Map.new(reference(asts, ins), fn {k, {v, _}} -> {k, v} end)
        assert out == expected
      end
    end

    property "fresh random expressions co-simulate" do
      check all(
              asts <- list_of(RTLGen.ast(), length: 25),
              vectors <- list_of(RTLGen.random_inputs(), length: 50),
              max_runs: 2
            ) do
        Cosim.assert_equivalent(expr_module("expr_prop", asts), vectors)
      end
    end
  end
end
