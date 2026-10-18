defmodule ExHdl.Protocol.Field do
  @moduledoc "A single header field. `offset` is the bit offset inside the header bitstream."
  defstruct [:name, :bits, :offset, :signed, :assert]

  @type t :: %__MODULE__{
          name: atom(),
          bits: pos_integer(),
          offset: non_neg_integer(),
          signed: boolean(),
          assert: integer() | nil
        }
end

defmodule ExHdl.Protocol.Spec do
  @moduledoc """
  Validated, backend-independent description of a packet layout.

  Wire format: the header is a sequence of fields followed by the payload. With
  `byte_order: :big` the header is one big-endian bitstream (fields may have any
  bit width). With `byte_order: :little` every field must be a whole number of
  bytes and is stored least-significant byte first.

  On AXI4-Stream, byte `k` of the packet travels in beat `div(k, bus_bytes)`,
  lane `rem(k, bus_bytes)` (`tdata[8*lane +: 8]`), as required by the AXI spec.
  """
  alias ExHdl.Protocol.Field

  defstruct [
    :name,
    :bus_width,
    :byte_order,
    :on_mismatch,
    :header_bits,
    :fields,
    :payload
  ]

  @type payload :: %{
          name: atom(),
          elem_bits: pos_integer(),
          signed: boolean(),
          complex: boolean()
        }

  @type t :: %__MODULE__{
          name: atom(),
          bus_width: 8 | 16 | 32 | 64,
          byte_order: :big | :little,
          on_mismatch: :drop_packet,
          header_bits: pos_integer(),
          fields: [Field.t()],
          payload: payload()
        }

  @bus_widths [8, 16, 32, 64]

  @doc "Header length in bus words."
  def header_words(%__MODULE__{header_bits: h, bus_width: w}), do: div(h, w)

  @doc "Header length in bytes."
  def header_bytes(%__MODULE__{header_bits: h}), do: div(h, 8)

  @doc "Size of one payload element in bytes (both halves for complex types)."
  def payload_elem_bytes(%__MODULE__{payload: p}),
    do: div(p.elem_bits, 8) * if(p.complex, do: 2, else: 1)

  @doc false
  # Builds and validates a spec from the raw data collected by the DSL.
  def build!(name, opts, header_opts, raw_fields, raw_payload) do
    bus_width = Keyword.get(opts, :bus_width, 32)
    byte_order = Keyword.get(opts, :byte_order, :big)
    on_mismatch = Keyword.get(header_opts || [], :on_mismatch, :drop_packet)

    unless bus_width in @bus_widths,
      do:
        fail!(name, "bus_width must be one of #{inspect(@bus_widths)}, got #{inspect(bus_width)}")

    unless byte_order in [:big, :little],
      do: fail!(name, "byte_order must be :big or :little, got #{inspect(byte_order)}")

    unless on_mismatch == :drop_packet,
      do: fail!(name, "only on_mismatch: :drop_packet is supported, got #{inspect(on_mismatch)}")

    if raw_fields == [], do: fail!(name, "header must declare at least one field")
    if raw_payload == nil, do: fail!(name, "a payload declaration is required")

    {fields, header_bits} =
      Enum.map_reduce(raw_fields, 0, fn {fname, bits, fopts}, offset ->
        field = build_field!(name, byte_order, fname, bits, fopts, offset)
        {field, offset + bits}
      end)

    dupes = fields |> Enum.frequencies_by(& &1.name) |> Enum.filter(fn {_, n} -> n > 1 end)
    if dupes != [], do: fail!(name, "duplicate field names: #{inspect(Keyword.keys(dupes))}")

    if rem(header_bits, bus_width) != 0 do
      fail!(
        name,
        "header is #{header_bits} bits, which is not a multiple of bus_width #{bus_width}; " <>
          "pad the header so the payload starts on a bus word"
      )
    end

    %__MODULE__{
      name: name,
      bus_width: bus_width,
      byte_order: byte_order,
      on_mismatch: on_mismatch,
      header_bits: header_bits,
      fields: fields,
      payload: build_payload!(name, raw_payload)
    }
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

    signed =
      case Keyword.get(fopts, :type) do
        nil ->
          false

        type ->
          {signed, tbits} = parse_int_type!(pkt, type)

          if tbits != bits,
            do:
              fail!(
                pkt,
                "field #{inspect(fname)}: type #{inspect(type)} does not match width #{bits}"
              )

          signed
      end

    assert = Keyword.get(fopts, :assert)

    if assert != nil and not fits?(assert, bits, signed) do
      fail!(
        pkt,
        "field #{inspect(fname)}: assert value #{inspect(assert)} does not fit in #{bits} bits"
      )
    end

    %Field{name: fname, bits: bits, offset: offset, signed: signed, assert: assert}
  end

  defp build_payload!(pkt, {pname, popts}) do
    {complex, base} =
      case Keyword.get(popts, :type) do
        {:complex, t} -> {true, t}
        nil -> fail!(pkt, "payload #{inspect(pname)} needs a :type")
        t -> {false, t}
      end

    {signed, bits} = parse_int_type!(pkt, base)
    if rem(bits, 8) != 0, do: fail!(pkt, "payload element type must be whole bytes")
    %{name: pname, elem_bits: bits, signed: signed, complex: complex}
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

  defp fail!(pkt, msg), do: raise(ArgumentError, "defpacket #{inspect(pkt)}: #{msg}")
end
