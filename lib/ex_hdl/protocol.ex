defmodule ExHdl.Protocol do
  @moduledoc """
  DSL for packet layouts that compile to both BEAM binary codecs and AXI4-Stream
  hardware.

      defmodule MySDR.Protocol do
        use ExHdl.Protocol

        defpacket :iq_frame, bus_width: 32, byte_order: :little do
          header on_mismatch: :drop_packet do
            field :magic,      16, assert: 0x55AA
            field :channel_id, 8,  type: :u8
            field :gain_q15,   16, type: :s16
            ...
          end

          payload :stream, type: {:complex, :s16}
        end
      end

  For every packet `name` the module gets:

    * `name/0` - the validated `ExHdl.Protocol.Spec`
    * `encode_name/2` - `(header :: map | keyword, payload :: list) -> binary`.
      Asserted fields default to their asserted value.
    * `decode_name/1` - `binary -> {:ok, header_map, payload_list} | {:error, reason}`,
      implemented as a single binary pattern match.
    * `__ex_hdl_packets__/0` - all specs of the module.
  """

  alias ExHdl.Protocol.Spec

  defmacro __using__(_opts) do
    quote do
      import ExHdl.Protocol, only: [defpacket: 2, defpacket: 3]
      Module.register_attribute(__MODULE__, :ex_hdl_packets, accumulate: true)
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

  defmacro __before_compile__(env) do
    specs = env.module |> Module.get_attribute(:ex_hdl_packets) |> Enum.reverse()

    defs = Enum.map(specs, &packet_functions/1)

    quote do
      @doc false
      def __ex_hdl_packets__, do: unquote(Macro.escape(specs))
      unquote_splicing(defs)
    end
  end

  # -- code generation -------------------------------------------------------

  defp packet_functions(%Spec{} = spec) do
    encode = :"encode_#{spec.name}"
    decode = :"decode_#{spec.name}"
    header_var = Macro.var(:header, __MODULE__)
    payload_var = Macro.var(:payload, __MODULE__)
    endian = spec.byte_order

    encode_segments =
      Enum.map(spec.fields, fn f ->
        value =
          quote do
            ExHdl.Protocol.Runtime.fetch_field!(
              unquote(header_var),
              unquote(spec.name),
              unquote(f.name),
              unquote(f.bits),
              unquote(f.signed),
              unquote(f.assert)
            )
          end

        segment(value, f.bits, f.signed, endian)
      end)

    decode_segments =
      Enum.map(spec.fields, fn f -> segment(field_var(f), f.bits, f.signed, endian) end)

    header_map = {:%{}, [], Enum.map(spec.fields, fn f -> {f.name, field_var(f)} end)}

    assert_checks =
      for f <- spec.fields, f.assert != nil do
        quote do
          :ok <-
            ExHdl.Protocol.Runtime.check_assert(
              unquote(f.name),
              unquote(field_var(f)),
              unquote(f.assert)
            )
        end
      end

    elem_bytes = Spec.payload_elem_bytes(spec)

    quote do
      @doc "Returns the `ExHdl.Protocol.Spec` for `#{unquote(inspect(spec.name))}`."
      def unquote(spec.name)(), do: unquote(Macro.escape(spec))

      @doc "Encodes a `#{unquote(inspect(spec.name))}` packet."
      def unquote(encode)(unquote(header_var), unquote(payload_var))
          when is_list(unquote(payload_var)) do
        unquote(header_var) = Map.new(unquote(header_var))

        <<unquote_splicing(encode_segments), unquote(encode_payload(spec, payload_var))::binary>>
      end

      @doc "Decodes a `#{unquote(inspect(spec.name))}` packet."
      def unquote(decode)(<<unquote_splicing(decode_segments), unquote(payload_var)::binary>>) do
        with unquote_splicing(assert_checks),
             0 <- rem(byte_size(unquote(payload_var)), unquote(elem_bytes)) do
          {:ok, unquote(header_map), unquote(decode_payload(spec, payload_var))}
        else
          unquote(
            if assert_checks == [] do
              quote(do: (_ -> {:error, :partial_payload_element}))
            else
              quote do
                {:error, _} = err -> err
                _ -> {:error, :partial_payload_element}
              end
            end
          )
        end
      end

      def unquote(decode)(bin) when is_binary(bin), do: {:error, :truncated_header}
    end
  end

  defp encode_payload(%Spec{payload: p, byte_order: endian, name: name}, payload_var) do
    check = fn var ->
      quote do
        ExHdl.Protocol.Runtime.check_value!(
          unquote(name),
          unquote(p.name),
          unquote(var),
          unquote(p.elem_bits),
          unquote(p.signed)
        )
      end
    end

    i = Macro.var(:i, __MODULE__)
    q = Macro.var(:q, __MODULE__)

    if p.complex do
      quote do
        for {unquote(i), unquote(q)} <- unquote(payload_var), into: <<>> do
          <<unquote(segment(check.(i), p.elem_bits, p.signed, endian)),
            unquote(segment(check.(q), p.elem_bits, p.signed, endian))>>
        end
      end
    else
      quote do
        for unquote(i) <- unquote(payload_var), into: <<>> do
          <<unquote(segment(check.(i), p.elem_bits, p.signed, endian))>>
        end
      end
    end
  end

  defp decode_payload(%Spec{payload: p, byte_order: endian}, payload_var) do
    i = Macro.var(:i, __MODULE__)
    q = Macro.var(:q, __MODULE__)

    if p.complex do
      quote do
        for <<unquote(segment(i, p.elem_bits, p.signed, endian)),
              unquote(segment(q, p.elem_bits, p.signed, endian)) <- unquote(payload_var)>>,
            do: {unquote(i), unquote(q)}
      end
    else
      quote do
        for <<unquote(segment(i, p.elem_bits, p.signed, endian)) <- unquote(payload_var)>>,
          do: unquote(i)
      end
    end
  end

  defp field_var(f), do: Macro.var(:"field_#{f.name}", __MODULE__)

  # Builds `value::endian-signedness-size(bits)`.
  defp segment(value, bits, signed, endian) do
    sign = if signed, do: :signed, else: :unsigned
    type = {:-, [], [{:-, [], [{endian, [], nil}, {sign, [], nil}]}, {:size, [], [bits]}]}
    {:"::", [], [value, type]}
  end
