defmodule ExHdl.RTL.GenTaskTest do
  use ExUnit.Case, async: false

  test "mix ex_hdl.gen.sv writes every module of the RTL hierarchies" do
    dir = Path.join(System.tmp_dir!(), "ex_hdl_gen_#{System.unique_integer([:positive])}")
    Mix.shell(Mix.Shell.Process)

    try do
      Mix.Tasks.ExHdl.Gen.Sv.run(["ExHdl.Test.RTLDesigns.Gen", "--out", dir])

      assert File.ls!(dir) |> Enum.sort() ==
               ~w(async_fifo_8x3.sv counter_8.sv exhdl_cdc_sync_w4_s2.sv)

      assert File.read!(Path.join(dir, "counter_8.sv")) =~ "module counter_8 ("
      assert_received {:mix_shell, :info, ["* " <> _]}
    after
      Mix.shell(Mix.Shell.IO)
      File.rm_rf!(dir)
    end
  end

  test "modules without generators are rejected" do
    assert_raise Mix.Error, ~r/ex_hdl_rtl\/0/, fn ->
      Mix.Tasks.ExHdl.Gen.Sv.run(["ExHdl.RTL.Examples"])
    end
  end
end
