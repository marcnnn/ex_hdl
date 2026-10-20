defmodule ExHdl.DSPArithCosimTest do
  @moduledoc """
  Products wider than one DSP multiplier (split into pieces), multiplies
  sharing DSP slices under `ii: n`, and the priority encoder behind
  `ExHdl.DSP.msb/2` and `count_leading_zeros/2`, each bit for bit against
  the Nx reference.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias ExHdl.Sim.Verilator
  alias ExHdl.Test.Arith
  alias ExHdl.Test.Audio, as: A

  @moduletag :verilator
  @moduletag timeout: 600_000

  @traffic [{100, 100, 1}, {60, 70, 2}, {95, 25, 3}]

  defp run_ref(fun, samples, state, params, ranges) do
    {y, _} = NxFixed.run_scan_stacked(fun, samples, state, params, param_ranges: ranges)
    y |> List.wrap() |> Enum.flat_map(&leaves/1) |> Enum.map(&Nx.to_flat_list/1)
  end

  defp leaves(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&leaves/1)
  defp leaves(t), do: [t]

  defp extremes(bits, n, seed) do
    :rand.seed(:exsss, seed)
    lo = -(1 <<< (bits - 1))
    hi = (1 <<< (bits - 1)) - 1
    [lo, hi, 0, -1, 1, lo + 1] ++ for(_ <- 1..n, do: lo + :rand.uniform(hi - lo + 1) - 1)
  end

  for {family, mhz} <- [{:zynq7, 150}, {:ultrascale_plus, 250}] do
    @family family
    @mhz mhz
    test "32 x 32 products and 32 x 24 dot products in DSP pieces (#{family})" do
      t = ExHdl.Target.Timing.new(family: @family)

      {:ok, d} =
        ExHdl.DSP.scan_to_sv(&Arith.wide_mul/2, Arith.wide_args(),
          state: 1,
          param_ranges: Arith.wide_ranges(),
          family: @family,
          clock_mhz: @mhz,
          name: "wide_mul_#{@family}"
        )

      assert d.dsp ==
               ExHdl.Target.Timing.dsp_count(t, 32, 32) +
                 2 * ExHdl.Target.Timing.dsp_count(t, 32, 24)

      assert d.source =~ "_pp3"
      {:ok, sim} = Verilator.build_stream(d)
      n = 200
      a = extremes(32, n, 1)
      b = Enum.reverse(extremes(32, n, 2))
      u = Enum.zip(extremes(32, n, 3), extremes(32, n, 4)) |> Enum.map(&Tuple.to_list/1)
      v = Enum.zip(extremes(24, n, 5), extremes(24, n, 6)) |> Enum.map(&Tuple.to_list/1)

      samples =
        {Nx.tensor(a, type: :s32), Nx.tensor(b, type: :s32), Nx.tensor(u, type: :s32),
         Nx.tensor(v, type: :s32)}

      expected =
        run_ref(&Arith.wide_mul/2, samples, Nx.tensor(0, type: :u8), [], Arith.wide_ranges())

      for {vp, rp, seed} <- @traffic do
        assert {:ok, res} =
                 Verilator.run_stream(sim, [a, b, u, v], [],
                   valid_pct: vp,
                   ready_pct: rp,
                   seed: seed
                 )

        assert res.outputs == expected
      end
    end
  end

  test "four multiplies share one DSP under ii: 4" do
    {:ok, d} =
      ExHdl.DSP.scan_to_sv(&Arith.taps4/3, Arith.taps4_args(),
        state: 1,
        ii: 4,
        name: "taps4_shared",
        param_names: ["c"]
      )

    {:ok, plain} =
      ExHdl.DSP.scan_to_sv(&Arith.taps4/3, Arith.taps4_args(), state: 1, ii: 4, share: false)

    assert {d.dsp, d.shared, plain.dsp} == {1, 1, 4}
    {:ok, sim} = Verilator.build_stream(d)
    xs = extremes(16, 300, 7)
    c = [-32768, 32767, 12345, -23456]
    c2 = [77, -32768, 32767, 5]
    s = Nx.tensor(0, type: :s16)
    tensors = fn cs -> [cs |> Enum.map(&Nx.tensor(&1, type: :s16)) |> List.to_tuple()] end
    {a, b} = Enum.split(xs, 150)

    {ya, state} =
      NxFixed.run_scan_stacked(&Arith.taps4/3, Nx.tensor(a, type: :s16), {s, s, s}, tensors.(c))

    {yb, _} =
      NxFixed.run_scan_stacked(&Arith.taps4/3, Nx.tensor(b, type: :s16), state, tensors.(c2))

    expected = Nx.to_flat_list(ya) ++ Nx.to_flat_list(yb)

    for {vp, rp, seed} <- @traffic do
      assert {:ok, res} =
               Verilator.run_stream(sim, [xs], [c],
                 valid_pct: vp,
                 ready_pct: rp,
                 seed: seed,
                 switch: {150, [c2]}
               )

      assert res.outputs == [expected]
    end
  end

  test "biquad at ii: :auto: split products, the feed-forward multiplies on one unit" do
    opts = [state: 1, param_ranges: A.param_ranges(), param_names: ["coef"], init: A.zero_state()]
    {:ok, d} = ExHdl.DSP.scan_to_sv(&A.biquad/3, A.args(), opts ++ [ii: :auto, name: "bq_shared"])
    {:ok, plain} = ExHdl.DSP.scan_to_sv(&A.biquad/3, A.args(), opts ++ [ii: :auto, share: false])
    # 3 products 32 x 24 (2 slices each) and 2 of 32 x 32 (4 each)
    assert plain.dsp == 14
    assert d.dsp == 10 and d.shared == 1
    {:ok, sim} = Verilator.build_stream(d)
    coef = A.design(:peaking, 1000, q: 2.0, gain_db: 9)
    xs = A.signal(150, 1) ++ A.loud(40) ++ A.signal(60, 2)

    {y, _} =
      NxFixed.run_scan_stacked(
        &A.biquad/3,
        Nx.tensor(xs, type: :s32),
        A.zero_state(),
        [A.coef_tensors(coef)],
        param_ranges: A.param_ranges()
      )

    for {vp, rp, seed} <- @traffic do
      assert {:ok, res} =
               Verilator.run_stream(sim, [xs], [Tuple.to_list(coef)],
                 valid_pct: vp,
                 ready_pct: rp,
                 seed: seed
               )

      assert res.outputs == [Nx.to_flat_list(y)]
    end
  end

  test "msb and count_leading_zeros are a priority encoder" do
    {:ok, d} =
      ExHdl.DSP.scan_to_sv(&Arith.levels/2, Arith.levels_args(),
        state: 1,
        param_ranges: Arith.levels_ranges(),
        name: "levels"
      )

    assert d.source =~ "_pe_v"
    refute d.source =~ ">= "
    {:ok, sim} = Verilator.build_stream(d)
    :rand.seed(:exsss, 11)
    edges = for k <- 0..24, d <- [-1, 0, 1], v = (1 <<< k) + d, v < 1 <<< 24, do: v

    xs =
      [0, -1, -(1 <<< 23)] ++
        edges ++ for(_ <- 1..200, do: :rand.uniform(1 <<< 24) - 1 - (1 <<< 22))

    expected =
      run_ref(
        &Arith.levels/2,
        Nx.tensor(xs, type: :s32),
        Nx.tensor(0, type: :u8),
        [],
        Arith.levels_ranges()
      )

    for {vp, rp, seed} <- @traffic do
      assert {:ok, res} =
               Verilator.run_stream(sim, [xs], [], valid_pct: vp, ready_pct: rp, seed: seed)

      assert res.outputs == expected
    end
  end
end
