defmodule ExHdl.Protocol.Field do
  @moduledoc """
  A single header field. `offset` is the bit offset inside the fixed part of
  its layer. `bits` is `:bytes` for the variable-length tail of a layer (IPv4
  options), whose length follows from the layer's `header_length` field.

  `kind` is `:int`, `:flag` (1 bit, decodes to a boolean), `:enum` (decodes
  to the name in `enum` if known) or `:bytes`. `assert` is stored as the raw
  integer.
  """
  defstruct [
    :name,
    :bits,
    :offset,
    signed: false,
    assert: nil,
    kind: :int,
    enum: nil,
    length: nil,
    header_length: nil,
    checksum: nil,
    pseudo: [],
    optional: false,
    match: nil,
    error: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          bits: pos_integer() | :bytes,
          offset: non_neg_integer(),
          signed: boolean(),
          assert: integer() | nil,
          kind: :int | :flag | :enum | :bytes,
          enum: keyword(integer()) | nil,
          length: nil | :total,
          header_length: nil | pos_integer(),
          checksum: nil | :header | :segment,
          pseudo: [atom() | {atom(), atom()}],
          optional: boolean(),
          match: nil | pos_integer(),
          error: term()
        }

  @doc "True for fields whose value the encoder computes (lengths, checksums)."
  def computed?(%__MODULE__{} = f),
    do: f.length != nil or f.header_length != nil or f.checksum != nil
end

defmodule ExHdl.Protocol.Layer do
  @moduledoc """
  One header of a packet chain (Ethernet, a VLAN tag, IPv4, ...).

  `name` is the instance name used in decoded maps and port names, `header`
  the `defheader` it was built from. `fixed_bytes` is the size of the fixed
  part; with a `header_length` field the header is `value * unit` bytes and
  the `:bytes` field `tail` takes the rest. `next` selects the following
  layer from a field value (`{field, [{value, target}]}`, target a layer name
  or `:payload`), `default` applies to unlisted values (`:reject` drops the
  packet). `max` bounds how often the layer may repeat on one packet.
  """
  defstruct [
    :name,
    :header,
    :fields,
    :fixed_bytes,
    hlen_field: nil,
    tail: nil,
    max: 1,
    next: nil,
    default: :reject
  ]

  @type t :: %__MODULE__{}

  def field(%__MODULE__{fields: fields}, name), do: Enum.find(fields, &(&1.name == name))

  @doc "Smallest and largest header size in bytes."
  def size_range(%__MODULE__{hlen_field: nil, fixed_bytes: f}), do: {f, f}

  def size_range(%__MODULE__{} = l) do
    f = field(l, l.hlen_field)
    {l.fixed_bytes, Bitwise.bsl(1, f.bits) * f.header_length - f.header_length}
  end
end

