defmodule ExHdl.ChannelWrapTest do
  @moduledoc "Channel kernels (tid, tuser, per-channel parameters, busy) as RTL black boxes."
  use ExUnit.Case, async: true
  use ExHdl.RTL

  alias ExHdl.RTL.Wrap
  alias ExHdl.Test.Audio, as: A

  defp design(name, extra) do
    {:ok, d} =
      ExHdl.DSP.scan_to_sv(
        &A.biquad/3,
        A.args(),
        [
          state: 1,
          param_ranges: A.param_ranges(),
          param_names: ["coef"],
          name: name,
          channels: 16,
          state_mem: :block,
          channel_params: ["coef"],
          tid: true,
          tuser: 8
        ] ++ extra
      )

    d
  end

  test "the black box has the sideband, coefficient port and busy" do
    bb = Wrap.scan(design("bq_bb", []))
    names = Enum.map(bb.ports, & &1.name)
    assert [:pc_addr, :pc_data, :pc_we, :pc_swap, :pc_pending, :busy] -- names == []
    assert %{type: {:u, 160}} = Enum.find(bb.ports, &(&1.name == :pc_data))
  end

  for clock <- [:shared, :separate] do
    @clock clock
    @tag :verilator
    test "a wrapped channel kernel lints inside an RTL design, pc_clock: #{clock}" do
      d = design("bq_w_#{@clock}", pc_clock: @clock)
      axis_in = Interface.axi_stream(data: d.in_width, keep: false, last: false, id: 4, user: 8)
      axis_out = Interface.axi_stream(data: d.out_width, keep: false, last: false, id: 4, user: 8)
      separate = @clock == :separate

      top =
        module "#{d.name}_top" do
          domain(:sys)
          if separate, do: domain(:pc, clock: :pc_clk, reset: nil)
          pc = if separate, do: :pc, else: :sys
          s = slave(:s_axis, axis_in, domain: :sys)
          m = master(:m_axis, axis_out, domain: :sys)
          addr = input(:pc_addr, 4, domain: pc)
          data = input(:pc_data, d.pc_width, domain: pc)
          we = input(:pc_we, 1, domain: pc)
          swap = input(:pc_swap, 1, domain: :sys)
          pending = output(:pc_pending, 1, domain: :sys)
          busy = output(:busy, 1, domain: :sys)

          k =
            instance(:k, Wrap.scan(d),
              domains: if(separate, do: [sys: :sys, pc: :pc], else: []),
              connect: [pc_addr: addr, pc_data: data, pc_we: we, pc_swap: swap]
            )

          pending <~ k.pc_pending
          busy <~ k.busy
          connect(s, k.s_axis)
          connect(k.m_axis, m)
        end

      dir = Path.join(System.tmp_dir!(), "ex_hdl_cwrap_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      files =
        for {f, src} <- ExHdl.Backends.SystemVerilog.RTL.generate(top) do
          File.write!(Path.join(dir, f), src)
          Path.join(dir, f)
        end

      {log, status} =
        System.cmd("verilator", ["--lint-only", "-Wall", "--top-module", top.name | files],
          stderr_to_stdout: true
        )

      File.rm_rf!(dir)
      assert status == 0, log
    end
  end
end
