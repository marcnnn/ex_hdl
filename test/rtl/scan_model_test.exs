defmodule ExHdl.RTL.ScanModelTest do
  @moduledoc """
  BEAM models of wrapped stream kernels (`Wrap.scan/2`, `model:`) against
  the generated SystemVerilog in Verilator, cycle by cycle, with random
  valid/ready, parameter loads and resets; and against the Nx reference.
  """
  use ExUnit.Case, async: true
  use ExHdl.RTL

  alias ExHdl.RTL.{Bench, Sim, Wrap}
  alias ExHdl.Test.DSP, as: K

  @t Nx.template({}, :s16)

  defmodule Driver do
    @moduledoc false
    # random tvalid/tready/p_load; tid round robin over accepted samples
    @behaviour ExHdl.RTL.Bench.Agent
    # words: tdata of the samples to send, in order (default random)
    defstruct [:channels, :types, words: nil, tid: 0, offer: nil]

    # a reset in the middle of the run
    def drive(st, cycle) when cycle in 350..351,
      do: {%{rst_n: 0, s_axis_tvalid: 0}, %{st | offer: nil, tid: 0}}

    def drive(st, _cycle) do
      offer =
        st.offer ||
          %{s_axis_tdata: rnd(st.types.s_axis_tdata), s_axis_tuser: rnd(st.types[:s_axis_tuser])}

      valid = if st.offer || :rand.uniform() < 0.7, do: 1, else: 0
      load = if :rand.uniform() < 0.03, do: 1, else: 0

      ins =
        %{
          s_axis_tvalid: valid,
          s_axis_tdata: offer.s_axis_tdata,
          m_axis_tready: if(:rand.uniform() < 0.6, do: 1, else: 0),
          load: load
        }
        |> then(&if(load == 1, do: Map.put(&1, :a, Enum.random(0..32767)), else: &1))
        |> then(&if(st.types[:s_axis_tid], do: Map.put(&1, :s_axis_tid, st.tid), else: &1))
        |> then(
          &if(st.types[:s_axis_tuser],
            do: Map.put(&1, :s_axis_tuser, offer.s_axis_tuser),
            else: &1
          )
        )

      {ins, %{st | offer: if(valid == 1, do: offer, else: nil)}}
    end

    def sample(%{offer: o} = st, %{s_axis_tready: 1}, _c) when o != nil,
      do: %{st | offer: nil, tid: rem(st.tid + 1, st.channels), words: tl_words(st.words)}

    def sample(st, _outs, _c), do: st

    defp next_word(%{words: [w | _]}), do: w
    defp next_word(%{words: []}), do: 0
    defp next_word(st), do: rnd(st.types.s_axis_tdata)

    defp tl_words([_ | rest]), do: rest
    defp tl_words(other), do: other

    defp rnd(nil), do: 0
    defp rnd({_, _} = t), do: Enum.random(ExHdl.RTL.Expr.range(t))
  end

  defp one_pole(name, opts) do
    {:ok, d} =
      ExHdl.DSP.scan_to_sv(
        &K.one_pole_step/3,
        [@t, @t, @t],
        [state: 1, name: name, param_names: ["a"]] ++ opts
      )

    d
  end

  defp model(init \\ Nx.tensor(0, type: :s16)),
    do: [fun: &K.one_pole_step/3, args: [@t, @t, @t], init: init]

  # top level: the kernel's ports as top ports (a for p_a)
  defp top(d, typed) do
    bb = Wrap.scan(d, model: model(), typed: typed)
    s_if = Wrap.scan_axis(d, :s_axis, typed: typed)
    m_if = Wrap.scan_axis(d, :m_axis, typed: typed)

    module "#{d.name}_top" do
      s = slave(:s_axis, s_if)
      m = master(:m_axis, m_if)
      a = input(:a, if(typed, do: s(16), else: u(16)), domain: :static)
      load = input(:load, 1)
      k = instance(:k, bb, connect: [p_a: a, p_load: load])
      connect(s, k.s_axis)
      connect(k.m_axis, m)
      if d.busy, do: output(:busy, 1) <~ k.busy
    end
  end

  test "the model's outputs are the Nx reference of the accepted samples" do
    d = one_pole("sm_beam", ii: :auto)
    assert d.ii > 1
    m = top(d, true)
    a = 9000
    xs = for i <- 1..40, do: rem(i * 3001, 30000) - 15000

    stim =
      [%{rst_n: 0, a: a}, %{rst_n: 0}] ++
        Enum.map(xs, &%{rst_n: 1, s_axis_tvalid: 1, s_axis_tdata: &1, m_axis_tready: 1}) ++
        List.duplicate(%{s_axis_tvalid: 0}, 60)

    {_, out} = m |> Sim.new() |> Sim.run(stim)

    # with ii > 1 a held tvalid is taken every ii cycles
    taken =
      for {o, ins} <- Enum.zip(out, stim),
          ins[:s_axis_tvalid] == 1 and o.s_axis_tready == 1,
          do: ins.s_axis_tdata

    assert length(taken) < length(xs)
    got = for o <- out, o.m_axis_tvalid == 1, do: o.m_axis_tdata

    {ref, _} =
      NxFixed.run_scan(
        &K.one_pole_step/3,
        Enum.map(taken, &Nx.tensor(&1, type: :s16)),
        Nx.tensor(0, type: :s16),
        [Nx.tensor(a, type: :s16)]
      )

    assert got == Enum.map(ref, &Nx.to_number/1)
    assert Enum.any?(got, &(&1 < 0))
  end

  # an ex_sdr block wrapped with its model, all parameter ports at the top
  defp block_top(d, block) do
    bb = Wrap.scan(d, model: block)
    s_if = Wrap.scan_axis(d, :s_axis)
    m_if = Wrap.scan_axis(d, :m_axis)

    module "#{d.name}_top" do
      s = slave(:s_axis, s_if)
      m = master(:m_axis, m_if)

      conns =
        for p <- d.params do
          n = Tuple.product(p.shape)
          {String.to_atom(p.port), input(String.to_atom(p.port), p.bits * n, domain: :static)}
        end

      conns = if d.params == [], do: conns, else: [{:p_load, input(:load, 1)} | conns]
      k = instance(:k, bb, connect: conns)
      connect(s, k.s_axis)
      connect(k.m_axis, m)
    end
  end

  defp pack(fields, leaf_values) do
    fields
    |> Enum.zip(leaf_values)
    |> Enum.reduce(0, fn {f, vs}, acc ->
      vs
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {v, e}, acc ->
        Bitwise.bor(
          acc,
          Bitwise.bsl(Bitwise.band(v, Bitwise.bsl(1, f.bits) - 1), f.offset + e * f.bits)
        )
      end)
    end)
  end

  describe "against Verilator" do
    @describetag :verilator
    @describetag timeout: 900_000

    for {mod, name, bopts, label} <- [
          {ExSdr.Math, :moving_average_cc, [length: 16, scale: 1 / 16], "moving_average_cc"},
          {ExSdr.Digital, :chunks_to_symbols_bc,
           [table: [{0.7, 0.7}, {-0.7, 0.7}, {-0.7, -0.7}, {0.7, -0.7}]], "chunks_to_symbols_bc"},
          {ExSdr.Filters, :fir_filter_ccf, [taps: ExHdl.Test.BlockCases.lowpass(15)], "fir_ccf"},
          {ExSdr.Timing, :mmse_resampler_ff, [resamp_ratio: 0.75], "mmse_resampler_ff"}
        ] do
      @mod mod
      @name name
      @bopts bopts
      @label label
      test "ex_sdr block #{label} with its model" do
        alias ExHdl.Test.BlockCases, as: C
        block = @mod.block(@name, Keyword.put_new(@bopts, :format, C.q15()))
        {:ok, d} = ExHdl.Block.scan_to_sv(block, name: "smb_" <> @label, ii: :auto)
        m = block_top(d, block)
        types = for p <- ExHdl.RTL.Module.data_inputs(m), into: %{}, do: {p.name, p.type}

        idle =
          d.params
          |> Enum.zip(C.leaf_ints(List.to_tuple(block.params)))
          |> Map.new(fn {p, vs} ->
            {String.to_atom(p.port), pack([%{bits: p.bits, offset: 0}], [vs])}
          end)

        input = C.stimulus(block, 300, 4, 5)
        leaves = C.leaf_ints(input)
        words = for i <- 0..299, do: pack(d.inputs, Enum.map(leaves, &[Enum.at(&1, i)]))

        :rand.seed(:exsss, {3, 4, 5})

        bench =
          m
          |> Sim.new()
          |> Bench.new([drv: %Driver{channels: 1, types: types, words: words}], idle: idle)
          |> Bench.run(900)

        r = Bench.compare(bench)
        assert r == :ok, inspect(r)
        assert Enum.count(Bench.stimulus(bench), &(&1[:s_axis_tvalid] == 1)) > 100
      end
    end

    for {label, opts, typed} <- [
          {"ii: auto, typed ports", [ii: :auto], true},
          {"ii: 1 by channels, round robin", [channels: :auto_loop], false},
          {"channels in LUT RAM with tid, tuser and the clear sweep",
           [channels: :auto_loop, state_mem: :distributed, tid: true, tuser: 5], false},
          {"state folded over 3 rows of block RAM, round robin",
           [channels: 3, state_mem: :block, state_fold: 3], false}
        ] do
      @label label
      @opts opts
      @typed typed
      test "one-pole kernel, #{label}" do
        opts =
          case Keyword.get(@opts, :channels) do
            :auto_loop ->
              {:ok, %{loop_latency: l}} =
                ExHdl.DSP.analyze_scan(&K.one_pole_step/3, [@t, @t, @t], state: 1, ii: :auto)

              Keyword.put(@opts, :channels, l + 1)

            _ ->
              @opts
          end

        name = "sm_" <> (:erlang.phash2(@label) |> Integer.to_string())
        d = one_pole(name, opts)
        m = top(d, @typed)
        types = for p <- ExHdl.RTL.Module.data_inputs(m), into: %{}, do: {p.name, p.type}

        for seed <- 1..3 do
          :rand.seed(:exsss, {seed, 1, 2})

          bench =
            m
            |> Sim.new()
            |> Bench.new([drv: %Driver{channels: d.channels, types: types}], idle: %{a: 1234})
            |> Bench.run(700)

          r = Bench.compare(bench)
          assert r == :ok, "seed #{seed}: #{inspect(r)}"
          assert Enum.count(Bench.stimulus(bench), &(&1[:load] == 1)) > 3
        end
      end
    end
  end
end
