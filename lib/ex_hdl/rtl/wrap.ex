defmodule ExHdl.RTL.Wrap do
  @moduledoc """
  Existing ExHdl generators as instantiable black boxes, with their
  SystemVerilog attached as `sources`, so RTL designs can use them and
  co-simulate them in Verilator. Stream kernels can carry a BEAM model
  (`scan/2`, option `model:`); protocol blocks have none.

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

  Options:

    * `model: [fun: f, args: args, init: state]` - a BEAM model for
      `ExHdl.RTL.Sim` (`ExHdl.RTL.Wrap.ScanModel`): `fun` and `args` as
      given to `ExHdl.DSP.analyze_scan/3` (`state:` index, default 1),
      `init` the initial state as for `scan_to_sv/3` (default zeros). The
      model steps the Nx kernel once per accepted sample and reproduces
      the generated module's handshake cycle by cycle. A
      `%NxFixed.Block{}` (as given to `ExHdl.Block.scan_to_sv/2`) works too.
    * `typed: true` - signed ports where the kernel's values are signed:
      `p_<name>` of one signed element, and `tdata` when it holds exactly
      one signed element without padding. Default `false` (all ports
      unsigned vectors, as before).

      bb = Wrap.scan(design, model: [fun: &Servo.pi_step/5, args: args], typed: true)
  """
  def scan(%ExHdl.Backends.SystemVerilog.Scan.Design{} = d, opts \\ []) do
    cw = max(1, bit_len(d.channels - 1))
    typed = Keyword.get(opts, :typed, false)
    s_axis = scan_axis(d, :s_axis, typed: typed)
    m_axis = scan_axis(d, :m_axis, typed: typed)
    out_t = tdata_type(d.outputs, d.out_width, typed)

    sources = %{"#{d.name}.sv" => d.source}
    separate = d.pc_clock == :separate

    model =
      case Keyword.get(opts, :model) do
        nil ->
          nil

        %NxFixed.Block{} = b ->
          m = [fun: b.fun, args: ExHdl.Block.args(b), init: ExHdl.Block.init(b)]
          {ExHdl.RTL.Wrap.ScanModel, {d, Keyword.put(m, :out_type, out_t)}}

        m when is_list(m) ->
          {ExHdl.RTL.Wrap.ScanModel, {d, Keyword.put(m, :out_type, out_t)}}
      end

    black_box d.name, sources: sources, model: model do
      domain(:sys)
      if separate, do: domain(:pc, clock: :pc_clk, reset: nil)

      for p <- d.params do
        n = p.shape |> Tuple.to_list() |> Enum.product()
        bits = p.bits * n
        t = if typed and n == 1 and elem(p.type, 0) == :s, do: s(bits), else: u(bits)
        input(String.to_atom(p.port), t, domain: :static)
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

  @doc """
  The AXI4-Stream interface of a wrapped kernel's `:s_axis` or `:m_axis`
  bundle (option `typed:` as in `scan/2`), for the bundles of the module
  that instantiates it.
  """
  def scan_axis(%ExHdl.Backends.SystemVerilog.Scan.Design{} = d, which, opts \\ [])
      when which in [:s_axis, :m_axis] do
    cw = max(1, bit_len(d.channels - 1))
    typed = Keyword.get(opts, :typed, false)

    {fields, width, id} =
      case which do
        :s_axis -> {d.inputs, d.in_width, if(d.tid, do: cw, else: 0)}
        :m_axis -> {d.outputs, d.out_width, if(d.channels > 1, do: cw, else: 0)}
      end

    iface = Interface.axi_stream(data: width, keep: false, last: false, id: id, user: d.tuser)
    t = tdata_type(fields, width, typed)

    Interface.new(
      :axi_stream,
      Enum.map(iface.fields, fn
        {:tdata, _, dir} -> {:tdata, t, dir}
        f -> f
      end)
    )
  end

  # tdata is signed only when it is one signed element filling the word
  defp tdata_type([%{type: {:s, _}, shape: shape, bits: bits}], width, true)
       when bits == width do
    if Tuple.product(shape) == 1, do: s(width), else: u(width)
  end

  defp tdata_type(_fields, width, _typed), do: u(width)

  defp bit_len(0), do: 0
  defp bit_len(v), do: 1 + bit_len(Bitwise.bsr(v, 1))
end
