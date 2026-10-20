defmodule ExHdl.RTL.Interface do
  @moduledoc """
  Interface bundles: named groups of signals with directions.

  An interface is a list of fields `{name, type, :fwd | :bwd}` seen from
  the master: `:fwd` fields flow master to slave (`tdata`, `tvalid`),
  `:bwd` fields slave to master (`tready`). Inside a module:

      axis = Interface.axi_stream(data: 64, user: 4)
      s = slave(:s_axis, axis)     # s_axis_tdata input, s_axis_tready output, ...
      m = master(:m_axis, axis)    # m_axis_tdata output, m_axis_tready input, ...
      connect(s, m)                # m.tdata <~ s.tdata, ..., s.tready <~ m.tready

  A bundle is a map of field handles (`s.tdata`, `s.tvalid`) plus
  `:__bundle__`. Instance ports of a child declared as a bundle come back
  as bundles too (`u.m_axis`). `connect(source, sink)` assigns every
  `:fwd` field of `sink` from `source` and every `:bwd` field of `source`
  from `sink`; both must have the same interface.

  Port names are `<prefix>_<field>`.
  """
  alias ExHdl.RTL.{Builder, ElaborationError}

  defstruct [:name, :fields]

  @type field :: {atom(), ExHdl.RTL.Expr.type(), :fwd | :bwd}
  @type t :: %__MODULE__{name: atom(), fields: [field()]}

  @doc "A custom interface from `{name, type, :fwd | :bwd}` fields."
  def new(name, fields) do
    for f <- fields do
      unless match?({n, _, d} when is_atom(n) and d in [:fwd, :bwd], f),
        do:
          raise(
            ArgumentError,
            "interface field must be {name, type, :fwd | :bwd}, got #{inspect(f)}"
          )
    end

    %__MODULE__{
      name: name,
      fields: Enum.map(fields, fn {n, t, d} -> {n, ExHdl.RTL.Expr.type!(t), d} end)
    }
  end

  @doc """
  AXI4-Stream. Options: `data:` tdata bits (default 32), `keep:` (default
  true when `data` is a multiple of `keep_unit`), `keep_unit:` data bits
  per `tkeep` bit (default 8; 32 for the DWord keeps of the PCIe streams),
  `strb:` (false, one bit per byte), `last:` (true), `id:`, `dest:`,
  `user:` bits (0 = absent), `ready:` (true).
  """
  def axi_stream(opts \\ []) do
    data = Keyword.get(opts, :data, 32)
    bytes = div(data + 7, 8)
    unit = Keyword.get(opts, :keep_unit, 8)

    unless is_integer(unit) and unit >= 1,
      do:
        raise(ArgumentError, "keep_unit must be a positive number of bits, got #{inspect(unit)}")

    keep = Keyword.get(opts, :keep, rem(data, unit) == 0)

    fields =
      [{:tdata, data, :fwd}] ++
        opt(keep, {:tkeep, div(data + unit - 1, unit), :fwd}) ++
        opt(Keyword.get(opts, :strb, false), {:tstrb, bytes, :fwd}) ++
        opt(Keyword.get(opts, :last, true), {:tlast, 1, :fwd}) ++
        bits(opts, :id, :tid) ++
        bits(opts, :dest, :tdest) ++
        bits(opts, :user, :tuser) ++
        [{:tvalid, 1, :fwd}] ++ opt(Keyword.get(opts, :ready, true), {:tready, 1, :bwd})

    new(:axi_stream, fields)
  end

  @doc "AXI4-Lite with `addr:` (default 32) and `data:` (32 or 64) bits."
  def axi_lite(opts \\ []) do
    a = Keyword.get(opts, :addr, 32)
    d = Keyword.get(opts, :data, 32)

    new(:axi_lite, [
      {:awaddr, a, :fwd},
      {:awprot, 3, :fwd},
      {:awvalid, 1, :fwd},
      {:awready, 1, :bwd},
      {:wdata, d, :fwd},
      {:wstrb, div(d, 8), :fwd},
      {:wvalid, 1, :fwd},
      {:wready, 1, :bwd},
      {:bresp, 2, :bwd},
      {:bvalid, 1, :bwd},
      {:bready, 1, :fwd},
      {:araddr, a, :fwd},
      {:arprot, 3, :fwd},
      {:arvalid, 1, :fwd},
      {:arready, 1, :bwd},
      {:rdata, d, :bwd},
      {:rresp, 2, :bwd},
      {:rvalid, 1, :bwd},
      {:rready, 1, :fwd}
    ])
  end

  @doc """
  A simple synchronous memory port: `en`, `we`, `addr`, `wdata` (and `be`
  with `be: true`, one bit per byte) from master to memory, `rdata` back.
  Options `addr:` and `data:` (bits, required).
  """
  def mem_port(opts) do
    a = Keyword.fetch!(opts, :addr)
    d = Keyword.fetch!(opts, :data)

    new(
      :mem_port,
      [{:en, 1, :fwd}, {:we, 1, :fwd}, {:addr, a, :fwd}, {:wdata, d, :fwd}] ++
        opt(Keyword.get(opts, :be, false), {:be, div(d + 7, 8), :fwd}) ++ [{:rdata, d, :bwd}]
    )
  end

  @doc "Swaps `:fwd` and `:bwd`."
  def flip(%__MODULE__{} = i),
    do: %{
      i
      | fields:
          Enum.map(i.fields, fn {n, t, d} -> {n, t, if(d == :fwd, do: :bwd, else: :fwd)} end)
    }

  defp opt(true, f), do: [f]
  defp opt(false, _), do: []

  defp bits(opts, key, name) do
    case Keyword.get(opts, key, 0) do
      0 -> []
      w -> [{name, w, :fwd}]
    end
  end

  # -- bundles ---------------------------------------------------------------------------

  @doc false
  def declare(prefix, %__MODULE__{} = iface, role, opts) do
    prefix = Builder.name!(prefix)

    fields =
      for {f, t, d} <- iface.fields, into: %{} do
        name = :"#{prefix}_#{f}"

        h =
          case {role, d} do
            {:wire, _} -> Builder.wire(name, t, opts)
            {:master, :fwd} -> Builder.output(name, t, opts)
            {:master, :bwd} -> Builder.input(name, t, opts)
            {:slave, :fwd} -> Builder.input(name, t, opts)
            {:slave, :bwd} -> Builder.output(name, t, opts)
          end

        {f, h}
      end

    if role != :wire, do: Builder.add_bundle(%{name: prefix, iface: iface, role: role})
    Map.put(fields, :__bundle__, iface)
  end

  @doc false
  def connect(%{__bundle__: a} = source, %{__bundle__: b} = sink) do
    if a.fields != b.fields do
      raise ElaborationError,
            "connect: interfaces differ (#{describe(a)} vs #{describe(b)})"
    end

    for {f, _, d} <- a.fields do
      case d do
        :fwd -> Builder.assign(sink[f], source[f])
        :bwd -> Builder.assign(source[f], sink[f])
      end
    end

    nil
  end

  def connect(a, b),
    do:
      raise(ElaborationError, "connect expects two bundles, got #{inspect(a)} and #{inspect(b)}")

  defp describe(i),
    do:
      Enum.map_join(i.fields, " ", fn {n, {s, w}, d} ->
        "#{n}:#{s}#{w}#{if d == :bwd, do: "<", else: ""}"
      end)
end
