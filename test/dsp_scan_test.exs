defmodule ExHdl.DSPScanTest do
  use ExUnit.Case, async: true

  alias ExHdl.DSP
  alias ExHdl.Test.DSP, as: K

  defp t(type), do: Nx.template({}, type)
  defp ops(scan, ids), do: Enum.map(ids, &scan.graph.nodes[&1].op)

  defp ddc(opts \\ []),
    do:
      DSP.analyze_scan(
        &K.ddc_step/5,
        [{t(:s16), t(:s16)}, t(:u16), t(:u16), t(:s16), []],
        [state: 1] ++ opts
      )

  defp one_pole(opts \\ []),
    do: DSP.analyze_scan(&K.one_pole_step/3, [t(:s16), t(:s16), t(:s16)], [state: 1] ++ opts)

  describe "ddc_step" do
    test "only the phase accumulator is in the loop, so it runs at one sample per cycle" do
      assert {:ok, scan} = ddc()
      assert %{loop_latency: 1, ii: 1, channels: 1, throughput: 1.0} = scan
      assert ops(scan, scan.critical_path) == [:parameter, :as_type, :add, :bitwise_and, :as_type]

      recurrence_ops = ops(scan, MapSet.to_list(scan.recurrence))
      refute :multiply in recurrence_ops
      refute :take in recurrence_ops
    end

    test "the rest is pipelined: table, mixer and gain add latency, not loop time" do
      assert {:ok, scan} = ddc()
      # BRAM (2) + mixer DSP (3) + gain DSP (3) + adder/clip stages
      assert scan.pipeline_latency >= 8
    end
  end

  describe "one-pole IIR (multiply inside the loop)" do
    test "is rejected at full rate with the critical path and the options" do
      assert {:error, %DSP.ScheduleError{message: msg}} = one_pole()
      assert msg =~ "feedback loop (state -> next state) needs 4 cycles"
      assert msg =~ "multiply       dsp48, 3 cycles"
      assert msg =~ ~r/critical loop path:\n\s+parameter/
      assert msg =~ "ii: 4"
      assert msg =~ "channels: 4"
    end

    test "runs with ii: or channels: of at least the loop latency" do
      assert {:ok, %{ii: 4, channels: 1, throughput: 0.25}} = one_pole(ii: 4)
      assert {:ok, %{ii: 6, throughput: tp}} = one_pole(ii: 6)
      assert_in_delta tp, 1 / 6, 1.0e-9
      assert {:ok, %{ii: 4, channels: 4, throughput: 1.0}} = one_pole(channels: 4)
    end

    test "too small ii: or channels: is rejected" do
      assert {:error, %{message: msg}} = one_pole(ii: 3)
      assert msg =~ "needs 4 cycles, more than ii: 3"
      assert {:error, %{message: msg}} = one_pole(channels: 2)
      assert msg =~ "more than channels: 2"
      assert {:error, %{message: msg}} = one_pole(ii: 4, channels: 4)
      assert msg =~ "not both"
    end

    test "the timing model can be overridden" do
      # A DSP with a single register stage shortens the loop to 2 cycles.
      assert {:error, %{message: msg}} = one_pole(dsp_latency: 1)
      assert msg =~ "needs 2 cycles"
    end
  end

  describe "FIR with constant taps" do
    # the taps of ex_sdr's GNU Radio comparison case
    @taps Mix.Project.deps_paths()[:ex_sdr]
          |> Path.join("test/dsp_cases/fir_ccf_31tap.json")
          |> File.read!()
          |> JSON.decode!()
          |> get_in(["params", "taps"])
          |> Enum.map(&round(&1 * 32768))

    defp fir(opts \\ []) do
      args = [
        {t(:s16), t(:s16)},
        {Nx.template({30}, :s16), Nx.template({30}, :s16)},
        [taps: @taps]
      ]

      DSP.analyze_scan(&K.fir_ccf_step/3, args, [state: 1] ++ opts)
    end

    test "the accumulator bound is exactly 32768 * sum(|taps|)" do
      assert {:ok, scan} = fir()
      sum_abs = @taps |> Enum.map(&abs/1) |> Enum.sum()
      bound = 32768 * sum_abs

      dots =
        for n <- Map.values(scan.graph.nodes),
            n.op == :dot,
            do: NxFixed.IntSet.bounds(n.range)

      assert [{lo, hi}, {lo, hi}] = dots
      # extremes: -32768 on positive taps and 32767 on negative ones, and vice versa
      assert -lo <= bound and hi <= bound and -lo > bound - sum_abs and hi > bound - 2 * sum_abs
    end

    test "only the delay line is in the loop, so it runs at one sample per cycle" do
      assert {:ok, scan} = fir()
      assert %{loop_latency: 1, ii: 1, throughput: 1.0} = scan
      assert ops(scan, scan.critical_path) == [:parameter, :concatenate, :slice]
    end
  end

  describe "state groups (one loop per strongly connected part of the state)" do
    alias ExHdl.Test.Audio, as: A

    defp biquad(opts),
      do:
        DSP.analyze_scan(
          &A.biquad/3,
          A.args(),
          [state: 1, param_ranges: A.param_ranges()] ++ opts
        )

    test "a biquad's input history is not part of its feedback loop" do
      assert {:ok, scan} = biquad(ii: :auto)
      assert [%{leaves: [0]}, %{leaves: [1]}, %{leaves: [2, 3, 4], loop_latency: l}] = scan.groups
      assert scan.loop_latency == l
      # the feed-forward products of x1, x2 are computed ahead of the loop
      assert hd(scan.critical_path) in hd(tl(tl(scan.groups))).params
    end

    test "a cascade of four biquads has the loop of one" do
      {:ok, one} = biquad(ii: :auto)
      spec = DSP.cascade(for k <- 1..4, do: A.stage("eq#{k}"))
      opts = Keyword.drop(spec, [:fun, :args])
      assert {:ok, scan} = DSP.analyze_scan(spec[:fun], spec[:args], opts ++ [ii: :auto])
      assert scan.loop_latency == one.loop_latency
      assert length(scan.groups) == 12
      assert spec[:param_names] == ~w(eq1_coef eq2_coef eq3_coef eq4_coef)
    end

    test "state in RAM needs channels of at least the loop plus the read latency" do
      {:ok, %{loop_latency: l}} = biquad(ii: :auto)
      assert {:ok, %{channels: ^l, state_mem: :registers}} = biquad(channels: l)
      assert {:error, %{message: msg}} = biquad(channels: l, state_mem: :block)
      assert msg =~ "state memory read 1 more, so more than channels: #{l}"
      assert msg =~ "channels: #{l + 1}"
      assert {:ok, %{ram_latency: 1}} = biquad(channels: l + 1, state_mem: :block)
      assert {:error, _} = biquad(channels: l + 1, state_mem: :ultra)
      assert {:ok, %{ram_latency: 2}} = biquad(channels: l + 2, state_mem: :ultra)
      assert {:error, %{message: msg}} = biquad(ii: :auto, state_mem: :block)
      assert msg =~ "needs channels: n"
      assert {:error, %{message: msg}} = biquad(channels: 20, state_mem: :flash)
      assert msg =~ "state_mem: must be one of"
    end

    test "a folded state memory takes one sample every state_fold cycles" do
      {:ok, %{loop_latency: l}} = biquad(ii: :auto)
      # n * k >= l + ram_latency + k - 1
      n = div(l + 1 + 3 + 3, 4)

      assert {:ok, %{channels: ^n, state_fold: 4, ii: ii, throughput: 0.25}} =
               biquad(channels: n, state_mem: :block, state_fold: 4)

      assert ii == 4 * n
      assert {:error, %{message: msg}} = biquad(channels: n - 1, state_mem: :block, state_fold: 4)
      assert msg =~ "folded state memory 4 more"
      assert {:ok, %{state_fold: 1}} = biquad(channels: l + 1, state_mem: :block, state_fold: 1)
      assert {:error, %{message: msg}} = biquad(channels: l, state_fold: 2)
      assert msg =~ "state_fold: needs the state in a memory"
      assert {:error, %{message: msg}} = biquad(channels: 20, state_mem: :block, state_fold: 0)
      assert msg =~ "state_fold: must be a positive integer"
    end

    test "folded state memories merge while a row fits state_row_bits and the span fits" do
      spec = DSP.cascade(for k <- 1..4, do: A.stage("eq#{k}"))

      mems = fn extra ->
        {:ok, d} =
          DSP.scan_to_sv(
            spec[:fun],
            spec[:args],
            Keyword.drop(spec, [:fun, :args]) ++
              [state_mem: :ultra, channel_params: :all, state_fold: 4] ++ extra
          )

        d.state_memories
      end

      # one memory per stage that reads state: two per biquad
      separate = mems.(channels: 64, state_row_bits: 0)
      assert length(separate) == 8
      assert Enum.all?(separate, &(&1.depth == 256 and &1.width == div(&1.bits + 3, 4)))
      total = separate |> Enum.map(& &1.bits) |> Enum.sum()
      biquad = div(total, 4)

      # two biquads per 72-bit row
      assert [%{bits: b, width: w}, %{bits: b, width: w}] = mems.(channels: 64)
      assert b == 2 * biquad and w == div(b + 3, 4) and w <= 72

      # with 6 channels a sample of the same channel follows after 24
      # cycles: the span of two biquads does not fit, about one does
      short = mems.(channels: 6)
      assert length(short) == 4
      assert short |> Enum.map(& &1.bits) |> Enum.sum() == total
      assert Enum.all?(short, &(&1.bits < 2 * biquad))
    end

    test "per-channel parameters, tid and unknown names are checked" do
      {:ok, scan} = biquad(ii: :auto)
      sv = ExHdl.Backends.SystemVerilog.Scan

      assert_raise ArgumentError, ~r/channel_params: needs channels/, fn ->
        sv.generate(scan, param_names: ["coef"], channel_params: ["coef"])
      end

      assert_raise ArgumentError, ~r/tid: true needs channels/, fn ->
        sv.generate(scan, tid: true)
      end

      {:ok, scan} = biquad(channels: 12)

      assert_raise ArgumentError, ~r/no parameter argument named "gain"/, fn ->
        sv.generate(scan, param_names: ["coef"], channel_params: ["gain"])
      end
    end
  end

  test "next_state must keep the state's type" do
    assert {:error, %DSP.ScheduleError{message: msg}} =
             DSP.analyze_scan(&K.widening_state_step/2, [t(:s16), t(:s16)], state: 1)

    assert msg =~ "state is {:s, 16}{}, next_state is {:s, 32}{}"
  end

  test "overflow is still reported first" do
    assert {:error, %NxFixed.RangeError{message: msg}} =
             DSP.analyze_scan(&K.overflowing_scan_step/2, [t(:s16), t(:s16)], state: 1)

    assert msg =~ "add needs -65536..65534"
  end

  test "ex_sdr's format-generic ddc block as Q15 runs at one sample per cycle" do
    f = NxFixed.Num.q(16, 15)
    s = %NxFixed.Fixed{t: Nx.template({}, :s16), frac: 15}
    args = [{s, s}, Nx.template({}, :u16), Nx.template({}, :u16), s, [format: f]]

    assert {:ok, %{loop_latency: 1, ii: 1}} =
             DSP.analyze_scan(&ExSdr.DSP.Blocks.ddc/5, args, state: 1)
  end
end
