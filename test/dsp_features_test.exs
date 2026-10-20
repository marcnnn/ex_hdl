defmodule ExHdl.DSPFeaturesTest do
  @moduledoc false
  # Idioms, DSP splitting and sharing, memories and the frame sideband,
  # without simulation.
  use ExUnit.Case, async: true

  import Bitwise

  alias ExHdl.DSP
  alias ExHdl.Target.Timing
  alias ExHdl.Test.Arith
  alias ExHdl.Test.Audio, as: A
  alias ExHdl.Test.Mixer, as: M

  doctest ExHdl.DSP, only: [frame_flags: 1]
  doctest ExHdl.Target.Timing

  defp ops(scan), do: Enum.map(scan.graph.order, &scan.graph.nodes[&1].op)

  describe "idioms" do
    test "a signed wrap is wiring, so a wrapping accumulator has a loop of one adder" do
      acc = fn x, s -> {s, DSP.wrap(Nx.add(s, Nx.as_type(x, :s64)), 48)} end

      clamp = fn x, s ->
        lim = fn v -> Nx.tensor(v, type: :s64) end
        {s, Nx.clip(Nx.add(s, Nx.as_type(x, :s64)), lim.(-(1 <<< 47)), lim.((1 <<< 47) - 1))}
      end

      args = [Nx.template({}, :s32), Nx.template({}, :s64)]
      ranges = %{1 => -(1 <<< 47)..((1 <<< 47) - 1)}
      opts = [state: 1, param_ranges: ranges, family: :ultrascale_plus, clock_mhz: 500]

      assert {:ok, scan} = DSP.analyze_scan(acc, args, opts)
      assert :wrap in ops(scan)
      refute :bitwise_and in ops(scan)
      assert scan.loop_latency == 1

      assert {:ok, %{loop_latency: 2}} = DSP.analyze_scan(clamp, args, opts ++ [ii: :auto])
    end

    test "NxFixed.Primitives.wrap/2 and the biquad's error feedback are recognised" do
      f = fn x, s ->
        {x, NxFixed.Primitives.wrap(Nx.add(Nx.as_type(s, :s64), Nx.as_type(x, :s64)), :s32)}
      end

      t = Nx.template({}, :s32)
      assert {:ok, scan} = DSP.analyze_scan(f, [t, t], state: 1)
      assert :wrap in ops(scan) and scan.loop_latency == 1

      opts = [state: 1, param_ranges: A.param_ranges(), init: A.zero_state(), ii: :auto]
      assert {:ok, bq} = DSP.analyze_scan(&A.biquad/3, A.args(), opts)
      assert :wrap in ops(bq)
    end

    test "msb and count_leading_zeros: one :msb node, no comparators" do
      assert {:ok, scan} =
               DSP.analyze_scan(&Arith.levels/2, Arith.levels_args(),
                 state: 1,
                 param_ranges: Arith.levels_ranges()
               )

      assert Enum.count(ops(scan), &(&1 == :msb)) == 2
      refute :greater_equal in ops(scan)
      refute :sum in ops(scan)

      [m | _] =
        for id <- scan.graph.order, scan.graph.nodes[id].op == :msb, do: scan.graph.nodes[id]

      assert m.attrs == {1, 23}
    end

    test "the helpers agree with the definitions on the BEAM" do
      xs = [0, 1, 2, 3, 4, 255, 256, (1 <<< 24) - 1, 1 <<< 24, 1 <<< 30]
      run = fn f -> Enum.map(xs, &Nx.to_number(Nx.Defn.jit(f).(Nx.tensor(&1, type: :s32)))) end

      assert run.(&DSP.msb(&1, 24)) == Enum.map(xs, &min(max(log2(&1), 0), 23))

      assert run.(&DSP.count_leading_zeros(&1, 24)) ==
               Enum.map(xs, &if(&1 >= 1 <<< 24, do: 0, else: 24 - bits(&1)))

      w = Nx.Defn.jit(&DSP.wrap(&1, 48)).(Nx.tensor([1 <<< 47, -(1 <<< 47) - 1, 5], type: :s64))
      assert Nx.to_flat_list(w) == [-(1 <<< 47), (1 <<< 47) - 1, 5]
    end
  end

  defp log2(0), do: 0
  defp log2(v), do: bits(v) - 1
  defp bits(0), do: 0
  defp bits(v), do: 1 + bits(v >>> 1)

  describe "DSP pieces per family" do
    test "products and slices on DSP48E1 and DSP48E2" do
      z7 = Timing.new()
      us = Timing.new(family: :ultrascale_plus)

      for {t, a, b, n} <- [
            {z7, 25, 18, 1},
            {z7, 32, 24, 2},
            {z7, 32, 32, 4},
            {z7, 48, 48, 6},
            {us, 27, 18, 1},
            {us, 32, 24, 2},
            {us, 32, 32, 4},
            {us, 18, 44, 2},
            {us, 48, 48, 6}
          ] do
        assert Timing.dsp_count(t, a, b) == n, "#{t.family} #{a} x #{b}"
      end

      assert Timing.mul_cost(us, 32, 32) == {:reg, 5, :dsp48_split}
      assert Timing.mul_cost(us, 32, 24) == {:reg, 4, :dsp48_split}

      assert %{swap: true, a: [{0, 17, false}, {17, 15, true}], b: [{0, 24, true}]} =
               Timing.dsp_split(us, 32, 24)
    end

    test "the generated design counts the slices of its products" do
      opts = [state: 1, param_ranges: Arith.wide_ranges()]
      {:ok, z7} = DSP.scan_to_sv(&Arith.wide_mul/2, Arith.wide_args(), opts)

      {:ok, us} =
        DSP.scan_to_sv(&Arith.wide_mul/2, Arith.wide_args(), opts ++ [family: :ultrascale_plus])

      assert {z7.dsp, us.dsp} == {4 + 2 * 2, 4 + 2 * 2}
    end
  end

  describe "DSP sharing under ii: n" do
    test "multiplies outside the loop are delayed into one unit; a window of ii stages" do
      opts = [state: 1, param_names: ["c"]]
      args = Arith.taps4_args()
      assert {:ok, %{dsp: 1, shared: 1}} = DSP.scan_to_sv(&Arith.taps4/3, args, opts ++ [ii: 4])
      assert {:ok, %{dsp: 2, shared: 2}} = DSP.scan_to_sv(&Arith.taps4/3, args, opts ++ [ii: 2])

      assert {:ok, %{dsp: 4, shared: 0}} =
               DSP.scan_to_sv(&Arith.taps4/3, args, opts ++ [ii: 4, share: false])

      assert {:ok, %{dsp: 4, shared: 0}} =
               DSP.scan_to_sv(&Arith.taps4/3, args, opts ++ [channels: 4])
    end
  end

  describe "memories" do
    defp mixer(extra), do: DSP.analyze_scan(&M.xmix/5, M.args(8, 2, 4), M.opts(8, 4, extra))

    test "specs: style, latency and banks per family, a read port per index element" do
      assert {:ok, scan} =
               mixer(
                 family: :ultrascale_plus,
                 memories: ["src", {"frame", banks: 1, style: :ultra}]
               )

      assert [
               %{name: "src", row: 2, depth: 8, banks: 2, style: :distributed, latency: 1},
               %{name: "frame", banks: 1, style: :ultra, latency: 2}
             ] = scan.memories

      assert scan.costs |> Map.values() |> Enum.sort() == [{:reg, 1, :ram}, {:reg, 2, :ram}]
    end

    test "errors: unknown names, other uses, indices outside the memory" do
      assert {:error, %{message: msg}} = mixer(memories: ["nope"])
      assert msg =~ ~s(no parameter named "nope")

      f = fn x, s, t -> {Nx.add(Nx.take(t, x), Nx.sum(t)), s} end
      t = Nx.template({}, :s32)
      args = [t, t, Nx.template({8}, :s32)]
      ranges = %{0 => 0..7, 2 => 0..100}

      assert {:error, %{message: msg}} =
               DSP.analyze_scan(f, args,
                 state: 1,
                 param_names: ["t"],
                 memories: ["t"],
                 param_ranges: ranges
               )

      assert msg =~ "can only be read with Nx.take(t, index)"

      # the width check already proves the index inside the memory
      g = fn x, s, t -> {Nx.take(t, x), s} end

      assert {:error, %NxFixed.RangeError{message: msg}} =
               DSP.analyze_scan(g, args,
                 state: 1,
                 param_names: ["t"],
                 memories: ["t"],
                 param_ranges: %{0 => 0..8, 2 => 0..100}
               )

      assert msg =~ "take index can be 0..8, table has 8 entries"
    end

    test "ports: write port per memory, swap and pending with two banks, a separate clock" do
      {:ok, d} =
        DSP.scan_to_sv(
          &M.xmix/5,
          M.args(8, 2, 4),
          M.opts(8, 4, memories: ["src", "gain", {"frame", clock: :separate}])
        )

      for p <-
            ~w(src_waddr src_wdata src_we src_swap src_pending frame_wclk s_axis_tlast m_axis_tlast),
          do: assert(d.source =~ p, p)

      assert Enum.find(d.memories, &(&1.name == "gain")).data_bits == 2 * 18
    end
  end

  describe "frame sideband" do
    test "frame: true needs {data, {first, last}}" do
      f = fn x, s -> {x, s} end
      t = Nx.template({}, :s32)
      assert {:error, %{message: msg}} = DSP.analyze_scan(f, [t, t], state: 1, frame: true)
      assert msg =~ "frame: true needs the sample"
    end
  end
end
