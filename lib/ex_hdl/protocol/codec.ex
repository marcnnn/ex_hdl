defmodule ExHdl.Protocol.Codec do
  @moduledoc """
  BEAM encoder and decoder for `ExHdl.Protocol.Spec`, used by the functions
  `defpacket` generates. It walks the layer chain the same way the hardware
  parser does.

  ## Decoding

  `decode_header/3` walks the layers: it decodes each fixed part, checks
  asserts, the header length, header checksums and runtime matches, and
  picks the next layer from the selector field. It returns the header and the
  bytes after it, untouched.

  `decode/3` then applies the total-length fields: each must cover its
  layer's header and fit inside the enclosing one, the innermost one ends
  the packet (later bytes, such as Ethernet padding, are dropped), and the
  packet must be long enough for it. Then it checks segment checksums
  (UDP: pseudo header, UDP header and payload) and converts the payload.

  Errors are `{:error, reason}`:

    * `:truncated_header` - the packet ends inside the header
    * `{:assert_failed, ref, value}` - an `assert:` field differs
    * `{:no_branch, ref, value}` - a selector value without a next layer, or
      a layer repeated more than its `max:`
    * `{:bad_length, ref, value}` - a header-length or total-length field is
      too small, or a total length exceeds the enclosing one
    * `{:bad_checksum, ref, value}` - a checksum does not verify
    * `{:no_match, ref, value}` - a runtime match (`match:` option) failed
    * `{:truncated, ref, value}` - the packet is shorter than the innermost
      total-length field says
    * `:partial_payload_element` - the payload is not a whole number of
      elements

  `ref` is the field name for packets with a single `header` block and
  `{layer, field}` for layer chains. A field declared with `error: reason`
  reports `{:error, reason}` instead.

  The hardware parser drops packets with header errors and forwards the
  payload of packets with `:truncated` or segment `:bad_checksum` errors with
  `m_axis_tuser` set on the last beat (both are only known at the end).
  """

  import Bitwise
  alias ExHdl.Protocol.{Field, Layer, Spec}

  # -- decoding ----------------------------------------------------------------

  @doc """
  Decodes the header chain. Returns `{:ok, header, rest}` with `rest` the
  bytes after the header. Options: `match: %{ref => [value]}` (or a keyword
  list for flat specs) checks fields against runtime tables.
  """
  def decode_header(%Spec{} = spec, bin, opts \\ []) when is_binary(bin) do
    with {:ok, steps, p} <- walk(spec, bin, matches(opts)) do
      {:ok, header_map(spec, steps), binary_part(bin, p, byte_size(bin) - p)}
    end
  end

  @doc "Decodes a whole packet: `{:ok, header, payload}` or `{:error, reason}`."
  def decode(%Spec{} = spec, bin, opts \\ []) when is_binary(bin) do
    with {:ok, steps, p} <- walk(spec, bin, matches(opts)),
         {:ok, e} <- lengths(spec, steps, p, byte_size(bin)),
         payload_bin = binary_part(bin, p, e - p),
         :ok <- segment_checksums(spec, steps, bin, e),
         {:ok, payload} <- decode_payload(spec, payload_bin) do
      {:ok, header_map(spec, steps), payload}
    end
  end

  defp matches(opts) do
    opts |> Keyword.get(:match, %{}) |> Map.new(fn {k, v} -> {k, List.wrap(v)} end)
  end

  # A step: %{layer, idx, start, hlen, raw: %{field => int | binary}}
  defp walk(spec, bin, matches) do
    walk(spec, hd(spec.layers), bin, 0, %{}, [], matches)
  end

  defp walk(spec, %Layer{} = l, bin, offset, counts, steps, matches) do
    avail = byte_size(bin) - offset

    if avail < l.fixed_bytes do
      {:error, :truncated_header}
    else
      fixed = binary_part(bin, offset, l.fixed_bytes)
      raw = parse_fixed(spec, l, fixed)
      idx = Map.get(counts, l.name, 0)

      with :ok <- check_asserts(spec, l, raw),
           {:ok, hlen} <- header_length(spec, l, raw, avail),
           raw = put_tail(l, raw, bin, offset, hlen),
           header_bin = binary_part(bin, offset, hlen),
           :ok <- header_checksums(spec, l, raw, header_bin),
           :ok <- check_matches(spec, l, raw, matches),
           counts = Map.put(counts, l.name, idx + 1),
           {:ok, target} <- next_layer(spec, l, raw, counts) do
        step = %{layer: l, idx: idx, start: offset, hlen: hlen, raw: raw}
        steps = [step | steps]

        case target do
          :payload ->
            {:ok, Enum.reverse(steps), offset + hlen}

          name ->
            walk(spec, Spec.layer(spec, name), bin, offset + hlen, counts, steps, matches)
        end
      end
    end
  end

  defp parse_fixed(spec, l, fixed) do
    endian = spec.byte_order

    {raw, _} =
      Enum.reduce(l.fields, {%{}, fixed}, fn
        %Field{kind: :bytes}, acc ->
          acc

        f, {raw, rest} ->
          <<v::size(f.bits), rest::bitstring>> = rest
          v = if endian == :little, do: swap_bytes(v, f.bits), else: v
          v = if f.signed and v >= 1 <<< (f.bits - 1), do: v - (1 <<< f.bits), else: v
          {Map.put(raw, f.name, v), rest}
      end)

    raw
  end

  defp swap_bytes(v, bits) do
    <<le::little-size(bits)>> = <<v::size(bits)>>
    le
  end

  defp fail(spec, l, f, kind, v) do
    case f.error do
      nil -> {:error, {kind, Spec.ref(spec, l.name, f.name), v}}
      reason -> {:error, reason}
    end
  end

  defp check_asserts(spec, l, raw) do
    Enum.find_value(l.fields, :ok, fn f ->
      if f.assert != nil and raw[f.name] != f.assert,
        do: fail(spec, l, f, :assert_failed, raw[f.name])
    end)
  end

  defp header_length(_spec, %Layer{hlen_field: nil} = l, _raw, _avail), do: {:ok, l.fixed_bytes}

  defp header_length(spec, l, raw, avail) do
    f = Layer.field(l, l.hlen_field)
    hlen = raw[f.name] * f.header_length

    cond do
      hlen < l.fixed_bytes -> fail(spec, l, f, :bad_length, raw[f.name])
      hlen > avail -> {:error, :truncated_header}
      true -> {:ok, hlen}
    end
  end

  defp put_tail(%Layer{tail: nil}, raw, _bin, _offset, _hlen), do: raw

  defp put_tail(l, raw, bin, offset, hlen),
    do: Map.put(raw, l.tail, binary_part(bin, offset + l.fixed_bytes, hlen - l.fixed_bytes))

  defp header_checksums(spec, l, raw, header_bin) do
    Enum.find_value(l.fields, :ok, fn f ->
      if f.checksum == :header and inet_sum(header_bin) != 0xFFFF,
        do: fail(spec, l, f, :bad_checksum, raw[f.name])
    end)
  end

  defp check_matches(_spec, _l, _raw, matches) when map_size(matches) == 0, do: :ok

  defp check_matches(spec, l, raw, matches) do
    Enum.find_value(l.fields, :ok, fn f ->
      case Map.fetch(matches, Spec.ref(spec, l.name, f.name)) do
        {:ok, values} ->
          values = Enum.map(values, &Spec.resolve_value!(spec.name, f, &1))
          if raw[f.name] not in values, do: fail(spec, l, f, :no_match, raw[f.name])

        :error ->
          nil
      end
    end)
  end

  defp next_layer(_spec, %Layer{next: nil}, _raw, _counts), do: {:ok, :payload}

  defp next_layer(spec, %Layer{next: {fname, cases}} = l, raw, counts) do
    v = raw[fname]

    target =
      case List.keyfind(cases, v, 0) do
        {_, t} -> t
        nil -> l.default
      end

    cond do
      target == :reject ->
        fail(spec, l, Layer.field(l, fname), :no_branch, v)

      target != :payload and Map.get(counts, target, 0) >= Spec.layer(spec, target).max ->
        fail(spec, l, Layer.field(l, fname), :no_branch, v)

      true ->
        {:ok, target}
    end
  end

  # Returns the end offset of the packet (innermost total length, or the size).
  defp lengths(spec, steps, p, size) do
    result =
      Enum.reduce_while(steps, {nil, nil}, fn step, {e_outer, last} ->
        case Enum.find(step.layer.fields, &(&1.length == :total)) do
          nil ->
            {:cont, {e_outer, last}}

          f ->
            v = step.raw[f.name]
            e = step.start + v

            if e < p or (e_outer != nil and e > e_outer),
              do: {:halt, fail(spec, step.layer, f, :bad_length, v)},
              else: {:cont, {e, {step.layer, f, v}}}
        end
      end)

    case result do
      {:error, _} = err -> err
      {nil, nil} -> {:ok, size}
      {e, _} when e <= size -> {:ok, e}
      {_, {l, f, v}} -> fail(spec, l, f, :truncated, v)
    end
  end

  defp segment_checksums(spec, steps, bin, e) do
    Enum.find_value(steps, :ok, fn step ->
      Enum.find_value(step.layer.fields, fn f ->
        if f.checksum == :segment do
          v = step.raw[f.name]
          pseudo = pseudo_bytes(spec, steps, step, f)
          seg = binary_part(bin, step.start, e - step.start)

          if not (f.optional and v == 0) and inet_sum(pseudo <> seg) != 0xFFFF,
            do: fail(spec, step.layer, f, :bad_checksum, v)
        end
      end)
    end)
  end

  defp pseudo_bytes(spec, steps, step, f) do
    for ref <- f.pseudo, into: <<>> do
      {lname, fname} = if is_atom(ref), do: {step.layer.name, ref}, else: ref
      src = Enum.find(steps, &(&1.layer.name == lname))
      pf = Layer.field(Spec.layer(spec, lname), fname)
      word_bits = div(pf.bits + 15, 16) * 16
      <<src.raw[fname]::size(word_bits)>>
    end
  end

  defp decode_payload(%Spec{payload: %{bytes: true}}, bin), do: {:ok, bin}

  defp decode_payload(%Spec{payload: p, byte_order: endian} = spec, bin) do
    if rem(byte_size(bin), Spec.payload_elem_bytes(spec)) != 0 do
      {:error, :partial_payload_element}
    else
      bits = p.elem_bits

      elems =
        for <<x::binary-size(div(bits, 8)) <- bin>>, do: decode_int(x, bits, p.signed, endian)

      {:ok, if(p.complex, do: pairs(elems), else: elems)}
    end
  end

  defp decode_int(x, _bits, false, endian), do: :binary.decode_unsigned(x, endian)

  defp decode_int(x, bits, true, :big) do
    <<v::signed-big-size(bits)>> = x
    v
  end

  defp decode_int(x, bits, true, :little) do
    <<v::signed-little-size(bits)>> = x
    v
  end

  defp pairs([i, q | rest]), do: [{i, q} | pairs(rest)]
  defp pairs([]), do: []

  defp header_map(%Spec{flat: true}, [step]), do: value_map(step)

  defp header_map(%Spec{} = spec, steps) do
    base = for l <- spec.layers, l.max > 1, into: %{}, do: {l.name, []}

    steps
    |> Enum.reverse()
    |> Enum.reduce(base, fn step, acc ->
      if step.layer.max > 1,
        do: Map.update!(acc, step.layer.name, &[value_map(step) | &1]),
        else: Map.put(acc, step.layer.name, value_map(step))
    end)
  end

  defp value_map(step) do
    Map.new(step.layer.fields, fn f -> {f.name, present(f, step.raw[f.name])} end)
  end

  defp present(%Field{kind: :flag}, v), do: v == 1

  defp present(%Field{kind: :enum, enum: enum}, v) do
    case List.keyfind(enum, v, 1) do
      {name, _} -> name
      nil -> v
    end
  end

  defp present(_f, v), do: v

  # -- encoding ----------------------------------------------------------------

  @doc """
  Encodes a packet. Missing computed fields (lengths, checksums, header
  lengths) are computed, missing selector fields derived from the layers
  present; explicit values are used as given.
  """
  def encode(%Spec{} = spec, header, payload) do
    payload_bin = encode_payload(spec, payload)
    steps = plan(spec, header)

    {bin, _} =
      steps
      |> Enum.reverse()
      |> Enum.reduce({payload_bin, nil}, fn step, {after_bin, _} ->
        {serialize(spec, steps, step, after_bin) <> after_bin, nil}
      end)

    bin
  end

  # Resolves the layer sequence and the non-computed field values.
  defp plan(%Spec{flat: true} = spec, header) do
    l = hd(spec.layers)
    [%{layer: l, idx: 0, vals: resolve_fields(spec, l, Map.new(header))}]
  end

  defp plan(%Spec{} = spec, header) do
    header = Map.new(header)
    plan(spec, hd(spec.layers), header, %{}, [])
  end

  defp plan(spec, l, header, counts, acc) do
    idx = Map.get(counts, l.name, 0)
    lmap = layer_input(spec, l, header, idx)
    counts = Map.put(counts, l.name, idx + 1)

    {lmap, target} = choose_next(spec, l, lmap, header, counts)
    acc = [%{layer: l, idx: idx, vals: resolve_fields(spec, l, lmap)} | acc]

    case target do
      :payload -> Enum.reverse(acc)
      name -> plan(spec, Spec.layer(spec, name), header, counts, acc)
    end
  end

  defp layer_input(spec, l, header, idx) do
    v =
      case Map.fetch(header, l.name) do
        {:ok, list} when l.max > 1 and is_list(list) -> Enum.at(list, idx)
        {:ok, m} when l.max == 1 and idx == 0 -> m
        _ -> nil
      end

    if v == nil,
      do: raise(ArgumentError, "#{inspect(spec.name)}: missing header layer #{inspect(l.name)}")

    Map.new(v)
  end

  defp available?(spec, header, counts, name) do
    l = Spec.layer(spec, name)
    used = Map.get(counts, name, 0)

    case Map.get(header, name) do
      nil -> false
      list when is_list(list) and l.max > 1 -> used < length(list) and used < l.max
      _ -> used == 0
    end
  end

  defp choose_next(_spec, %Layer{next: nil}, lmap, _header, _counts), do: {lmap, :payload}

  defp choose_next(spec, %Layer{next: {fname, cases}} = l, lmap, header, counts) do
    f = Layer.field(l, fname)

    case Map.fetch(lmap, fname) do
      {:ok, value} ->
        v = to_raw!(spec, f, value)

        target =
          case List.keyfind(cases, v, 0) do
            {_, t} -> t
            nil -> l.default
          end

        if target == :reject,
          do: raise(ArgumentError, "#{inspect(spec.name)}: #{inspect(fname)} = #{v} has no layer")

        {lmap, target}

      :error ->
        targets = Enum.uniq(Enum.map(cases, &elem(&1, 1)))

        target =
          Enum.find(targets, &(&1 != :payload and available?(spec, header, counts, &1))) ||
            Enum.find(targets, &(&1 == :payload))

        case target && List.keyfind(cases, target, 1) do
          {v, _} ->
            {Map.put(lmap, fname, v), target}

          nil ->
            raise ArgumentError,
                  "#{inspect(spec.name)}: cannot derive #{inspect(l.name)}.#{fname}: " <>
                    "no next layer #{inspect(targets -- [:payload])} in the header"
        end
    end
  end

  defp resolve_fields(spec, l, lmap) do
    Map.new(l.fields, fn f ->
      value =
        case Map.fetch(lmap, f.name) do
          {:ok, v} when f.kind == :bytes -> check_bytes!(spec, f, v)
          {:ok, v} -> to_raw!(spec, f, v)
          :error when f.kind == :bytes -> <<>>
          :error when f.assert != nil -> f.assert
          :error -> if Field.computed?(f), do: :auto, else: missing!(spec, f)
        end

      {f.name, value}
    end)
  end

  defp missing!(spec, f),
    do: raise(ArgumentError, "#{inspect(spec.name)}: missing header field #{inspect(f.name)}")

  defp check_bytes!(_spec, _f, v) when is_binary(v), do: v

  defp check_bytes!(spec, f, v),
    do:
      raise(
        ArgumentError,
        "#{inspect(spec.name)}: #{inspect(f.name)} must be a binary, got #{inspect(v)}"
      )

  defp to_raw!(spec, f, value) do
    v =
      cond do
        f.kind == :flag and is_boolean(value) -> if value, do: 1, else: 0
        f.kind == :enum and is_atom(value) and Keyword.has_key?(f.enum, value) -> f.enum[value]
        true -> value
      end

    ExHdl.Protocol.Runtime.check_value!(spec.name, f.name, v, f.bits, f.signed)
  end

  defp serialize(spec, steps, step, after_bin) do
    l = step.layer
    vals = step.vals
    tail = if l.tail, do: vals[l.tail], else: <<>>
    hlen = l.fixed_bytes + byte_size(tail)

    vals =
      Map.new(vals, fn
        {name, :auto} ->
          f = Layer.field(l, name)

          cond do
            f.header_length ->
              if rem(hlen, f.header_length) != 0,
                do:
                  raise(
                    ArgumentError,
                    "#{inspect(spec.name)}: #{inspect(l.tail)} must make the header a multiple of #{f.header_length} bytes"
                  )

              {name, check_computed!(spec, f, div(hlen, f.header_length))}

            f.length ->
              {name, check_computed!(spec, f, hlen + byte_size(after_bin))}

            true ->
              {name, :auto}
          end

        other ->
          other
      end)

    seg =
      for f <- l.fields, f.checksum == :segment and vals[f.name] == :auto, reduce: vals do
        vals ->
          bin = pack(spec, l, Map.put(vals, f.name, 0) |> zero_auto(l))
          pseudo = pseudo_values(spec, steps, step, f, vals)
          sum = bnot(inet_sum(pseudo <> bin <> after_bin)) &&& 0xFFFF
          Map.put(vals, f.name, if(f.optional and sum == 0, do: 0xFFFF, else: sum))
      end

    hdr =
      for f <- l.fields, f.checksum == :header and seg[f.name] == :auto, reduce: seg do
        vals ->
          bin = pack(spec, l, Map.put(vals, f.name, 0) |> zero_auto(l))
          Map.put(vals, f.name, bnot(inet_sum(bin)) &&& 0xFFFF)
      end

    pack(spec, l, hdr)
  end

  defp check_computed!(spec, f, v) do
    if Spec.fits?(v, f.bits, false),
      do: v,
      else:
        raise(
          ArgumentError,
          "#{inspect(spec.name)}: computed #{inspect(f.name)} = #{v} does not fit #{f.bits} bits"
        )
  end

  defp zero_auto(vals, _l),
    do: Map.new(vals, fn {k, v} -> {k, if(v == :auto, do: 0, else: v)} end)

  defp pseudo_values(spec, steps, step, f, own_vals) do
    for ref <- f.pseudo, into: <<>> do
      {lname, fname} = if is_atom(ref), do: {step.layer.name, ref}, else: ref

      v =
        if lname == step.layer.name,
          do: own_vals[fname],
          else: Enum.find(steps, &(&1.layer.name == lname)).vals[fname]

      pf = Layer.field(Spec.layer(spec, lname), fname)
      word_bits = div(pf.bits + 15, 16) * 16
      <<v::size(word_bits)>>
    end
  end

  defp pack(spec, l, vals) do
    endian = spec.byte_order

    for f <- l.fields, into: <<>> do
      case f.kind do
        :bytes ->
          vals[f.name]

        _ ->
          v = vals[f.name]

          case endian do
            :big -> <<v::size(f.bits)>>
            :little -> <<v::little-size(f.bits)>>
          end
      end
    end
  end

  defp encode_payload(%Spec{payload: %{bytes: true}} = spec, payload) do
    unless is_binary(payload),
      do: raise(ArgumentError, "#{inspect(spec.name)}: payload must be a binary")

    payload
  end

  defp encode_payload(%Spec{payload: p, byte_order: endian, name: name}, payload)
       when is_list(payload) do
    check = fn v ->
      ExHdl.Protocol.Runtime.check_value!(name, p.name, v, p.elem_bits, p.signed)
    end

    bits = p.elem_bits

    int = fn v ->
      case endian do
        :big -> <<v::size(bits)>>
        :little -> <<v::little-size(bits)>>
      end
    end

    if p.complex do
      for {i, q} <- payload, into: <<>>, do: int.(check.(i)) <> int.(check.(q))
    else
      for i <- payload, into: <<>>, do: int.(check.(i))
    end
  end

  # -- checksum ----------------------------------------------------------------

  @doc """
  Ones' complement sum (RFC 1071) of `bin` as big-endian 16-bit words, odd
  length padded with a zero byte. A header that contains its correct
  checksum sums to `0xFFFF`.
  """
  def inet_sum(bin), do: inet_sum(bin, 0)

  defp inet_sum(<<w::16, rest::binary>>, acc), do: inet_sum(rest, acc + w)
  defp inet_sum(<<b>>, acc), do: inet_sum(<<>>, acc + (b <<< 8))
  defp inet_sum(<<>>, acc) when acc > 0xFFFF, do: inet_sum(<<>>, (acc &&& 0xFFFF) + (acc >>> 16))
  defp inet_sum(<<>>, acc), do: acc
end
