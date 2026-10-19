defmodule ExHdl.MemoryCosimTest do
  @moduledoc """
  Large state (:memory class) in hardware: the Forney convolutional
  interleaver as a stream kernel (`ExHdl.Test.MemoryKernels`), whose delay
  line is read with a data-dependent index from a memory, co-simulated
  against `ExSdr.Comm.ConvInterleaver.stream/5`; and resource checks with
  Yosys for the memory and FIR mappings.
  """
  use ExUnit.Case, async: true

  alias ExHdl.Sim.Verilator
  alias ExHdl.Test.MemoryKernels, as: K
  alias ExSdr.Comm.ConvInterleaver

  @moduletag timeout: 600_000

  @traffic [{100, 100, 1}, {70, 50, 2}, {30, 95, 3}, {95, 20, 4}]

  defp interleaver(i, m, inverse, fill) do
    state = K.conv_interleave_state(i, m, fill)
    template = &Nx.Defn.Composite.traverse(&1, fn t -> Nx.to_template(t) end)
    args = [Nx.template({}, :u8), template.(state), [branches: i, depth: m, inverse: inverse]]
    name = "il_#{i}x#{m}_#{if inverse, do: "de", else: "in"}_#{fill}"

    {:ok, d} =
      ExHdl.DSP.scan_to_sv(&K.conv_interleave_step/3, args, state: 1, init: state, name: name)

    d
  end

  describe "convolutional interleaver" do
    @describetag :verilator

    for {i, m, fill, path} <- [
          {3, 2, 0, "LUT RAM"},
          {12, 17, 0, "block RAM"},
          {3, 2, 7, "multiplexer"}
        ],
        inverse <- [false, true] do
      @params {i, m, fill, inverse}
      test "#{i} branches, depth #{m}, #{if inverse, do: "deinterleave", else: "interleave"}, line #{fill}: #{path}" do
        {i, m, fill, inverse} = @params
        d = interleaver(i, m, inverse, fill)
        assert d.source =~ "delay line memory" == (fill == 0)
        {:ok, sim} = Verilator.build_stream(d)

        :rand.seed(:exsss, i * 100 + m)
        n = 2 * i * (i - 1) * m + 500
        bytes = for _ <- 1..n, into: <<>>, do: <<:rand.uniform(256) - 1>>
        c = ConvInterleaver.new(branches: i, depth: m)
        history = :binary.copy(<<fill>>, ConvInterleaver.delay(c))
        direction = if inverse, do: :deinterleave, else: :interleave
        {expected, _} = ConvInterleaver.stream(c, direction, bytes, {history, 0}, native: false)

        for {vp, rp, seed} <- @traffic do
          assert {:ok, res} =
                   Verilator.run_stream(sim, [:binary.bin_to_list(bytes)], [],
                     valid_pct: vp,
                     ready_pct: rp,
                     seed: seed
                   )

          assert res.outputs == [:binary.bin_to_list(expected)]
        end
      end
    end
  end

  describe "resources (Yosys synth_xilinx)" do
    @describetag :yosys

    defp synth(d) do
      {:ok, u} = ExHdl.Synth.Yosys.utilization(%{"#{d.name}.sv" => d.source}, d.name)
      u
    end

    test "the DVB-T interleaver's 2244-byte line is block RAM" do
      u = synth(interleaver(12, 17, false, 0))
      assert u.bram18 in 1..2
      assert u.ff < 200
    end

    test "fir_filter_fff with 63 taps: folded DSP chain, no adder tree" do
      block =
        ExSdr.Filters.block(:fir_filter_fff,
          taps: ExHdl.Test.BlockCases.lowpass(63),
          format: ExHdl.Test.BlockCases.q15()
        )

      {:ok, chain} = ExHdl.Block.scan_to_sv(block, name: "fir63_chain")
      {:ok, tree} = ExHdl.Block.scan_to_sv(block, name: "fir63_tree", fir: :tree)
      c = synth(chain)
      t = synth(tree)
      assert c.dsp <= div(t.dsp, 2) + 2
      assert c.lut < 100 and t.lut > 1000
      assert chain.latency < tree.latency
    end

    test "a 1024-sample moving average is a running sum over block RAM" do
      block =
        ExSdr.Math.block(:moving_average_ff,
          length: 1024,
          scale: 1 / 1024,
          format: ExHdl.Test.BlockCases.q15()
        )

      {:ok, d} = ExHdl.Block.scan_to_sv(block, name: "ma1024")
      u = synth(d)
      assert u.bram18 == 1
      assert u.dsp == 0
      assert u.ff < 200
    end
  end
end
