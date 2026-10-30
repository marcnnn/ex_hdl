defmodule ExHdl.Protocol do
  @moduledoc """
  DSL for packet layouts that compile to both BEAM binary codecs and AXI4-Stream
  hardware.

  Headers are written as plain Elixir binary patterns, the same ones a BEAM
  parser would use in a function head, so patterns can be copied from and to
  existing code. What a pattern cannot express (enums, checksums, lengths,
  match tables) is given per field next to it.

  A packet with one fixed header:

      defmodule MySDR.Protocol do
        use ExHdl.Protocol

        defpacket :iq_frame, bus_width: 32, byte_order: :little do
          header <<magic::16-little, channel_id::8, gain_q15::16-little-signed,
                   seq_num::16-little, timestamp::64-little>>
                 when magic == 0x55AA,
                 on_mismatch: :drop_packet

          payload :stream, type: {:complex, :s16}
        end
      end

  A chain of headers, where the next layer follows from a field value (in the
  style of a P4 parser):

      defheader :eth, <<dst::48, src::48, ethertype::16>>,
        ethertype: [type: {:enum, vlan: 0x8100, qinq: 0x88A8, ipv4: 0x0800}]

      defheader :vlan, <<pcp::3, dei::1, vid::12, ethertype::16>>,
        dei: [type: :flag],
        ethertype: [type: {:enum, vlan: 0x8100, ipv4: 0x0800}]

      defheader :ipv4,
        <<version::4, ihl::4, dscp_ecn::8, total_length::16, id::16, flags_frag::16,
          ttl::8, protocol::8, checksum::16, src::32, dst::32,
          options::binary-size(ihl * 4 - 20)>>
        when version == 4,
        version: [error: :not_ipv4],
        total_length: [length: :total],
        checksum: [checksum: :header]

      defheader :udp, <<src_port::16, dst_port::16, length::16, checksum::16>>,
        dst_port: [match: 4],
        length: [length: :total],
        checksum: [checksum: :segment, optional: true,
                   pseudo: [{:ipv4, :src}, {:ipv4, :dst}, {:ipv4, :protocol}, :length]]

      defpacket :udp_rx, bus_width: 64 do
        layer :eth, next: {:ethertype, vlan: :vlan, qinq: :vlan, ipv4: :ipv4}
        layer :vlan, max: 2, next: {:ethertype, vlan: :vlan, ipv4: :ipv4}
        layer :ipv4, next: {:protocol, %{17 => :udp}}
        layer :udp
        payload :data, type: :bytes
      end

  ## Patterns

  `ExHdl.Protocol.Bitstring` has the details. In short: `name::N` is an
  unsigned field, `signed` makes it signed, `big` / `little` must agree with
  the packet's `byte_order`, `name::binary-size(field * unit - fixed)` is the
  variable tail of a header (IPv4 options, `field` gets `header_length: unit`),
  a trailing unsized `rest::binary` is ignored, and guards `field == value`
  become asserts.

  Every `defheader name, pattern` also defines `match_name/1`, the pattern as
  an ordinary function head: `binary -> {:ok, fields, rest} | :error` with raw
  integer fields.

  ## Field options

  Given as `field: [opts]` after the pattern (or as `field name, bits, opts`
  in the older `do` block form, which takes `type: :uN | :sN` and `assert:`
  too):

    * `type:` - `:flag` (1 bit, a boolean) or `{:enum, name: value, ...}`
      (decodes to the name if known, encodes names or integers)
    * `error: reason` - decode returns `{:error, reason}` when this field's
      assert fails, instead of the default tuple
    * `match: n` - compared at run time against a table: in hardware `n`
      entries from input ports, on the BEAM the `match:` decode option
    * `length: :total` - bytes from the start of this layer to the end of the
      packet; computed on encode, checked on decode, and the packet is cut
      there (Ethernet padding is dropped)
    * `header_length: unit` - the layer's header is `value * unit` bytes; the
      last field (`:bytes`) holds the bytes past the fixed part
    * `checksum: :header` - RFC 1071 checksum over this layer's header
    * `checksum: :segment` - checksum over `pseudo:` fields (each zero-extended
      to 16-bit words), this layer and the payload; `optional: true` means a
      transmitted 0 is not checked and a computed 0 is sent as `0xFFFF` (UDP)

  ## Layers

  `defheader` declares a reusable header, `layer name, opts`
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
      import ExHdl.Protocol, only: [defpacket: 2, defpacket: 3, defheader: 2, defheader: 3]
      Module.register_attribute(__MODULE__, :ex_hdl_packets, accumulate: true)
      Module.register_attribute(__MODULE__, :ex_hdl_headers, accumulate: true)
      @before_compile ExHdl.Protocol
    end
  end

  defmacro defpacket(name, opts \\ [], do: block) do
    quote do
      ExHdl.Protocol.Builder.start(__MODULE__, unquote(name), unquote(opts))
      import ExHdl.Protocol.DSL
      unquote(block)
      import ExHdl.Protocol.DSL, only: []
      ExHdl.Protocol.Builder.finish(__MODULE__)
    end
  end

  defmacro defheader(name, pattern_or_block, field_opts \\ [])

  defmacro defheader(name, [do: block], []) do
    quote do
      ExHdl.Protocol.Builder.start_header(__MODULE__, unquote(name))
      import ExHdl.Protocol.DSL, only: [field: 2, field: 3]
      unquote(block)
      import ExHdl.Protocol.DSL, only: []
      ExHdl.Protocol.Builder.finish_header(__MODULE__)
    end
  end

  defmacro defheader(name, pattern, field_opts) do
    {fields, rest_var} = Bitstring.to_fields(pattern, field_opts)

    quote do
      ExHdl.Protocol.Builder.start_header(__MODULE__, unquote(name))
      unquote_splicing(field_calls(fields))
      ExHdl.Protocol.Builder.finish_header(__MODULE__)
      unquote(match_function(name, pattern, fields, rest_var))
    end
  end

  @doc false
  def field_calls(fields) do
    for {name, bits, opts} <- fields do
      quote do
        ExHdl.Protocol.Builder.field(__MODULE__, unquote(name), unquote(bits), unquote(opts))
      end
    end
  end

  # The pattern itself as a function head, so the BEAM compiler checks it and
  # plain code can use it.
  defp match_function(name, pattern, fields, rest_var) when is_atom(name) do
    {{:<<>>, meta, segments}, guard} = Bitstring.split_guard(pattern)
    fun = :"match_#{name}"
    rest = Macro.unique_var(:rest, __MODULE__)

    segments =
      if rest_var do
        {:"::", m, [_var, spec]} = List.last(segments)
        Enum.drop(segments, -1) ++ [{:"::", m, [rest, spec]}]
      else
        segments ++ [quote(do: unquote(rest) :: bitstring)]
      end

    call = {fun, [], [{:<<>>, meta, segments}]}
    head = if guard, do: {:when, [], [call, guard]}, else: call
    vars = Map.new(segments, &segment_var/1)
    map = {:%{}, [], for({f, _, _} <- fields, do: {f, Map.fetch!(vars, f)})}

    quote do
      @doc "Matches the `#{unquote(inspect(name))}` header pattern: `{:ok, fields, rest}` or `:error`."
      def unquote(head), do: {:ok, unquote(map), unquote(rest)}
      def unquote(fun)(bin) when is_bitstring(bin), do: :error
    end
  end

  defp segment_var({:"::", _, [{n, _, _} = var, _]}), do: {n, var}
  defp segment_var({n, _, _} = var), do: {n, var}

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

  # header opts do field ... end, or header pattern, [on_mismatch: ...] ++ field options
  defmacro header(pattern_or_opts, opts \\ [])

  defmacro header([do: block], []) do
    quote do
      ExHdl.Protocol.Builder.header(__MODULE__, [])
      unquote(block)
    end
  end

  defmacro header(opts, do: block) do
    quote do
      ExHdl.Protocol.Builder.header(__MODULE__, unquote(opts))
      unquote(block)
    end
  end

  defmacro header(pattern, opts) do
    {header_opts, field_opts} = Keyword.split(opts, [:on_mismatch])
    {fields, _rest_var} = ExHdl.Protocol.Bitstring.to_fields(pattern, field_opts)

    quote do
      ExHdl.Protocol.Builder.header(__MODULE__, unquote(header_opts))
      unquote_splicing(ExHdl.Protocol.field_calls(fields))
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

    byte_order = Keyword.get(opts, :byte_order, :big)

    raw_layers =
      for {lname, hname, fields, lopts} <- raw_layers,
          do: {lname, hname, check_endian!(wip.name, byte_order, fields), lopts}

    spec = ExHdl.Protocol.Spec.build!(wip.name, opts, raw_layers, wip.payload, flat?)
    Module.put_attribute(mod, :ex_hdl_packets, spec)
  end

  # Pattern fields carry the endianness written in the pattern; it has to be
  # the packet's byte order (single bytes and below have none).
  defp check_endian!(pkt, byte_order, fields) do
    for {name, bits, opts} <- fields do
      {endian, opts} = Keyword.pop(opts, :endian)

      if endian && endian != byte_order && is_integer(bits) && bits > 8 do
        raise ArgumentError,
              "defpacket #{inspect(pkt)}: field #{inspect(name)} is #{endian}-endian in the " <>
                "pattern but the packet has byte_order: #{inspect(byte_order)}"
      end

      {name, bits, opts}
    end
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
