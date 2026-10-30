defmodule ExHdl.Protocol do
  @moduledoc """
  DSL for packet layouts that compile to both BEAM binary codecs and AXI4-Stream
  hardware.

  A packet with one fixed header:

      defmodule MySDR.Protocol do
        use ExHdl.Protocol

        defpacket :iq_frame, bus_width: 32, byte_order: :little do
          header on_mismatch: :drop_packet do
            <<
              magic::16 - assert(0x55AA),
              channel_id::8 - type(:u8),
              gain_q15::16 - type(:s16),
              ...
            >>
          end

          payload :stream, type: {:complex, :s16}
        end
      end

  A chain of headers, where the next layer follows from a field value (in the
  style of a P4 parser):

      defheader :eth do
        <<
          dst::48,
          src::48,
          ethertype::16 - type({:enum, vlan: 0x8100, qinq: 0x88A8, ipv4: 0x0800})
        >>
      end

      defheader :vlan do
        <<
          pcp::3,
          dei::1 - flag,
          vid::12,
          ethertype::16 - type({:enum, vlan: 0x8100, ipv4: 0x0800})
        >>
      end

      defheader :ipv4 do
        <<
          version::4,
          ihl::4,
          dscp_ecn::8,
          total_length::16,
          id::16,
          flags::3,
          frag_offset::13,
          ttl::8,
          protocol::8,
          checksum::16,
          src::32,
          dst::32,
          options::bytes
        >>
        when version == 4 and
             error(version, :not_ipv4) and
             header_length(ihl, 4) and
             length(total_length, :total) and
             header_checksum(checksum)
      end

      defheader :udp do
        <<
          src_port::16,
          dst_port::16,
          length::16,
          checksum::16
        >>
        when hw_match(dst_port, 4) and
             length(length, :total) and
             segment_checksum(checksum,
               optional: true,
               pseudo: [{:ipv4, :src}, {:ipv4, :dst}, {:ipv4, :protocol}, :length]
             )
      end

      defpacket :udp_rx, bus_width: 64 do
        layer :eth, next: {:ethertype, vlan: :vlan, qinq: :vlan, ipv4: :ipv4}
        layer :vlan, max: 2, next: {:ethertype, vlan: :vlan, ipv4: :ipv4}
        layer :ipv4, next: {:protocol, %{17 => :udp}}
        layer :udp
        payload :data, type: :bytes
      end

  Headers can also be declared using the legacy macro syntax:
  `field :dst, 48`, `field :ethertype, 16, type: {:enum, ...}`.

  ## Fields & Bitstring Syntax

  Fields can be declared with native Elixir bitstrings (`<<...>>`) or `field/2,3`.
  Bitstring modifiers map directly to field options:

    * `name::bits` - unsigned integer of `bits` width
    * `name::signed-bits` or `name::bits - signed` - signed integer
    * `name::bits - flag` or `name::bits - type(:flag)` - 1-bit boolean flag
    * `name::bits - type({:enum, name: value, ...})` - enum
    * `name::bits - assert(value)` or `(name = value)::bits` or `name::bits - value`
    * `name::bits - error(reason)` - custom error reason on mismatch
    * `name::bits - match(n)` - runtime match table with `n` entries
    * `name::bits - length(:total)` - layer total length
    * `name::bits - header_length(unit)` - variable header multiplier
    * `name::bits - checksum(:header)` - RFC 1071 header checksum
    * `name::bits - checksum(:segment, optional: true, pseudo: [...])` - UDP segment checksum
    * `name::bytes` or `name::binary` - variable-length tail

  ## Layers

  `defheader name do ... end` declares a reusable header, `layer name, opts`
  places it in a packet (`header: other` or `header: {Module, other}` to use
  a header under another name). Options: `next: {field, cases}` with cases a
  map or keyword list from field values (or enum names) to the next layer or
  `:payload`, `default:` the target of unlisted values (default `:reject`),
  `max:` how often the layer may repeat. A layer without `next:` is followed
  by the payload. The first layer is the root.

  ## Generated functions

  For every packet `name` the module gets:

    * `name/0` - the validated `ExHdl.Protocol.Spec`
    * `encode_name/2` - `(header :: map | keyword, payload) -> binary`.
      Asserted fields default to their asserted value, computed fields are
      computed unless given, selector fields default to the value that leads
      to the next layer present in the map.
    * `decode_name/1,2` - `binary -> {:ok, header, payload} | {:error, reason}`
    * `decode_name_header/1,2` - `binary -> {:ok, header, rest} | {:error, reason}`,
      the header chain only, `rest` the bytes after it
    * `__ex_hdl_packets__/0`, `__ex_hdl_headers__/0`

  Header maps are flat for a single `header` block. For layer chains they
  map each layer to its field map, repeated layers (`max: n > 1`) to a list,
  absent single layers are missing. Payloads are lists of integers (or
  `{i, q}` for complex types), or binaries with `type: :bytes`. See
  `ExHdl.Protocol.Codec` for the decode rules and error tuples, and
  `ExHdl.Backends.SystemVerilog.Protocol` for the hardware.
  """

  alias ExHdl.Protocol.{Bitstring, Spec}

  defmacro __using__(_opts) do
    quote do
      import ExHdl.Protocol, only: [defpacket: 2, defpacket: 3, defheader: 2]
      Module.register_attribute(__MODULE__, :ex_hdl_packets, accumulate: true)
      Module.register_attribute(__MODULE__, :ex_hdl_headers, accumulate: true)
      @before_compile ExHdl.Protocol
    end
  end

  defmacro defpacket(name, opts \\ [], do: block) do
    transformed_block = Bitstring.transform_packet_block(block)

    quote do
      ExHdl.Protocol.Builder.start(__MODULE__, unquote(name), unquote(opts))
      import ExHdl.Protocol.DSL
      unquote(transformed_block)
      import ExHdl.Protocol.DSL, only: []
      ExHdl.Protocol.Builder.finish(__MODULE__)
    end
  end

  defmacro defheader(name, do: block) do
    transformed_block = Bitstring.transform_ast(block)

    quote do
      ExHdl.Protocol.Builder.start_header(__MODULE__, unquote(name))
      import ExHdl.Protocol.DSL, only: [field: 2, field: 3]
      unquote(transformed_block)
      import ExHdl.Protocol.DSL, only: []
      ExHdl.Protocol.Builder.finish_header(__MODULE__)
    end
  end

  defmacro __before_compile__(env) do
    specs = env.module |> Module.get_attribute(:ex_hdl_packets) |> Enum.reverse()
    headers = env.module |> Module.get_attribute(:ex_hdl_headers) |> Enum.reverse()

    defs = Enum.map(specs, &packet_functions/1)

    quote do
      @doc false
      def __ex_hdl_packets__, do: unquote(Macro.escape(specs))
      @doc false
      def __ex_hdl_headers__, do: unquote(Macro.escape(headers))
      unquote_splicing(defs)
    end
  end

  defp packet_functions(%Spec{} = spec) do
    name = spec.name
    encode = :"encode_#{name}"
    decode = :"decode_#{name}"
    decode_header = :"decode_#{name}_header"

    quote do
      @doc "Returns the `ExHdl.Protocol.Spec` for `#{unquote(inspect(name))}`."
      def unquote(name)(), do: unquote(Macro.escape(spec))

      @doc "Encodes a `#{unquote(inspect(name))}` packet."
      def unquote(encode)(header, payload),
        do: ExHdl.Protocol.Codec.encode(unquote(name)(), header, payload)

      @doc "Decodes a `#{unquote(inspect(name))}` packet (options: `match:`)."
      def unquote(decode)(bin, opts \\ []) when is_binary(bin),
        do: ExHdl.Protocol.Codec.decode(unquote(name)(), bin, opts)

      @doc "Decodes the headers of a `#{unquote(inspect(name))}` packet, returning the rest as a binary."
      def unquote(decode_header)(bin, opts \\ []) when is_binary(bin),
        do: ExHdl.Protocol.Codec.decode_header(unquote(name)(), bin, opts)
    end
  end
