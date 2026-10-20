defmodule ExHdl.RTL.Wrap do
  @moduledoc """
  Existing ExHdl generators as instantiable black boxes, with their
  SystemVerilog attached as `sources`, so RTL designs can use them and
  co-simulate them in Verilator. They have no BEAM model.

      parser = Wrap.protocol(MySDR.Protocol.iq_frame(), :parser)
      u = instance :rx, parser
      connect(s_axis, u.s_axis)
      connect(u.m_axis, payload)
      channel = u.meta_channel_id

  Both use domain `:sys` (`clk`, synchronous active-low `rst_n`).
  """
  use ExHdl.RTL

  alias ExHdl.Protocol.Spec

  @doc """
  `<name>_parser`, `<name>_emitter` or `<name>_loopback` of a packet spec
  (`ExHdl.Backends.SystemVerilog.Protocol`). AXI4-Stream ports are the
  bundles `s_axis` (slave) and `m_axis` (master) with tdata, tkeep, tlast
  (and tuser where the spec has end-of-packet checks); the other ports are
  `ExHdl.Backends.SystemVerilog.Protocol.ports/2` (`meta_*`, match tables,
  `dropped_packets`).
  """
  def protocol(%Spec{} = spec, which) when which in [:parser, :emitter, :loopback] do
    tuser? = Spec.tuser?(spec)
    s_user = if tuser? and which == :emitter, do: [user: 1], else: []
    m_user = if tuser?, do: [user: 1], else: []
    s_axis = Interface.axi_stream([data: spec.bus_width] ++ s_user)
    m_axis = Interface.axi_stream([data: spec.bus_width] ++ m_user)
    sources = ExHdl.Backends.SystemVerilog.Protocol.generate(spec)
    ports = ExHdl.Backends.SystemVerilog.Protocol.ports(spec, which)

    black_box "#{spec.name}_#{which}", sources: sources do
      domain(:sys)

      for {name, :input, bits, signed} <- ports,
          do: input(name, field_type(%{bits: bits, signed: signed}))

      slave(:s_axis, s_axis)
      master(:m_axis, m_axis)

      for {name, :output, bits, signed} <- ports,
          do: output(name, field_type(%{bits: bits, signed: signed}), comb_from: :none)
    end
  end

  defp field_type(%{bits: b, signed: true}), do: s(b)
  defp field_type(%{bits: b}), do: u(b)

  @doc """
  A stream kernel (`ExHdl.Backends.SystemVerilog.Scan.Design`, from
  `ExHdl.DSP.scan_to_sv/3`). Ports: the `p_<name>` parameter inputs
  (static), `p_load` if there are parameters (a cycle with it high
  captures them; they apply between samples), the bundles `s_axis` /
  `m_axis` (tdata, tvalid, tready; tid and tuser when the kernel has them),
  and with per-channel parameters `pc_addr`, `pc_data`, `pc_we` (domain
  `:pc` with clock `pc_clk` for `pc_clock: :separate`), `pc_swap`,
  `pc_pending`; `busy` for a state memory cleared after reset.
  """
  def scan(%ExHdl.Backends.SystemVerilog.Scan.Design{} = d) do
    cw = max(1, bit_len(d.channels - 1))
    s_id = if d.tid, do: cw, else: 0
    m_id = if d.channels > 1, do: cw, else: 0

    s_axis =
      Interface.axi_stream(data: d.in_width, keep: false, last: false, id: s_id, user: d.tuser)

    m_axis =
      Interface.axi_stream(data: d.out_width, keep: false, last: false, id: m_id, user: d.tuser)

    sources = %{"#{d.name}.sv" => d.source}
    separate = d.pc_clock == :separate

    black_box d.name, sources: sources do
      domain(:sys)
      if separate, do: domain(:pc, clock: :pc_clk, reset: nil)

      for p <- d.params do
        bits = p.bits * (p.shape |> Tuple.to_list() |> Enum.product())
        input(String.to_atom(p.port), bits, domain: :static)
      end

      # captures the parameter ports; they apply once earlier samples have left
      if d.params != [], do: input(:p_load, 1, domain: :sys)

      if d.channel_params != [] do
        pc = if separate, do: :pc, else: :sys
        input(:pc_addr, cw, domain: pc)
        input(:pc_data, d.pc_width, domain: pc)
        input(:pc_we, 1, domain: pc)
        input(:pc_swap, 1, domain: :sys)
        output(:pc_pending, 1, domain: :sys, comb_from: :none)
      end

      if d.busy, do: output(:busy, 1, domain: :sys, comb_from: :none)

      # every output comes from registers (no combinational ready path)
      slave(:s_axis, s_axis, domain: :sys, comb_from: :none)
      master(:m_axis, m_axis, domain: :sys, comb_from: :none)
    end
  end

  defp bit_len(0), do: 0
  defp bit_len(v), do: 1 + bit_len(Bitwise.bsr(v, 1))
end