end

defmodule ExHdl.Protocol.DSL do
  @moduledoc false

  defmacro header(opts \\ [], do: block) do
    quote do
      ExHdl.Protocol.Builder.header(__MODULE__, unquote(opts))
      unquote(block)
    end
  end

  defmacro field(name, bits, opts \\ []) do
    quote do
      ExHdl.Protocol.Builder.field(__MODULE__, unquote(name), unquote(bits), unquote(opts))
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
      name: name,
      opts: opts,
      header: nil,
      fields: [],
      payload: nil
    })
  end

  def header(mod, opts), do: update(mod, &%{&1 | header: opts})

  def field(mod, name, bits, opts),
    do: update(mod, &%{&1 | fields: [{name, bits, opts} | &1.fields]})

  def payload(mod, name, opts) do
    update(mod, fn wip ->
      if wip.payload,
        do: raise(ArgumentError, "defpacket #{inspect(wip.name)}: only one payload allowed")

      %{wip | payload: {name, opts}}
    end)
  end

  def finish(mod) do
    wip = Module.get_attribute(mod, @attr)
    Module.delete_attribute(mod, @attr)

    spec =
      ExHdl.Protocol.Spec.build!(
        wip.name,
        wip.opts,
        wip.header,
        Enum.reverse(wip.fields),
        wip.payload
      )

    Module.put_attribute(mod, :ex_hdl_packets, spec)
  end

  defp update(mod, fun) do
    case Module.get_attribute(mod, @attr) do
      nil -> raise ArgumentError, "header/field/payload must be used inside defpacket"
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
