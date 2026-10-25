defmodule ExHdl.FrameCosimTest do
  @moduledoc """
  ex_sdr's linear :frame filters (decimating and interpolating FIRs,
  rational resamplers, polyphase filter banks) generated from their
  `%NxFixed.Block{}` (`ExHdl.Frame.to_sv/2`) and co-simulated against
  `NxFixed.Block.run/4` on random full-range input, bit for bit, with
  random backpressure.
  """
  use ExUnit.Case, async: true

  alias ExHdl.Sim.Verilator
  alias ExHdl.Test.BlockCases, as: C

  @traffic [{100, 100, 1}, {70, 50, 2}, {30, 95, 3}, {95, 20, 4}]

  defp taps(n), do: C.lowpass(n)
  defp ctaps(n), do: Enum.map(C.lowpass(n), &{&1, &1 / 2})

  # {label, name, block opts, structure}
  @cases [
    {"fir_fff_decim4", :fir_filter_fff, [taps: {:taps, 31}, decimation: 4], :polyphase_decimator},
    {"fir_ccf_decim3", :fir_filter_ccf, [taps: {:taps, 31}, decimation: 3], :polyphase_decimator},
    {"fir_ccc_decim2", :fir_filter_ccc, [taps: {:ctaps, 15}, decimation: 2],
     :polyphase_decimator},
    {"fir_fcc_decim2", :fir_filter_fcc, [taps: {:ctaps, 15}, decimation: 2],
     :polyphase_decimator},
    {"fir_ccf_63_decim8", :fir_filter_ccf, [taps: {:taps, 63}, decimation: 8],
     :polyphase_decimator},
    {"interp_fff_3", :interp_fir_filter_fff, [taps: {:taps, 31}, interpolation: 3], :direct},
    {"interp_ccf_4", :interp_fir_filter_ccf, [taps: {:taps, 31}, interpolation: 4], :direct},
    {"interp_ccc_2", :interp_fir_filter_ccc, [taps: {:ctaps, 15}, interpolation: 2], :direct},
    {"interp_ccf_63_8", :interp_fir_filter_ccf, [taps: {:taps, 63}, interpolation: 8], :direct},
    {"pfb_interp_4", :pfb_interpolator_ccf, [taps: {:taps, 31}, interpolation: 4], :direct},
    {"resamp_fff_3_2", :rational_resampler_fff,
     [taps: {:taps, 31}, interpolation: 3, decimation: 2], :direct},
    {"resamp_ccf_2_3", :rational_resampler_ccf,
     [taps: {:taps, 31}, interpolation: 2, decimation: 3], :direct},
    {"resamp_ccf_5_4_ph", :rational_resampler_ccf,
     [taps: {:taps, 31}, interpolation: 5, decimation: 4, phase: 2], :direct},
    {"pfb_decim_4", :pfb_decimator_ccf, [taps: {:taps, 31}, decimation: 4], :polyphase_decimator},
    {"pfb_decim_4_ch1", :pfb_decimator_ccf, [taps: {:taps, 31}, decimation: 4, channel: 1],
     :polyphase_decimator}
  ]

  defp block(name, opts) do
    opts =
      Enum.map(opts, fn
        {:taps, {:taps, n}} -> {:taps, taps(n)}
        {:taps, {:ctaps, n}} -> {:taps, ctaps(n)}
        other -> other
      end)

    ExSdr.Filters.block(name, [format: C.q15()] ++ opts)
  end

  describe "co-simulation" do
    @describetag :verilator
    @describetag timeout: 600_000

    for {label, name, opts, structure} <- @cases do
      @label label
      @name name
      @opts opts
      @structure structure

      test "#{label}: RTL is bit-identical to NxFixed.Block.run" do
        block = block(@name, @opts)
        {:ok, design} = ExHdl.Frame.to_sv(block, name: "frm_" <> @label)
        assert design.structure == @structure

        {d, _} = block.rate
        input = C.stimulus(block, d * 50, 256, 11)
        {out, _} = NxFixed.Block.run(block, input)
        expected = C.leaf_ints(out)
        {:ok, sim} = Verilator.build_stream(design)

        for {vp, rp, seed} = traffic <- @traffic do
          assert {:ok, res} =
                   Verilator.run_stream(sim, C.leaf_ints(input), [],
                     valid_pct: vp,
                     ready_pct: rp,
                     seed: seed
                   )

          assert res.outputs == expected, "#{@label}, traffic #{inspect(traffic)}"
        end
      end
    end

    test "decimator takes one input per cycle, interpolator gives one output per cycle" do
      for {name, opts, items} <- [
            {:fir_filter_fff, [taps: taps(31), decimation: 4], :inputs},
            {:interp_fir_filter_fff, [taps: taps(31), interpolation: 4], :outputs}
          ] do
        block = block(name, opts)
        {:ok, design} = ExHdl.Frame.to_sv(block, name: "frm_rate_#{name}")
        {:ok, sim} = Verilator.build_stream(design)
        {d, l} = block.rate
        n = 2000 * d
        input = C.stimulus(block, n, 256, 3)
        {:ok, res} = Verilator.run_stream(sim, C.leaf_ints(input), [])
        count = if items == :inputs, do: n, else: div(n, d) * l
        # cycles include the latency and the drain of 64 + latency idle cycles
        assert res.cycles <= count + 2 * design.latency + 64 + 16
      end
    end
  end

  describe "analysis" do
    test "multirate structure of a decimating FIR" do
      {:ok, ir} = ExHdl.Frame.analyze(block(:fir_filter_ccf, taps: taps(31), decimation: 4))
      assert {ir.d, ir.l, ir.k, ir.anchors} == {4, 1, 31, [0]}
      assert [%{shift: 15, const: 16_384, terms: [_]}, %{terms: [_]}] = ir.outputs
      [%{terms: [%{taps: [g]}]} | _] = ir.outputs
      assert g == NxFixed.Num.quantize_constants(taps(31), C.q15())
    end

    test "rational resampler: anchors per output phase" do
      {:ok, ir} =
        ExHdl.Frame.analyze(
          block(:rational_resampler_fff, taps: taps(31), interpolation: 3, decimation: 2)
        )

      assert {ir.d, ir.l, ir.k, ir.anchors} == {2, 3, 11, [0, 0, 1]}
    end

    test "complex taps on complex data: four terms" do
      {:ok, ir} = ExHdl.Frame.analyze(block(:fir_filter_ccc, taps: ctaps(15), decimation: 2))
      assert Enum.map(ir.outputs, &length(&1.terms)) == [2, 2]
    end

    test "kernels that are not linear in the input are rejected" do
      b =
        block(:freq_xlating_fir_filter_ccf,
          taps: taps(31),
          decimation: 4,
          center_freq: 1000.0,
          sampling_freq: 48_000.0
        )

      assert {:error, %ExHdl.Frame.Error{message: msg}} = ExHdl.Frame.to_sv(b)
      assert msg =~ "not a linear frame kernel"
    end

    test "stream blocks are not frame blocks" do
      assert {:error, %ExHdl.Frame.Error{message: msg}} =
               ExHdl.Frame.analyze(block(:fir_filter_fff, taps: taps(15)))

      assert msg =~ "not a fixed-rate frame block"
    end
  end
end
