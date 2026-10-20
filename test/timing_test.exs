defmodule ExHdl.Target.TimingTest do
  use ExUnit.Case, async: true

  alias ExHdl.DSP
  alias ExHdl.Target.Timing
  alias ExHdl.Test.DSP, as: K
  alias NxFixed.IntSet

  # Device data in the shape ExHdlXilinx.Device.get("xcku3p") returns.
  @xcku3p %{
    name: "xcku3p",
    family: :kintex_ultrascale_plus,
    resources: %{
      clb_luts: 162_720,
      clb_ffs: 325_440,
      bram36: 360,
      uram288: 48,
      dsp: 1_368,
      gty: 16
    },
    dsp: %{
      primitive: "DSP48E2",
      multiplier: {27, 18},
      preadder_bits: 27,
      accumulator_bits: 48,
      latency_full: 3,
      latency_min: 1
    },
    bram: %{primitive: "RAMB36E2", latency_with_output_reg: 2, latency_no_output_reg: 1},
    uram: %{primitive: "URAM288", depth: 4_096, width: 72, latency_with_output_reg: 2},
    fmax_mhz: %{
      dsp48e2_all_regs: %{"-1" => 645, "-2" => 775, "-3" => 891},
      bram_all_regs: %{"-1" => 650, "-2" => 737, "-3" => 825},
      uram: %{"-1" => 600, "-2" => 650, "-3" => 700}
    },
    delays: %{
      "-1" => %{
        lut_ns: 0.12,
        carry_ns_per_bit: 0.012,
        ff_clk_to_q_ns: 0.10,
        ff_setup_ns: 0.03,
        net_typ_ns: 0.35
      },
      "-2" => %{
        lut_ns: 0.10,
        carry_ns_per_bit: 0.010,
        ff_clk_to_q_ns: 0.09,
        ff_setup_ns: 0.03,
        net_typ_ns: 0.30
      }
    }
  }

  # A graph with two operands of the given signed widths.
  defp mul_cost(t, wa, wb) do
    r = fn w -> IntSet.of_type({:s, w}) end
    graph = %{nodes: %{1 => %{range: r.(wa)}, 2 => %{range: r.(wb)}}}
    Timing.cost(%{op: :multiply, inputs: [1, 2]}, graph, t)
  end

  defp add_cost(t, w) do
    graph = %{
      nodes: %{1 => %{range: IntSet.of_type({:s, w})}, 2 => %{range: IntSet.of_type({:s, w})}}
    }

    {:comb, ns} = Timing.cost(%{op: :add, inputs: [1, 2]}, graph, t)
    ns
  end

  test "Zynq-7000 stays the default with its original numbers" do
    t = Timing.new()
    assert %{family: :zynq7, speed_grade: "-1", dsp_multiplier: {25, 18}, uram_latency: nil} = t
    assert Timing.period_ns(t) == 1000 / 150 * 0.75
    assert Timing.level_ns(t) == 0.6
    assert_in_delta add_cost(t, 16), 0.6 + 0.03 * 17, 1.0e-12
    assert mul_cost(t, 25, 18) == {:reg, 3, :dsp48}
    assert mul_cost(t, 27, 18) == {:reg, 5, :dsp48_cascade}
    assert Timing.new(ii: 2, channels: 4, clock_mhz: 200).clock_mhz == 200
  end

  test "UltraScale+ uses DSP48E2 sizes and per-grade delays" do
    t1 = Timing.new(family: :ultrascale_plus)
    t2 = Timing.new(family: :ultrascale_plus, speed_grade: "-2", clock_mhz: 250)

    assert %{dsp_multiplier: {27, 18}, dsp_preadder_bits: 27, dsp_accumulator_bits: 48} = t1
    assert %{uram_latency: 2, bram_latency: 2, dsp_latency: 3} = t1
    assert mul_cost(t1, 27, 18) == {:reg, 3, :dsp48}
    assert mul_cost(t1, 18, 27) == {:reg, 3, :dsp48}
    assert mul_cost(t1, 28, 18) == {:reg, 5, :dsp48_cascade}
    assert Timing.dsp_fits?(t1, 26, 18)
    refute Timing.dsp_fits?(Timing.new(), 26, 18)

    assert_in_delta Timing.level_ns(t2), 0.40, 1.0e-12
    assert_in_delta Timing.period_ns(t2), 4.0 * 0.85 - 0.09 - 0.03, 1.0e-12
    assert add_cost(t2, 32) < add_cost(t1, 32)
    assert add_cost(t1, 32) < add_cost(Timing.new(), 32)
  end

  test "families, grades and aliases" do
    assert Timing.new(family: :kintex_ultrascale_plus).family == :ultrascale_plus

    assert_raise ArgumentError, ~r/unknown family :spartan3/, fn ->
      Timing.new(family: :spartan3)
    end

    assert_raise ArgumentError, ~r/speed grade "-3"; known: -1, -2/, fn ->
      Timing.new(family: :ultrascale_plus, speed_grade: "-3")
    end
  end

  test "ExHdlXilinx.Device data: from_device/3 and timing_options keyword lists" do
    t = Timing.from_device(@xcku3p, "-2", clock_mhz: 300)

    assert %{family: :ultrascale_plus, speed_grade: "-2", clock_mhz: 300, lut_ns: 0.10} = t
    assert t.net_typ_ns == 0.30
    assert t.fmax_mhz == %{dsp: 775, bram: 737, uram: 650}
    assert t.resources == %{lut: 162_720, ff: 325_440, bram: 360, uram: 48, dsp: 1_368, gt: 16}
    assert Timing.warnings(t) == []

    assert Timing.warnings(Timing.from_device(@xcku3p, "-1", clock_mhz: 640)) ==
             ["640 MHz exceeds the uram maximum of 600 MHz for ultrascale_plus -1"]

    # what ExHdlXilinx.Device.timing_options/3 returns today, plus the family
    opts = [
      lut_ns: 0.12,
      carry_ns_per_bit: 0.012,
      dsp_latency: 3,
      bram_latency: 2,
      clock_mhz: 250
    ]

    t = Timing.new([family: :kintex_ultrascale_plus] ++ opts)
    assert %{lut_ns: 0.12, dsp_multiplier: {27, 18}, clock_mhz: 250, net_typ_ns: 0.35} = t
    # without a family the delays apply to the Zynq-7000 primitives
    assert %{family: :zynq7, lut_ns: 0.12, dsp_multiplier: {25, 18}} = Timing.new(opts)
  end

  test "memory_style picks LUTRAM, block RAM or URAM" do
    us = Timing.new(family: :ultrascale_plus)
    z7 = Timing.new()
    assert Timing.memory_style(us, 32, 64) == :distributed
    assert Timing.memory_style(us, 32, 1024) == :block
    assert Timing.memory_style(us, 72, 4096) == :ultra
    assert Timing.memory_style(z7, 72, 4096) == :block
  end

  test "stream kernels schedule against the UltraScale+ model" do
    t = fn type -> Nx.template({}, type) end
    args = [t.(:s16), t.(:s16), t.(:s16)]

    assert {:error, %{message: msg}} =
             DSP.analyze_scan(&K.one_pole_step/3, args, state: 1, family: :ultrascale_plus)

    assert msg =~ "multiply       dsp48, 3 cycles"

    assert {:ok, scan} =
             DSP.analyze_scan(&K.one_pole_step/3, args,
               state: 1,
               ii: 4,
               family: :ultrascale_plus,
               speed_grade: "-2",
               clock_mhz: 400
             )

    assert scan.timing.family == :ultrascale_plus
    assert scan.timing.clock_mhz == 400
  end
end
