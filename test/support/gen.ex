defmodule ExHdl.Test.Gen do
  @moduledoc false
  # StreamData generators derived from a packet spec.
  use ExUnitProperties
  import Bitwise
  alias ExHdl.Protocol.Spec

  def int(bits, true), do: integer(-(1 <<< (bits - 1))..((1 <<< (bits - 1)) - 1))
  def int(bits, false), do: integer(0..((1 <<< bits) - 1))

  @doc "Header map for the non-asserted fields."
  def header(%Spec{fields: fields}) do
    fields
    |> Enum.filter(&is_nil(&1.assert))
    |> Map.new(fn f -> {f.name, int(f.bits, f.signed)} end)
    |> fixed_map()
  end

  def payload(%Spec{payload: p}, opts \\ []) do
    elem = int(p.elem_bits, p.signed)
    elem = if p.complex, do: tuple({elem, elem}), else: elem
    list_of(elem, Keyword.merge([min_length: 1, max_length: 64], opts))
  end

  @doc """
  A packet case: `{:good, bin}` or `{:bad, bin}` (bad assert, runt, or header
  without payload). Bad cases are only generated if the kind applies.
  """
  def packet_case(%Spec{} = spec, encode) do
    asserted = Enum.filter(spec.fields, & &1.assert)

    kinds =
      [{6, constant(:good)}, {1, constant(:runt)}, {1, constant(:header_only)}] ++
        if(asserted != [], do: [{2, constant(:bad_assert)}], else: [])

    gen all(
          kind <- frequency(kinds),
          header <- header(spec),
          payload <- payload(spec),
          bad_field <- member_of(if asserted == [], do: [nil], else: asserted),
          cut <- integer(1..(Spec.header_bytes(spec) - 1))
        ) do
      good = encode.(header, payload)

      case kind do
        :good ->
          {:good, good}

        :runt ->
          {:bad, binary_part(good, 0, cut)}

        :header_only ->
          {:bad, binary_part(good, 0, Spec.header_bytes(spec))}

        :bad_assert ->
          # Flip the lowest bit: stays in range and differs from the assert.
          wrong = Bitwise.bxor(bad_field.assert, 1)

          wrong =
            if Spec.fits?(wrong, bad_field.bits, bad_field.signed),
              do: wrong,
              else: bad_field.assert - 1

          {:bad, encode.(Map.put(header, bad_field.name, wrong), payload)}
      end
    end
  end
end

