defmodule ExHdl.ChannelCosimTest do
  @moduledoc """
  Time-multiplexed kernels for many channels: state in RAM, per-channel
  parameters from a double-buffered coefficient memory, channel index and
  sideband through the pipeline, and cascades whose stages keep separate
  loops. The kernel is ex_audio's biquad (`ExHdl.Test.Audio`); every run is
  compared bit for bit with the Nx reference per channel.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias ExHdl.Sim.Verilator
  alias ExHdl.Test.Audio, as: A
  alias ExHdl.Test.DSP, as: K

  @moduletag :verilator
  @moduletag timeout: 900_000

  # {valid_pct, ready_pct, seed}
  @traffic [{100, 100, 1}, {70, 50, 2}, {30, 95, 3}, {95, 20, 4}]

  defp biquad_opts(extra),
    do:
      [state: 1, param_ranges: A.param_ranges(), param_names: ["coef"], init: A.zero_state()] ++
        extra

  defp loop_latency do
    {:ok, scan} = ExHdl.DSP.analyze_scan(&A.biquad/3, A.args(), biquad_opts(ii: :auto))
    scan.loop_latency
  end

  defp biquad_sim(name, extra) do
    {:ok, d} = ExHdl.DSP.scan_to_sv(&A.biquad/3, A.args(), biquad_opts([name: name] ++ extra))
    {:ok, sim} = Verilator.build_stream(d)
    sim
  end

  # Runs one channel's samples through the reference, switching coefficients
  # at sample `at` (nil: never).
  defp reference(fun, samples, coefs, at, opts \\ []) do
    ranges = Keyword.get(opts, :param_ranges, A.param_ranges())
    init = Keyword.get(opts, :init, A.zero_state())
    [first | _] = coefs
    at = at || length(samples)
    {a, b} = Enum.split(samples, at)
    run = fn xs, state, params -> run(fun, xs, state, params, ranges) end
    {ya, state} = run.(a, init, first)
    {yb, _} = run.(b, state, List.last(coefs))
    ya ++ yb
  end

  defp run(_fun, [], state, _params, _ranges), do: {[], state}

  defp run(fun, xs, state, params, ranges) do
    {y, state} =
      NxFixed.run_scan_stacked(fun, Nx.tensor(xs, type: :s32), state, params,
        param_ranges: ranges
      )

    {Nx.to_flat_list(y), state}
  end

  defp interleave(per_channel, order) do
    # order: the channel of every sample in stream order
    {out, _} =
      Enum.map_reduce(order, %{}, fn c, seen ->
        k = Map.get(seen, c, 0)
        {per_channel |> Map.fetch!(c) |> Enum.at(k), Map.put(seen, c, k + 1)}
      end)

    out
  end

  defp coefs(c), do: A.design(:peaking, 300 + 400 * c, q: 1.5, gain_db: 9 - 2 * rem(c, 7))
  defp coefs_b(c), do: A.design(:lowpass, 2000 + 500 * c, q: 0.9)
  defp garbage(_c), do: {123_456_789, -98_765_432, 55_555_555, -1_000_000_000, 999_999_999}

  describe "biquad, channels: n with state and coefficients in block RAM" do
    test "n = loop latency + RAM read: every channel its own coefficients, a bank swap mid-stream" do
      n = loop_latency() + 1
      frames = 40
      sim = biquad_sim("bq_ram_#{n}", channels: n, state_mem: :block, channel_params: ["coef"])
      d = sim.design
      assert d.busy and d.state_mem == :block and d.pc_width == 160
      refute d.source =~ "for (int i"

      order = for _f <- 0..(frames - 1), c <- 0..(n - 1), do: c

      # every third channel ends with a full-scale square wave (saturation)
      samples =
        Map.new(0..(n - 1), fn c ->
          {c,
           if(rem(c, 3) == 0,
             do: A.signal(frames - 12, c) ++ A.loud(12),
             else: A.signal(frames, c)
           )}
        end)

      stream = interleave(samples, order)

      # the swap is requested with sample k - 1; frames from the next one use bank B
      k = 13 * n + 4
      flip_frame = div(k + n - 1, n)

      expected =
        Map.new(0..(n - 1), fn c ->
          {c,
           reference(
             &A.biquad/3,
             samples[c],
             [coef_list(coefs(c)), coef_list(coefs_b(c))],
             flip_frame
           )}
        end)
        |> interleave(order)

      pc =
        Enum.map(0..(n - 1), &{:write, &1, pc_values(coefs(&1))}) ++
          [:swap] ++
          Enum.map(0..(n - 1), &{:write, &1, pc_values(coefs_b(&1))}) ++
          [{:swap_at, k}] ++
          Enum.map((n - 1)..0//-1, &{:write_after_swap, &1, pc_values(garbage(&1))})

      # the last channels of the old frame are still in flight when the
      # banks swap: overwriting their old coefficients first shows that
      # pc_pending covers them
      no_swap =
        Map.new(0..(n - 1), fn c ->
          {c, reference(&A.biquad/3, samples[c], [coef_list(coefs(c))], nil)}
        end)
        |> interleave(order)

      refute no_swap == expected

      for {vp, rp, seed} <- @traffic do
        assert {:ok, res} =
                 Verilator.run_stream(sim, [stream], [],
                   valid_pct: vp,
                   ready_pct: rp,
                   seed: seed,
                   pc: pc
                 )

        assert res.outputs == [expected], "traffic #{inspect({vp, rp, seed})}"
        assert res.tid == order
      end
    end

    test "s_axis_tid with a channel missing, tuser through the pipeline, swap at a frame start" do
      l = loop_latency()
      n = l + 3
      present = Enum.to_list(0..(n - 1)) -- [5]
      frames = 30

      sim =
        biquad_sim("bq_tid",
          channels: n,
          state_mem: :block,
          channel_params: :all,
          tid: true,
          tuser: 20
        )

      assert sim.design.tid and sim.design.tuser == 20
      order = for _f <- 0..(frames - 1), c <- present, do: c
      samples = Map.new(present, &{&1, A.signal(frames, &1)})
      stream = interleave(samples, order)
      :rand.seed(:exsss, 99)
      users = for _ <- order, do: :rand.uniform(1 <<< 20) - 1

      # a frame starts where the channel does not increase
      k = 7 * length(present) + 3
      flip_frame = div(k + length(present) - 1, length(present))

      expected =
        Map.new(present, fn c ->
          {c,
           reference(
             &A.biquad/3,
             samples[c],
             [coef_list(coefs(c)), coef_list(coefs_b(c))],
             flip_frame
           )}
        end)
        |> interleave(order)

      pc =
        Enum.map(present, &{:write, &1, pc_values(coefs(&1))}) ++
          [:swap] ++
          Enum.map(present, &{:write, &1, pc_values(coefs_b(&1))}) ++
          [{:swap_at, k}] ++
          Enum.map(Enum.reverse(present), &{:write_after_swap, &1, pc_values(garbage(&1))})

      for {vp, rp, seed} <- @traffic do
        assert {:ok, res} =
                 Verilator.run_stream(sim, [stream], [],
                   valid_pct: vp,
                   ready_pct: rp,
                   seed: seed,
                   tid: order,
                   tuser: users,
                   pc: pc
                 )

        assert res.outputs == [expected]
        assert res.tid == order
        assert res.tuser == users
      end
    end
  end

  describe "one-pole IIR state in memories" do
    setup do
      t = Nx.template({}, :s16)

      {:ok, %{loop_latency: l}} =
        ExHdl.DSP.analyze_scan(&K.one_pole_step/3, [t, t, t], state: 1, ii: :auto)

      :rand.seed(:exsss, 5)
      %{l: l, t: t, xs: for(_ <- 1..600, do: :rand.uniform(65536) - 32769)}
    end

    for {style, init_mode, init, extra} <- [
          {:block, :clear, -5, []},
          {:distributed, :initial, 7, []},
          {:ultra, :clear, 300, []},
          {:block, :clear, 0, [ram_latency: 3]}
        ] do
      @style style
      @init_mode init_mode
      @init init
      @extra extra
      test "#{style}, state_init: #{init_mode}, init #{init}, #{inspect(extra)}", ctx do
        rl = Keyword.get(@extra, :ram_latency, if(@style == :ultra, do: 2, else: 1))
        n = ctx.l + rl
        init = Nx.tensor(@init, type: :s16)

        {:ok, d} =
          ExHdl.DSP.scan_to_sv(
            &K.one_pole_step/3,
            [ctx.t, ctx.t, ctx.t],
            [
              state: 1,
              channels: n,
              state_mem: @style,
              state_init: @init_mode,
              init: init,
              name: "op_#{@style}_#{@init_mode}_#{rl}",
              param_names: ["a"]
            ] ++ @extra
          )

        assert d.busy == (@init_mode == :clear)
        assert d.source =~ ~s{ram_style = "#{@style}"}
        {:ok, sim} = Verilator.build_stream(d)
        a = 9000
        order = for i <- 0..(length(ctx.xs) - 1), do: rem(i, n)

        per =
          Map.new(0..(n - 1), fn c ->
            xs = ctx.xs |> Enum.drop(c) |> Enum.take_every(n)

            {y, _} =
              NxFixed.run_scan_stacked(&K.one_pole_step/3, Nx.tensor(xs, type: :s16), init, [
                Nx.tensor(a, type: :s16)
              ])

            {c, Nx.to_flat_list(y)}
          end)

        expected = interleave(per, order)

        for {vp, rp, seed} <- @traffic do
          assert {:ok, res} =
                   Verilator.run_stream(sim, [ctx.xs], [a],
                     valid_pct: vp,
                     ready_pct: rp,
                     seed: seed
                   )

          assert res.outputs == [expected]
        end
      end
    end
  end

  describe "cascade of two biquads (ExHdl.DSP.cascade/1)" do
    test "each section keeps its own loop; channels with RAM state and both coefficient sets per channel" do
      spec = ExHdl.DSP.cascade([A.stage("eq1"), A.stage("eq2")])
      opts = Keyword.drop(spec, [:fun, :args])
      {:ok, scan} = ExHdl.DSP.analyze_scan(spec[:fun], spec[:args], opts ++ [ii: :auto])
      l = loop_latency()
      assert scan.loop_latency == l
      assert length(scan.groups) >= 2

      n = l + 2
      frames = 24

      {:ok, d} =
        ExHdl.DSP.scan_to_sv(
          spec[:fun],
          spec[:args],
          opts ++
            [name: "bq_cascade", channels: n, state_mem: :block, channel_params: :all]
        )

      assert Enum.map(d.channel_params, & &1.name) |> Enum.uniq() |> length() == 10
      assert d.pc_width == 320
      assert length(d.state_groups) == length(scan.groups)
      {:ok, sim} = Verilator.build_stream(d)

      order = for _f <- 0..(frames - 1), c <- 0..(n - 1), do: c
      samples = Map.new(0..(n - 1), &{&1, A.signal(frames, &1)})
      second = fn c -> A.design(:highpass, 80 + 10 * c) end

      expected =
        Map.new(0..(n - 1), fn c ->
          params = coef_list(coefs(c)) ++ coef_list(second.(c))

          {y, _} =
            NxFixed.run_scan_stacked(
              spec[:fun],
              Nx.tensor(samples[c], type: :s32),
              spec[:init],
              params,
              param_ranges: spec[:param_ranges]
            )

          {c, Nx.to_flat_list(y)}
        end)
        |> interleave(order)

      pc =
        Enum.map(0..(n - 1), &{:write, &1, pc_values(coefs(&1)) ++ pc_values(second.(&1))}) ++
          [:swap]

      for {vp, rp, seed} <- @traffic do
        assert {:ok, res} =
                 Verilator.run_stream(sim, [interleave(samples, order)], [],
                   valid_pct: vp,
                   ready_pct: rp,
                   seed: seed,
                   pc: pc
                 )

        assert res.outputs == [expected]
      end
    end
  end

  defp coef_list(coef), do: [A.coef_tensors(coef)]
  defp pc_values(coef), do: Tuple.to_list(coef)
end
