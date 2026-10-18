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
    @taps "test/dsp_cases/fir_ccf_31tap_round.json"
          |> File.read!()
          |> JSON.decode!()
          |> get_in(["params", "taps_q15"])

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
            do: ExHdl.Types.IntSet.bounds(n.range)

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

  test "next_state must keep the state's type" do
    assert {:error, %DSP.ScheduleError{message: msg}} =
             DSP.analyze_scan(&K.widening_state_step/2, [t(:s16), t(:s16)], state: 1)

    assert msg =~ "state is {:s, 16}{}, next_state is {:s, 32}{}"
  end

  test "overflow is still reported first" do
    assert {:error, %DSP.RangeError{message: msg}} =
             DSP.analyze_scan(&K.overflowing_scan_step/2, [t(:s16), t(:s16)], state: 1)

    assert msg =~ "add needs -65536..65534"
  end
end