defmodule ExHdl.Test.ChainGen do
  @moduledoc false
  # Random packets for layer chains, following a random header layout of
  # ExHdl.Protocol.Layout, with good and broken variants and the output the
  # parser -> emitter loopback should produce.
  use ExUnitProperties
  import Bitwise
  alias ExHdl.Protocol.{Codec, Layer, Layout, Spec}

  @doc """
  `{header, payload, path}` for a random layout. `tables` maps match field
  refs to their table; those fields take table values.
  """
  def packet(%Spec{} = spec, tables \\ %{}) do
    paths = Layout.paths(spec)

    gen all(
          path <- member_of(paths),
          layers <- fixed_list(Enum.map(path.steps, &layer_values(spec, path, &1, tables))),
          payload <- payload(spec)
        ) do
      {build_header(spec, path, layers), payload, path}
    end
  end

  defp layer_values(spec, path, step, tables) do
    l = step.layer

    l.fields
    |> Enum.reject(&(&1.assert != nil or &1.kind == :bytes or ExHdl.Protocol.Field.computed?(&1)))
    |> Enum.map(fn f -> {f.name, field_value(spec, path, step, f, tables)} end)
    |> fixed_map()
    |> then(fn g ->
      if l.tail do
        gen(all(m <- g, t <- binary(length: step.hlen - l.fixed_bytes)),
          do: Map.put(m, l.tail, t)
        )
      else
        g
      end
    end)
  end

  defp field_value(spec, path, step, f, tables) do
    cond_ =
      Enum.find_value(path.conds, fn {inst, _c, fname, c} ->
        if inst == step.inst and fname == f.name, do: c
      end)

    ref = Spec.ref(spec, step.layer.name, f.name)

    case {cond_, f.kind} do
      {{:in, vals}, _} ->
        member_of(vals)

      {{:not_in, vals}, _} ->
        filter(int(f.bits, false), &(&1 not in vals))

      {nil, :flag} ->
        boolean()

      {nil, _} ->
        case Map.get(tables, ref) do
          nil -> int(f.bits, f.signed)
          vals -> member_of(vals)
        end
    end
  end

  defp int(bits, true), do: integer(-(1 <<< (bits - 1))..((1 <<< (bits - 1)) - 1))
  defp int(bits, false), do: integer(0..((1 <<< bits) - 1))

  defp payload(%Spec{payload: %{bytes: true}}), do: binary(min_length: 1, max_length: 80)

  defp payload(%Spec{payload: p}) do
    elem = int(p.elem_bits, p.signed)
    elem = if p.complex, do: tuple({elem, elem}), else: elem
    list_of(elem, min_length: 1, max_length: 32)
  end

  defp build_header(%Spec{flat: true}, _path, [m]), do: m

  defp build_header(spec, path, layers) do
    base = for l <- spec.layers, l.max > 1, into: %{}, do: {l.name, []}

    path.steps
    |> Enum.zip(layers)
    |> Enum.reduce(base, fn {step, m}, acc ->
      if step.layer.max > 1,
        do: Map.update!(acc, step.layer.name, &(&1 ++ [m])),
        else: Map.put(acc, step.layer.name, m)
    end)
  end

  @doc """
  A case for the loopback: `{:good, bin, expected}`, `{:flag, bin, expected}`
  (forwarded with tuser) or `{:drop, bin}`, tagged with the kind:
  `{kind, outcome}`.
  """
  def loopback_case(%Spec{} = spec, tables \\ %{}) do
    gen all(
          {header, payload, path} <- packet(spec, tables),
          kind <- member_of(kinds(spec, path, tables)),
          r1 <- integer(0..0xFFFF_FFFF),
          r2 <- integer(0..0xFFFF_FFFF),
          extra <- binary(min_length: 1, max_length: 12)
        ) do
      {kind, make(spec, path, kind, header, payload, r1, r2, extra, tables)}
    end
  end

  defp kinds(spec, path, tables) do
    fields = for st <- path.steps, f <- st.layer.fields, do: {st, f}
    has = fn pred -> Enum.any?(fields, fn {st, f} -> pred.(st, f) end) end
    lengths? = has.(fn _, f -> f.length != nil end)

    [:good, :good, :good, :good, :runt, :header_only] ++
      if(lengths?, do: [:padded, :truncated, :bad_length], else: []) ++
      if(has.(fn _, f -> f.assert != nil end), do: [:bad_assert], else: []) ++
      if(has.(fn _, f -> f.checksum == :header end), do: [:bad_hcsum], else: []) ++
      if(has.(fn _, f -> f.checksum == :segment end), do: [:bad_seg, :zero_seg], else: []) ++
      if(has.(fn st, f -> f.match != nil and tables[Spec.ref(spec, st.layer.name, f.name)] end),
        do: [:no_match],
        else: []
      ) ++
      if(has.(fn st, _ -> st.layer.next != nil and st.layer.default == :reject end),
        do: [:bad_branch],
        else: []
      ) ++
      if(has.(fn st, _ -> st.layer.hlen_field != nil end), do: [:bad_hlen], else: [])
  end

  defp make(spec, path, kind, header, payload, r1, r2, extra, tables) do
    good = Codec.encode(spec, header, payload)
    p = path.payload
    fields = for st <- path.steps, f <- st.layer.fields, do: {st, f}
    pick = fn pred -> fields |> Enum.filter(fn {st, f} -> pred.(st, f) end) |> at(r1) end

    case kind do
      :good ->
        {:good, good, good}

      :padded ->
        {:good, good <> extra, good}

      :runt ->
        {:drop, binary_part(good, 0, rem(r1, p - 1) + 1)}

      :header_only ->
        {:drop, binary_part(good, 0, p)}

      :truncated ->
        n = byte_size(good) - p

        if n < 2 do
          {:good, good, good}
        else
          cut = binary_part(good, 0, p + rem(r1, n - 1) + 1)
          {:flag, cut, cut}
        end

      :bad_length ->
        {st, f} = pick.(fn _, f -> f.length != nil end)
        # shorter than the bytes from the layer start to the payload
        v = rem(r2, p - st.start + 1)
        {:drop, Codec.encode(spec, put_field(spec, header, st, f.name, v), payload)}

      :bad_assert ->
        {st, f} = pick.(fn _, f -> f.assert != nil end)
        wrong = band(bxor(f.assert, rem(r2, (1 <<< f.bits) - 1) + 1), (1 <<< f.bits) - 1)
        {:drop, Codec.encode(spec, put_field(spec, header, st, f.name, wrong), payload)}

      :bad_hcsum ->
        {st, f} = pick.(fn _, f -> f.checksum == :header end)
        {:drop, flip_field(spec, good, st, f, r2)}

      :bad_seg ->
        {st, f} = pick.(fn _, f -> f.checksum == :segment end)
        bin = flip_field(spec, good, st, f, r2)
        {:flag, bin, bin}

      :zero_seg ->
        {st, f} = pick.(fn _, f -> f.checksum == :segment end)
        bin = Codec.encode(spec, put_field(spec, header, st, f.name, 0), payload)
        {:good, bin, bin}

      :no_match ->
        {st, f} =
          pick.(fn st, f -> f.match != nil and tables[Spec.ref(spec, st.layer.name, f.name)] end)

        vals = tables[Spec.ref(spec, st.layer.name, f.name)]
        v = Enum.find(Stream.iterate(r2, &(&1 + 1)), &(band(&1, (1 <<< f.bits) - 1) not in vals))
        v = band(v, (1 <<< f.bits) - 1)
        {:drop, Codec.encode(spec, put_field(spec, header, st, f.name, v), payload)}

      :bad_branch ->
        {st, _} =
          pick.(fn st, f ->
            st.layer.next != nil and st.layer.default == :reject and
              f.name == elem(st.layer.next, 0)
          end)

        {fname, cases} = st.layer.next
        f = Layer.field(st.layer, fname)
        listed = Enum.map(cases, &elem(&1, 0))

        v =
          Enum.find(Stream.iterate(r2, &(&1 + 1)), &(band(&1, (1 <<< f.bits) - 1) not in listed))

        {:drop, put_bits(good, 8 * st.start + f.offset, f.bits, band(v, (1 <<< f.bits) - 1))}

      :bad_hlen ->
        {st, _} = pick.(fn st, _ -> st.layer.hlen_field != nil end)
        f = Layer.field(st.layer, st.layer.hlen_field)
        too_small = div(st.layer.fixed_bytes - 1, f.header_length)
        {:drop, put_bits(good, 8 * st.start + f.offset, f.bits, rem(r2, too_small + 1))}
    end
  end

  defp at(list, r), do: Enum.at(list, rem(r, length(list)))

  defp put_field(%Spec{flat: true}, header, _st, name, v), do: Map.put(header, name, v)

  defp put_field(_spec, header, st, name, v) do
    {lname, idx} = st.inst

    case header[lname] do
      list when is_list(list) ->
        Map.put(header, lname, List.update_at(list, idx, &Map.put(&1, name, v)))

      m ->
        Map.put(header, lname, Map.put(m, name, v))
    end
  end

  # Replaces a 16-bit field with a different nonzero value.
  defp flip_field(_spec, bin, st, f, r) do
    off = 8 * st.start + f.offset
    <<_::size(off), old::size(f.bits), _::bitstring>> = bin
    new = band(old + rem(r, 0xFFFD) + 1, 0xFFFF)
    # 0x0000 and 0xFFFF are the same in ones' complement; 0 disables UDP checksums
    new = if new in [0, 0xFFFF, old], do: if(old == 0x1234, do: 0x4321, else: 0x1234), else: new
    put_bits(bin, off, f.bits, new)
  end

  def put_bits(bin, off, bits, v) do
    <<pre::bitstring-size(off), _::size(bits), post::bitstring>> = bin
    <<pre::bitstring, v::size(bits), post::bitstring>>
  end
end
