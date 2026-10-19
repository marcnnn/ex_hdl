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

  test "ddc with a 64-entry sine table (LUT ROM instead of block RAM)" do
    [path] = Enum.filter(C.case_paths(), &String.ends_with?(&1, "ddc_rotator.json"))
    k = C.kernel(C.read_case(path), NxFixed.Num.q(16, 15, rounding: :nearest, lut_bits: 6))
    {_scan, sim} = build(k, "ddc_lut6", [])
    assert sim.design.source =~ "function automatic"
    refute sim.design.source =~ "initial begin"
    expected = reference(k)

    for traffic <- @traffic do
      assert run(sim, k, k.samples, traffic).outputs == expected
    end
  end

  test "min, max, abs, select, logic, variable shifts, sum, transpose against NxFixed.run_scan" do
    t = &Nx.template({}, &1)
    fun = &ExHdl.Test.DSP.misc_ops_step/3

    {:ok, scan} =
      ExHdl.DSP.analyze_scan(fun, [{t.(:s16), t.(:s16)}, t.(:s16), t.(:u8)], state: 1)

    design = SV.generate(scan, name: "misc_ops", param_names: ["k"])
    {:ok, sim} = Verilator.build_stream(design)

    :rand.seed(:exsss, 7)
    edge = [-32768, -32767, -1, 0, 1, 32767]

    pairs =
      for(a <- edge, b <- edge, do: {a, b}) ++
        for _ <- 1..400, do: {:rand.uniform(65536) - 32769, :rand.uniform(65536) - 32769}

    {as, bs} = Enum.unzip(pairs)

    for k <- [0, 3, 13] do
      samples =
        Enum.map(pairs, fn {a, b} -> {Nx.tensor(a, type: :s16), Nx.tensor(b, type: :s16)} end)

      kt = Nx.tensor(k, type: :u8)
      {outs, _} = NxFixed.run_scan(fun, samples, Nx.tensor(0, type: :s16), [kt])

      expected =
        outs
        |> Enum.map(&C.leaf_ints/1)
        |> Enum.zip_with(&List.flatten/1)

      for traffic <- @traffic do
        {vp, rp, seed} = traffic

        assert {:ok, res} =
                 Verilator.run_stream(sim, [as, bs], [k],
                   valid_pct: vp,
                   ready_pct: rp,
                   seed: seed
                 )

        assert res.outputs == expected, "k = #{k}, traffic #{inspect(traffic)}"
      end
    end
  end

  describe "parameter loads (p_load) take effect between samples" do
    for {file, change} <- [{"ddc_rotator.json", :ddc}, {"one_pole_a0p25.json", :one_pole}] do
      @case_file file
      @change change
      test "#{file}", do: assert_switch(@case_file, @change)
    end
  end

  defp assert_switch(file, change) do
    [path] = Enum.filter(C.case_paths(), &String.ends_with?(&1, file))
    k = C.kernel(C.read_case(path), NxFixed.Num.q(16, 15, rounding: :nearest))
    {_scan, sim} = build(k, "switch_#{change}", ii: :auto)

    params2 =
      Enum.map(k.params, fn
        %NxFixed.Fixed{} = p -> %{p | t: Nx.subtract(Nx.tensor(-1000, type: p.t.type), p.t)}
        t -> Nx.add(t, 1234) |> Nx.as_type(t.type)
      end)

    total = [k.samples] |> Nx.Defn.Composite.flatten_list() |> hd() |> Nx.axis_size(0)
    at = div(total, 3)
    first = slice_samples(k.samples, 0, at)
    rest = slice_samples(k.samples, at, total - at)

    {out1, state} =
      NxFixed.run_scan_stacked(k.fun, first, k.state, k.params, kernel_opts: k.kernel_opts)

    {out2, _} =
      NxFixed.run_scan_stacked(k.fun, rest, state, params2, kernel_opts: k.kernel_opts)

    expected = Enum.zip_with(C.leaf_ints(out1), C.leaf_ints(out2), &(&1 ++ &2))
    refute expected == reference(k), "the parameter change must be visible"

    for {vp, rp, seed} <- @traffic do
      assert {:ok, res} =
               Verilator.run_stream(
                 sim,
                 C.leaf_ints(k.samples),
                 C.leaf_ints(List.to_tuple(k.params)),
                 valid_pct: vp,
                 ready_pct: rp,
                 seed: seed,
                 switch: {at, C.leaf_ints(List.to_tuple(params2))}
               )

      assert res.outputs == expected
    end
  end

  defp slice_samples(samples, start, len) do
    Nx.Defn.Composite.traverse(samples, &Nx.slice_along_axis(&1, start, len, axis: 0))
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
