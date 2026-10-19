defmodule ExHdl.ScanCosimTest do
  @moduledoc """
  ex_sdr's DSP blocks (ddc, fir_complex, one_pole) in every fixed-point
  format of the shared DSP cases: the generated RTL (Verilator) against
  the Nx reference (`NxFixed.run_scan_stacked/5`) on the GNU Radio
  comparison input, bit for bit, with and without backpressure.
  """
  use ExUnit.Case, async: true

  alias ExHdl.Backends.SystemVerilog.Scan, as: SV
  alias ExHdl.Sim.Verilator
  alias ExHdl.Test.SdrCases, as: C

  @moduletag :verilator
  @moduletag timeout: 600_000

  # {valid_pct, ready_pct, seed}
  @traffic [{100, 100, 1}, {70, 50, 2}, {30, 95, 3}, {95, 20, 4}]

  defp build(k, name, opts) do
    {:ok, scan} = ExHdl.DSP.analyze_scan(k.fun, k.args, [state: 1] ++ opts)
    design = SV.generate(scan, name: name, init: k.state)
    {:ok, sim} = Verilator.build_stream(design)
    {scan, sim}
  end

  defp reference(k, samples \\ nil) do
    {out, _} =
      NxFixed.run_scan_stacked(k.fun, samples || k.samples, k.state, k.params,
        kernel_opts: k.kernel_opts
      )

    C.leaf_ints(out)
  end

  defp run(sim, k, samples, traffic) do
    {vp, rp, seed} = traffic

    assert {:ok, res} =
             Verilator.run_stream(sim, C.leaf_ints(samples), C.leaf_ints(List.to_tuple(k.params)),
               valid_pct: vp,
               ready_pct: rp,
               seed: seed
             )

    res
  end

  for path <- C.case_paths(),
      case = C.read_case(path),
      variant <- case["fixed_vs_float"] do
    @case case
    @variant variant
    @module "#{case["block"]["name"]}_#{variant["variant"]}"

    test "#{case["name"]} #{variant["variant"]}: RTL output is bit-identical to the Nx reference" do
      k = C.kernel(@case, C.format(@variant["format"]))
      {scan, sim} = build(k, @module, ii: :auto)
      expected = reference(k)
      n = length(hd(expected))

      for traffic <- @traffic do
        res = run(sim, k, k.samples, traffic)

        assert res.outputs == expected,
               "#{@module}: mismatch with traffic #{inspect(traffic)} at sample " <>
                 "#{first_mismatch(res.outputs, expected)}"

        # Without backpressure: one sample every ii cycles, plus pipeline
        # fill and the harness's 64 idle drain cycles.
        if traffic == {100, 100, 1},
          do: assert(res.cycles <= n * scan.ii + sim.design.latency + 64 + 2)
      end
    end
  end

  describe "one_pole: the multiply is inside the loop" do
    setup do
      [path] = Enum.filter(C.case_paths(), &String.ends_with?(&1, "one_pole_a0p25.json"))
      case = C.read_case(path)
      format = NxFixed.Num.q(16, 15, rounding: :nearest)
      %{case: case, format: format}
    end

    test "channels: n interleaves n independent filters at one sample per cycle", ctx do
      k = C.kernel(ctx.case, ctx.format)
      {:ok, %{loop_latency: l}} = ExHdl.DSP.analyze_scan(k.fun, k.args, state: 1, ii: :auto)
      assert l > 1

      for n <- [l, l + 2] do
        {_scan, sim} = build(k, "one_pole_ch#{n}", channels: n)
        assert_channels(k, sim, n)
      end
    end

    test "a deliberately long loop (slow DSP, fast clock) with ii: and channels:", ctx do
      k = C.kernel(ctx.case, ctx.format)
      timing = [dsp_latency: 5, clock_mhz: 300]

      {:ok, %{loop_latency: l}} =
        ExHdl.DSP.analyze_scan(k.fun, k.args, [state: 1, ii: :auto] ++ timing)

      assert l >= 8

      {_scan, sim} = build(k, "one_pole_long_ii", [ii: l + 1] ++ timing)
      expected = reference(k)

      for traffic <- @traffic do
        assert run(sim, k, k.samples, traffic).outputs == expected
      end

      {_scan, sim} = build(k, "one_pole_long_ch", [channels: l] ++ timing)
      assert_channels(k, sim, l)
    end
  end

  # Samples are dealt round robin to n channels; each channel must match the
  # reference run on its own subsequence.
  defp assert_channels(k, sim, n) do
    total = Nx.axis_size(k.samples.t, 0)

    expected =
      for c <- 0..(n - 1) do
        idx = Nx.tensor(Enum.to_list(c..(total - 1)//n))
        [ys] = reference(k, %{k.samples | t: Nx.take(k.samples.t, idx)})
        ys
      end

    interleaved =
      for i <- 0..(total - 1), do: expected |> Enum.at(rem(i, n)) |> Enum.at(div(i, n))

    for traffic <- @traffic do
      res = run(sim, k, k.samples, traffic)
      assert res.outputs == [interleaved], "channels: #{n}, traffic #{inspect(traffic)}"

      if traffic == {100, 100, 1},
        do: assert(res.cycles <= total + sim.design.latency + 64 + 2)
    end
  end

  defp first_mismatch(got, expected) do
    got
    |> Enum.zip(expected)
    |> Enum.map(fn {g, e} ->
      Enum.zip(g, e) |> Enum.find_index(fn {a, b} -> a != b end) || min(length(g), length(e))
    end)
    |> Enum.min()
  end
end