end

defmodule ExHdl.Protocol.DSL do
  @moduledoc false
  alias ExHdl.Protocol.Bitstring

  defmacro header(opts \\ [], do: block) do
    transformed_block = Bitstring.transform_ast(block)

    quote do
      ExHdl.Protocol.Builder.header(__MODULE__, unquote(opts))
      unquote(transformed_block)
    end
  end

  defmacro field(name, bits, opts \\ []) do
    quote do
      ExHdl.Protocol.Builder.field(__MODULE__, unquote(name), unquote(bits), unquote(opts))
    end
  end

  defmacro layer(name, opts \\ []) do
    quote do
      ExHdl.Protocol.Builder.layer(__MODULE__, unquote(name), unquote(opts))
    end
  end

  defmacro payload(name, opts) do
    quote do
      ExHdl.Protocol.Builder.payload(__MODULE__, unquote(name), unquote(opts))
    end
  end
end

defmodule ExHdl.Protocol.Builder do
  @moduledoc false
  # Collects DSL calls in a module attribute while the user module is compiled.

  @attr :ex_hdl_pkt_wip

  def start(mod, name, opts) do
    if Module.get_attribute(mod, @attr), do: raise(ArgumentError, "defpacket cannot be nested")
    unless is_atom(name), do: raise(ArgumentError, "defpacket name must be an atom")

    Module.put_attribute(mod, @attr, %{
      kind: :packet,
      name: name,
      opts: opts,
      header: nil,
      fields: [],
      layers: [],
      payload: nil
    })
  end

  def start_header(mod, name) do
    if Module.get_attribute(mod, @attr), do: raise(ArgumentError, "defheader cannot be nested")
    unless is_atom(name), do: raise(ArgumentError, "defheader name must be an atom")
    Module.put_attribute(mod, @attr, %{kind: :header, name: name, fields: []})
  end

  def header(mod, opts) do
    update(mod, fn wip ->
      if wip.header || wip.layers != [],
        do: raise(ArgumentError, "defpacket #{inspect(wip.name)}: use one header block or layers")

      %{wip | header: opts}
    end)
  end

  def field(mod, name, bits, opts),
    do: update(mod, &%{&1 | fields: [{name, bits, opts} | &1.fields]})

  def layer(mod, name, opts) do
    update(mod, fn wip ->
      if wip.header,
        do: raise(ArgumentError, "defpacket #{inspect(wip.name)}: use one header block or layers")

      %{wip | layers: [{name, opts} | wip.layers]}
    end)
  end

  def payload(mod, name, opts) do
    update(mod, fn wip ->
      if wip.payload,
        do: raise(ArgumentError, "defpacket #{inspect(wip.name)}: only one payload allowed")

      %{wip | payload: {name, opts}}
    end)
  end

  def finish_header(mod) do
    wip = Module.get_attribute(mod, @attr)
    Module.delete_attribute(mod, @attr)
    Module.put_attribute(mod, :ex_hdl_headers, {wip.name, Enum.reverse(wip.fields)})
  end

  def finish(mod) do
    wip = Module.get_attribute(mod, @attr)
    Module.delete_attribute(mod, @attr)

    {raw_layers, opts, flat?} =
      if wip.layers == [] do
        if wip.fields != [] or wip.header do
          opts = Keyword.merge(wip.opts, Keyword.take(wip.header || [], [:on_mismatch]))
          {[{:header, :header, Enum.reverse(wip.fields), []}], opts, true}
        else
          {[], wip.opts, true}
        end
      else
        if wip.fields != [],
          do: raise(ArgumentError, "defpacket #{inspect(wip.name)}: fields belong in defheader")

        layers =
          wip.layers
          |> Enum.reverse()
          |> Enum.map(fn {lname, lopts} ->
            {hname, fields} = lookup_header!(mod, wip.name, Keyword.get(lopts, :header, lname))
            {lname, hname, fields, Keyword.delete(lopts, :header)}
          end)

        {layers, wip.opts, false}
      end

    spec = ExHdl.Protocol.Spec.build!(wip.name, opts, raw_layers, wip.payload, flat?)
    Module.put_attribute(mod, :ex_hdl_packets, spec)
  end

  defp lookup_header!(_mod, pkt, {other, hname}) do
    Code.ensure_compiled!(other)

    case List.keyfind(other.__ex_hdl_headers__(), hname, 0) do
      nil ->
        raise ArgumentError,
              "defpacket #{inspect(pkt)}: #{inspect(other)} has no header #{inspect(hname)}"

      found ->
        found
    end
  end

  defp lookup_header!(mod, pkt, hname) do
    case List.keyfind(Module.get_attribute(mod, :ex_hdl_headers), hname, 0) do
      nil -> raise ArgumentError, "defpacket #{inspect(pkt)}: unknown header #{inspect(hname)}"
      found -> found
    end
  end

  defp update(mod, fun) do
    case Module.get_attribute(mod, @attr) do
      nil -> raise ArgumentError, "header/field/layer/payload must be used inside defpacket"
      wip -> Module.put_attribute(mod, @attr, fun.(wip))
    end
  end
end

defmodule ExHdl.Protocol.Runtime do
  @moduledoc false
  alias ExHdl.Protocol.Spec

  def fetch_field!(header, pkt, name, bits, signed, assert) do
    value =
      case Map.fetch(header, name) do
        {:ok, v} -> v
        :error when assert != nil -> assert
        :error -> raise ArgumentError, "#{inspect(pkt)}: missing header field #{inspect(name)}"
      end

    check_value!(pkt, name, value, bits, signed)
  end

  def check_value!(pkt, name, value, bits, signed) do
    if Spec.fits?(value, bits, signed) do
      value
    else
      kind = if signed, do: "signed", else: "unsigned"

      raise ArgumentError,
            "#{inspect(pkt)}: #{inspect(name)} = #{inspect(value)} does not fit #{kind} #{bits} bits"
    end
  end

  def check_assert(_name, value, value), do: :ok
  def check_assert(name, value, _expected), do: {:error, {:assert_failed, name, value}}
end