defmodule ExHdl.Protocol.Spec do
  @moduledoc """
  Validated, backend-independent description of a packet layout.

  A packet is a chain of layers (`ExHdl.Protocol.Layer`) followed by the
  payload. A `defpacket` with a single `header do ... end` block is a chain
  of one anonymous layer and decodes to a flat map (`flat: true`).

  Wire format: with `byte_order: :big` every layer is a big-endian bitstream
  (fields may have any bit width, a layer's fixed part is whole bytes). With
  `byte_order: :little` every field must be a whole number of bytes and is
  stored least-significant byte first.

  On AXI4-Stream, byte `k` of the packet travels in beat `div(k, bus_bytes)`,
  lane `rem(k, bus_bytes)` (`tdata[8*lane +: 8]`), as required by the AXI spec.
  """
  alias ExHdl.Protocol.{Field, Layer}

  defstruct [
    :name,
    :bus_width,
    :byte_order,
    :on_mismatch,
    :layers,
    :flat,
    :header_bits,
    :fields,
    :payload
  ]

  @type payload :: %{
          name: atom(),
          bytes: boolean(),
          elem_bits: pos_integer(),
          signed: boolean(),
          complex: boolean()
        }

  @type t :: %__MODULE__{
          name: atom(),
          bus_width: 8 | 16 | 32 | 64,
          byte_order: :big | :little,
          on_mismatch: :drop_packet,
          layers: [Layer.t()],
          flat: boolean(),
          header_bits: pos_integer() | nil,
          fields: [Field.t()] | nil,
          payload: payload()
        }

  @bus_widths [8, 16, 32, 64]

  @doc "Header length in bytes (fixed layouts only)."
  def header_bytes(%__MODULE__{header_bits: h}) when is_integer(h), do: div(h, 8)

  @doc "Header length in bus words, rounded up (fixed layouts only)."
  def header_words(%__MODULE__{bus_width: w} = spec),
    do: div(header_bytes(spec) * 8 + w - 1, w)

  @doc "True if the header has the same size and layout on every packet."
  def fixed?(%__MODULE__{header_bits: h}), do: is_integer(h)

  @doc "Size of one payload element in bytes (both halves for complex types)."
  def payload_elem_bytes(%__MODULE__{payload: %{bytes: true}}), do: 1

  def payload_elem_bytes(%__MODULE__{payload: p}),
    do: div(p.elem_bits, 8) * if(p.complex, do: 2, else: 1)

  def layer(%__MODULE__{layers: layers}, name), do: Enum.find(layers, &(&1.name == name))

  @doc "All fields of all layers as `{layer, field}`."
  def all_fields(%__MODULE__{layers: layers}),
    do: for(l <- layers, f <- l.fields, do: {l, f})

  @doc "The reference used in error tuples: the field name for flat specs, else `{layer, field}`."
  def ref(%__MODULE__{flat: true}, _layer, field), do: field
  def ref(%__MODULE__{}, layer, field), do: {layer, field}

  @doc "True if the hardware parser needs `m_axis_tuser` (length or segment checksum checks)."
  def tuser?(%__MODULE__{} = spec) do
    Enum.any?(all_fields(spec), fn {_, f} -> f.length != nil or f.checksum == :segment end)
  end

  @doc "True if any layer has a total-length field."
  def length_fields?(%__MODULE__{} = spec),
    do: Enum.any?(all_fields(spec), fn {_, f} -> f.length != nil end)

  # -- building ----------------------------------------------------------------

  @doc false
  # `raw_layers` is `[{name, header_name, raw_fields, layer_opts}]`, root first.
  def build!(name, opts, raw_layers, raw_payload, flat?) do
    bus_width = Keyword.get(opts, :bus_width, 32)
    byte_order = Keyword.get(opts, :byte_order, :big)
    on_mismatch = Keyword.get(opts, :on_mismatch, :drop_packet)

    unless bus_width in @bus_widths,
      do:
        fail!(name, "bus_width must be one of #{inspect(@bus_widths)}, got #{inspect(bus_width)}")

    unless byte_order in [:big, :little],
      do: fail!(name, "byte_order must be :big or :little, got #{inspect(byte_order)}")

    unless on_mismatch == :drop_packet,
      do: fail!(name, "only on_mismatch: :drop_packet is supported, got #{inspect(on_mismatch)}")

    if raw_layers == [], do: fail!(name, "declare a header block or at least one layer")
    if raw_payload == nil, do: fail!(name, "a payload declaration is required")

    layers = Enum.map(raw_layers, &build_layer!(name, byte_order, &1))

    dupes = layers |> Enum.frequencies_by(& &1.name) |> Enum.filter(fn {_, n} -> n > 1 end)
    if dupes != [], do: fail!(name, "duplicate layer names: #{inspect(Keyword.keys(dupes))}")

    layers = Enum.map(layers, &resolve_next!(name, &1, layers))

    fixed? = length(layers) == 1 and hd(layers).next == nil and hd(layers).hlen_field == nil

    spec = %__MODULE__{
      name: name,
      bus_width: bus_width,
      byte_order: byte_order,
      on_mismatch: on_mismatch,
      layers: layers,
      flat: flat?,
      header_bits: if(fixed?, do: hd(layers).fixed_bytes * 8),
      fields: if(flat?, do: hd(layers).fields),
      payload: build_payload!(name, raw_payload)
    }

    check_checksums!(spec)
    ExHdl.Protocol.Layout.validate!(spec)
    spec
  end

  defp build_layer!(pkt, byte_order, {lname, header, raw_fields, lopts}) do
    unless is_atom(lname), do: fail!(pkt, "layer name must be an atom, got #{inspect(lname)}")

    if raw_fields == [],
      do: fail!(pkt, "header #{inspect(header)} must declare at least one field")

    {fields, bits} =
      Enum.map_reduce(raw_fields, 0, fn {fname, fbits, fopts}, offset ->
        field = build_field!(pkt, byte_order, fname, fbits, fopts, offset)
        {field, offset + if(fbits == :bytes, do: 0, else: fbits)}
      end)

    dupes = fields |> Enum.frequencies_by(& &1.name) |> Enum.filter(fn {_, n} -> n > 1 end)
    if dupes != [], do: fail!(pkt, "duplicate field names: #{inspect(Keyword.keys(dupes))}")

    if rem(bits, 8) != 0,
      do: fail!(pkt, "header #{inspect(header)} is #{bits} bits, not a whole number of bytes")

    hlen = for f <- fields, f.header_length != nil, do: f
    tails = for f <- fields, f.kind == :bytes, do: f

    if length(hlen) > 1,
      do: fail!(pkt, "header #{inspect(header)}: only one header_length field allowed")

    last = List.last(fields)

    case {hlen, tails} do
      {_, [t | _]} when t != last ->
        fail!(pkt, "field #{inspect(t.name)}: a :bytes field must be the last field")

      {[], [t]} ->
        fail!(pkt, "field #{inspect(t.name)}: a :bytes field needs a header_length field")

      {[h], _} ->
        if div(bits, 8) > (Bitwise.bsl(1, h.bits) - 1) * h.header_length,
          do: fail!(pkt, "field #{inspect(h.name)}: header_length cannot cover the fixed part")

      _ ->
        :ok
    end

    max = Keyword.get(lopts, :max, 1)

    unless is_integer(max) and max >= 1,
      do: fail!(pkt, "layer #{inspect(lname)}: max must be a positive integer")

    %Layer{
      name: lname,
      header: header,
      fields: fields,
      fixed_bytes: div(bits, 8),
      hlen_field: Enum.at(Enum.map(hlen, & &1.name), 0),
      tail: Enum.at(Enum.map(tails, & &1.name), 0),
      max: max,
      next: Keyword.get(lopts, :next),
      default: Keyword.get(lopts, :default, if(Keyword.has_key?(lopts, :next), do: :reject))
    }
  end

  defp resolve_next!(pkt, %Layer{next: nil} = l, _layers) do
    if l.default not in [nil, :reject],
      do: fail!(pkt, "layer #{inspect(l.name)}: default: needs next:")

    %{l | default: :reject}
  end

  defp resolve_next!(pkt, %Layer{next: {fname, cases}} = l, layers) when is_atom(fname) do
    f = Layer.field(l, fname)

    if f == nil or f.kind == :bytes,
      do: fail!(pkt, "layer #{inspect(l.name)}: next: selector #{inspect(fname)} is not a field")

    cases =
      Enum.map(cases, fn {value, target} ->
        v = resolve_value!(pkt, f, value)
        check_target!(pkt, l, target, layers)
        {v, target}
      end)

    vals = Enum.map(cases, &elem(&1, 0))

    if length(Enum.uniq(vals)) != length(vals),
      do: fail!(pkt, "layer #{inspect(l.name)}: next: lists a value twice")

    default = l.default || :reject
    if default != :reject, do: check_target!(pkt, l, default, layers)
    %{l | next: {fname, cases}, default: default}
  end

  defp resolve_next!(pkt, l, _),
    do: fail!(pkt, "layer #{inspect(l.name)}: next: must be {field, [{value, target}]}")

  defp check_target!(_pkt, _l, :payload, _layers), do: :ok

  defp check_target!(pkt, l, target, layers) do
    unless Enum.any?(layers, &(&1.name == target)),
      do: fail!(pkt, "layer #{inspect(l.name)}: next target #{inspect(target)} is not a layer")
  end

  # Values in assert:/next: may be integers, enum names or booleans (flags).
  @doc false
  def resolve_value!(pkt, %Field{} = f, value) do
    v =
      cond do
        f.kind == :flag and is_boolean(value) -> if(value, do: 1, else: 0)
        f.kind == :enum and is_atom(value) and Keyword.has_key?(f.enum, value) -> f.enum[value]
        is_integer(value) -> value
        true -> fail!(pkt, "field #{inspect(f.name)}: unknown value #{inspect(value)}")
      end

    unless fits?(v, f.bits, f.signed),
      do: fail!(pkt, "field #{inspect(f.name)}: value #{inspect(value)} does not fit")

    v
  end

  @field_opts [
    :type,
    :assert,
    :error,
    :match,
    :length,
    :header_length,
    :checksum,
    :pseudo,
    :optional
  ]

  defp build_field!(pkt, _byte_order, fname, :bytes, fopts, offset) do
    unless is_atom(fname), do: fail!(pkt, "field name must be an atom, got #{inspect(fname)}")

    if fopts != [],
      do: fail!(pkt, "field #{inspect(fname)}: a :bytes field takes no options")

    %Field{name: fname, bits: :bytes, offset: offset, kind: :bytes}
  end

  defp build_field!(pkt, byte_order, fname, bits, fopts, offset) do
    unless is_atom(fname), do: fail!(pkt, "field name must be an atom, got #{inspect(fname)}")

    unless is_integer(bits) and bits in 1..64,
      do: fail!(pkt, "field #{inspect(fname)}: width must be 1..64 bits, got #{inspect(bits)}")

    if byte_order == :little and rem(bits, 8) != 0 do
      fail!(
        pkt,
        "field #{inspect(fname)}: byte_order :little requires whole-byte fields, got #{bits} bits"
      )
    end

    case Keyword.keys(fopts) -- @field_opts do
      [] -> :ok
      bad -> fail!(pkt, "field #{inspect(fname)}: unknown options #{inspect(bad)}")
    end

    {kind, signed, enum} =
      case Keyword.get(fopts, :type) do
        nil ->
          {:int, false, nil}

        :flag ->
          if bits != 1, do: fail!(pkt, "field #{inspect(fname)}: type :flag needs 1 bit")
          {:flag, false, nil}

        {:enum, values} when is_list(values) or is_map(values) ->
          values = Enum.to_list(values)

          for {k, v} <- values do
            unless is_atom(k) and fits?(v, bits, false),
              do: fail!(pkt, "field #{inspect(fname)}: bad enum entry #{inspect({k, v})}")
          end

          {:enum, false, values}

        type ->
          {signed, tbits} = parse_int_type!(pkt, type)

          if tbits != bits,
            do:
              fail!(
                pkt,
                "field #{inspect(fname)}: type #{inspect(type)} does not match width #{bits}"
              )

          {:int, signed, nil}
      end

    f = %Field{name: fname, bits: bits, offset: offset, signed: signed, kind: kind, enum: enum}

    assert =
      case Keyword.get(fopts, :assert) do
        nil ->
          nil

        a ->
          v =
            cond do
              kind == :flag and is_boolean(a) -> if(a, do: 1, else: 0)
              kind == :enum and is_atom(a) and Keyword.has_key?(enum, a) -> enum[a]
              true -> a
            end

          unless fits?(v, bits, signed),
            do:
              fail!(
                pkt,
                "field #{inspect(fname)}: assert value #{inspect(a)} does not fit in #{bits} bits"
              )

          v
      end

    length = Keyword.get(fopts, :length)
    hlen = Keyword.get(fopts, :header_length)
    checksum = Keyword.get(fopts, :checksum)
    match = Keyword.get(fopts, :match)

    if length not in [nil, :total],
      do: fail!(pkt, "field #{inspect(fname)}: length: must be :total")

    if hlen != nil and not (is_integer(hlen) and hlen >= 1),
      do: fail!(pkt, "field #{inspect(fname)}: header_length: must be a positive integer")

    if checksum not in [nil, :header, :segment],
      do: fail!(pkt, "field #{inspect(fname)}: checksum: must be :header or :segment")

    if match != nil and not (is_integer(match) and match >= 1),
      do: fail!(pkt, "field #{inspect(fname)}: match: must be the number of table entries")

    special = Enum.count([length, hlen, checksum, assert], &(&1 != nil))

    if special > 1,
      do:
        fail!(
          pkt,
          "field #{inspect(fname)}: assert, length, header_length and checksum exclude each other"
        )

    if (length || hlen || checksum) && (signed or kind != :int),
      do: fail!(pkt, "field #{inspect(fname)}: computed fields must be unsigned integers")

    if length && bits > 16,
      do: fail!(pkt, "field #{inspect(fname)}: length fields are at most 16 bits")

    if checksum && bits != 16,
      do: fail!(pkt, "field #{inspect(fname)}: checksum fields are 16 bits")

    if checksum && byte_order != :big,
      do: fail!(pkt, "field #{inspect(fname)}: checksums need byte_order: :big")

    pseudo = Keyword.get(fopts, :pseudo, [])

    if pseudo != [] and checksum != :segment,
      do: fail!(pkt, "field #{inspect(fname)}: pseudo: needs checksum: :segment")

    %{
      f
      | assert: assert,
        length: length,
        header_length: hlen,
        checksum: checksum,
        pseudo: pseudo,
        optional: Keyword.get(fopts, :optional, false),
        match: match,
        error: Keyword.get(fopts, :error)
    }
  end

  # Pseudo-header references must name fields of other layers or of the own one.
  defp check_checksums!(spec) do
    for {l, f} <- all_fields(spec), f.checksum == :segment, ref <- f.pseudo do
      {lname, fname} = if is_atom(ref), do: {l.name, ref}, else: ref
      other = layer(spec, lname)
      pf = other && Layer.field(other, fname)

      cond do
        pf == nil or pf.kind == :bytes ->
          fail!(spec.name, "field #{inspect(f.name)}: pseudo field #{inspect(ref)} not found")

        lname != l.name and Field.computed?(pf) ->
          fail!(spec.name, "field #{inspect(f.name)}: pseudo field #{inspect(ref)} is computed")

        lname != l.name and other.max != 1 ->
          fail!(spec.name, "field #{inspect(f.name)}: pseudo layer #{inspect(lname)} repeats")

        true ->
          :ok
      end
    end

    :ok
  end

  defp build_payload!(pkt, {pname, popts}) do
    case Keyword.get(popts, :type) do
      :bytes ->
        %{name: pname, bytes: true, elem_bits: 8, signed: false, complex: false}

      nil ->
        fail!(pkt, "payload #{inspect(pname)} needs a :type")

      type ->
        {complex, base} =
          case type do
            {:complex, t} -> {true, t}
            t -> {false, t}
          end

        {signed, bits} = parse_int_type!(pkt, base)
        if rem(bits, 8) != 0, do: fail!(pkt, "payload element type must be whole bytes")
        %{name: pname, bytes: false, elem_bits: bits, signed: signed, complex: complex}
    end
  end

  defp parse_int_type!(pkt, type) when is_atom(type) do
    case Atom.to_string(type) do
      <<sign, rest::binary>> when sign in [?s, ?u] ->
        case Integer.parse(rest) do
          {bits, ""} when bits in 1..64 -> {sign == ?s, bits}
          _ -> fail!(pkt, "unknown type #{inspect(type)}")
        end

      _ ->
        fail!(pkt, "unknown type #{inspect(type)}")
    end
  end

  defp parse_int_type!(pkt, type), do: fail!(pkt, "unknown type #{inspect(type)}")

  @doc false
  def fits?(v, bits, false) when is_integer(v), do: v >= 0 and v < Bitwise.bsl(1, bits)

  def fits?(v, bits, true) when is_integer(v),
    do: v >= -Bitwise.bsl(1, bits - 1) and v < Bitwise.bsl(1, bits - 1)

  def fits?(_, _, _), do: false

  @doc false
  def fail!(pkt, msg), do: raise(ArgumentError, "defpacket #{inspect(pkt)}: #{msg}")
end
