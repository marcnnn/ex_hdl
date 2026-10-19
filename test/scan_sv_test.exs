defmodule ExHdl.ScanSvTest do
  @moduledoc "Structure of the generated stream kernel RTL (no simulator needed)."
  use ExUnit.Case, async: true

  alias ExHdl.Backends.SystemVerilog.Scan, as: SV
  alias ExHdl.Test.DSP, as: K

  defp t(type), do: Nx.template({}, type)

  defp one_pole(opts),
    do:
      ExHdl.DSP.analyze_scan(&K.one_pole_step/3, [t(:s16), t(:s16), t(:s16)], [state: 1] ++ opts)

  test "unsupported operations are reported by name" do
    {:ok, scan} =
      ExHdl.DSP.analyze_scan(&K.row_take_step/2, [t(:s16), t(:s16)], state: 1, ii: :auto)

    assert_raise SV.UnsupportedError, ~r/Nx operation :take \(node \d+.*needs a 1-D table/, fn ->
      SV.generate(scan)
    end
  end

  test "ii: :auto takes the loop latency" do
    assert {:ok, %{ii: 4, loop_latency: 4, channels: 1}} = one_pole(ii: :auto)
  end

  test "ii: n throttles the input, the state is written n - 1 stages after it is read" do
    {:ok, scan} = one_pole(ii: 4)
    d = SV.generate(scan, name: "op", param_names: ["a"])
    assert %{ii: 4, channels: 1, state_stage: 0, write_stage: 3} = d
    assert d.source =~ "one sample every 4 enabled cycles"
    assert d.source =~ "input  logic [15:0] p_a,"
    assert d.source =~ "module op ("
  end

  test "channels: n keeps n states and accepts a sample every cycle" do
    {:ok, scan} = one_pole(channels: 6)
    d = SV.generate(scan, name: "op", init: Nx.tensor(-5, type: :s16))
    assert d.source =~ "assign gap_ok = 1'b1;"
    assert d.source =~ ~r/logic signed \[15:0\] n\d+_mem \[6\];/
    assert d.source =~ "<= 16'shFFFB;"
  end

  test "the DDC's sine table is block RAM, its multiplies DSP48E1 products" do
    {:ok, scan} =
      ExHdl.DSP.analyze_scan(
        &K.ddc_step/5,
        [{t(:s16), t(:s16)}, t(:u16), t(:u16), t(:s16), []],
        state: 1
      )

    d = SV.generate(scan, param_names: ["phase_inc", "gain"])
    assert d.latency == scan.pipeline_latency + 1
    assert d.in_width == 32 and d.out_width == 32
    assert [%{port: "p_phase_inc", bits: 16}, %{port: "p_gain", bits: 16}] = d.params
    # one shared table, read through two ports
    assert length(Regex.scan(~r/logic signed \[15:0\] rom\d+ \[1024\];/, d.source)) == 1
    assert length(Regex.scan(~r/_p = \S+ \* \S+;/, d.source)) == 6
  end

  test ":init must match the state" do
    {:ok, scan} = one_pole(ii: 4)

    assert_raise ArgumentError, ~r/:init must be shaped like the state/, fn ->
      SV.generate(scan, init: Nx.tensor([1, 2], type: :s16))
    end
  end

  @tag :tmp_dir
  test "mix ex_hdl.gen.sv writes the kernels of a module", %{tmp_dir: dir} do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.ExHdl.Gen.Sv.run(["ExHdl.Test.SdrKernels", "--out", dir])

    for name <- ~w(ddc_q15 fir_complex_q15 one_pole_q15 one_pole_q15_ch5) do
      assert File.read!(Path.join(dir, "#{name}.sv")) =~ "module #{name} ("
    end

    assert_received {:mix_shell, :info, ["  latency 6, ii 5, channels 1, tdata 16 -> 16 bits"]}
  end
end
