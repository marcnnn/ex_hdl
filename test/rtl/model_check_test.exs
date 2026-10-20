defmodule ExHdl.RTL.ModelCheckTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  use ExHdl.RTL

  import Bitwise, only: [band: 2, bsl: 2]

  alias ExHdl.RTL.{Cosim, Examples}
  alias ExHdl.RTL.Cosim.Mismatch

  # Counter model: Moore output (the count before this edge).
  defp counter_model(width) do
    {0,
     fn
       _c, %{rst_n: 0} -> {0, %{count: nil}}
       c, %{en: en} -> {band(c + en, bsl(1, width) - 1), %{count: c}}
     end}
  end

  defp counter_stimulus(n, seed) do
    :rand.seed(:exsss, {seed, 2, 3})
    [%{rst_n: 0}, %{rst_n: 0}] ++ for(_ <- 3..n, do: %{rst_n: 1, en: :rand.uniform(2) - 1})
  end

  test "a correct model passes" do
    assert :ok =
             Cosim.check_model(Examples.counter(4), counter_stimulus(100, 1), counter_model(4))
  end

  test "a mismatch reports cycle, port, values and the input history" do
    {s, step} = counter_model(4)
    wrong = {s, fn c, ins -> if c == 5, do: {7, %{count: 5}}, else: step.(c, ins) end}
    stim = [%{rst_n: 0}, %{rst_n: 0}] ++ List.duplicate(%{rst_n: 1, en: 1}, 20)

    assert {:mismatch, %Mismatch{} = m} =
             Cosim.check_model(Examples.counter(4), stim, wrong, history: 3)

    assert m.backend == :beam
    assert m.cycle == 8
    assert m.diffs == [{:count, 7, 6}]
    assert [{6, %{en: 1, rst_n: 1}, [{:count, 4, 4}]}, {7, _, _}, {8, _, _}] = m.history

    msg = Mismatch.message(m)
    assert msg =~ "counter_4 (beam) differs from the model at cycle 8:\n"
    assert msg =~ "  count: expected 7, actual 6\n"
    assert msg =~ ">      8: en=1 rst_n=1 | count=6 (expected 7)\n"
    assert msg =~ "       7: en=1 rst_n=1 | count=5\n"

    e =
      assert_raise ExUnit.AssertionError, fn ->
        Cosim.assert_model(Examples.counter(4), stim, wrong)
      end

    assert e.message =~ "differs from the model at cycle 8"
  end

  test "latency shifts the comparison, nil is don't care" do
    m =
      module "delay2" do
        a = input(:a, 8)
        q = output(:q, 8)
        r1 = reg(:r1, 8)
        r2 = reg(:r2, 8)

        sync do
          r1 <~ a
          r2 <~ r1
        end

        q <~ r2
      end

    stim = for i <- 0..30, do: %{rst_n: if(i < 1, do: 0, else: 1), a: rem(i * 37, 256)}
    model = {nil, fn st, %{a: a} -> {st, %{q: a}} end}
    assert :ok = Cosim.check_model(m, stim, model, latency: 2)
    assert {:mismatch, %{cycle: 2}} = Cosim.check_model(m, stim, model, latency: 1)

    # don't care for the cycles where the pipeline is filling
    expected = [%{q: nil}, %{q: nil} | Enum.map(Enum.drop(stim, -2), &%{q: &1.a})]
    assert :ok = Cosim.check_trace(m, stim, expected)

    msg =
      m
      |> Cosim.check_model(stim, model, latency: 1)
      |> elem(1)
      |> Mismatch.message()

    assert msg =~ "(model step 1, latency 1)"
  end

  test "model inputs carry held values and signed outputs accept raw bits" do
    m =
      module "neg8" do
        a = input(:a, s(8))
        b = input(:b, 1)
        q = output(:q, s(9))
        q <~ mux(b, -a, a)
      end

    stim = [%{a: 5}, %{b: 1}, %{a: -128}, %{b: 0}]

    seen = fn _, ins -> {nil, %{q: if(ins.b == 1, do: band(-ins.a, 0x1FF), else: ins.a)}} end
    assert :ok = Cosim.check_model(m, stim, {nil, seen})

    assert_raise ArgumentError, ~r/no output :nope/, fn ->
      Cosim.check_trace(m, stim, [%{nope: 1}])
    end
  end

  @tag :verilator
  test "verilator and both backends" do
    stim = counter_stimulus(200, 4)
    assert :ok = Cosim.check_model(Examples.counter(8), stim, counter_model(8), backend: :both)
    {s, step} = counter_model(8)
    wrong = {s, fn c, ins -> step.(c, %{ins | en: 1}) end}

    assert {:mismatch, %{backend: :verilator}} =
             Cosim.check_model(Examples.counter(8), stim, wrong, backend: :verilator)
  end

  describe "wide ports" do
    # 66-bit block scrambler style datapath: XOR with a rotating key,
    # registered, plus a signed accumulator, at several widths.
    defp wide(w) do
      module "wide_#{w}" do
        a = input(:a, w)
        k = input(:k, w)
        sa = input(:sa, s(w))
        x = output(:x, w)
        acc = output(:acc, s(w), reset: 0)
        top = output(:top, 1)
        x <~ bxor(a, cat([k[0..(w - 2)], k[w - 1]]))
        top <~ a[w - 1]

        sync do
          acc <~ add_wrap(acc, sa)
        end
      end
    end

    defp wide_model(w) do
      mask = bsl(1, w) - 1
      wrap = fn v -> ExHdl.RTL.Expr.wrap(v, {:s, w}) end

      {0,
       fn
         _acc, %{rst_n: 0} ->
           {0, %{}}

         acc, %{a: a, k: k, sa: sa} ->
           rot = band(bsl(k, 1), mask) + Bitwise.bsr(k, w - 1)
           {wrap.(acc + sa), %{x: bxor(a, rot), acc: acc, top: Bitwise.bsr(a, w - 1)}}
       end}
    end

    defp wide_stimulus(w, n) do
      :rand.seed(:exsss, {w, 7, 7})
      r = fn -> :rand.uniform(bsl(1, w)) - 1 end

      for i <- 1..n do
        %{rst_n: if(i < 3, do: 0, else: 1), a: r.(), k: r.(), sa: r.() - bsl(1, w - 1)}
      end
    end

    for w <- [66, 72, 128, 512] do
      test "#{w} bits in the BEAM simulator" do
        w = unquote(w)
        assert :ok = Cosim.check_model(wide(w), wide_stimulus(w, 60), wide_model(w))
      end

      @tag :verilator
      test "#{w} bits in Verilator" do
        w = unquote(w)
        stim = wide_stimulus(w, 60)
        assert :ok = Cosim.check_model(wide(w), stim, wide_model(w), backend: :verilator)
        Cosim.assert_equivalent(wide(w), stim)
      end
    end

    @tag :verilator
    @tag timeout: 300_000
    test "word boundary widths co-simulate" do
      for w <- [64, 65, 97] do
        Cosim.assert_equivalent(wide(w), wide_stimulus(w, 30))
      end
    end
  end
end
