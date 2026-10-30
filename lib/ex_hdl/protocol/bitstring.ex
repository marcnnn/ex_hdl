defmodule ExHdl.Protocol.Bitstring do
  @moduledoc """
  Turns a plain Elixir binary pattern into `ExHdl.Protocol` fields.

  The pattern is the one you would write in a function head, so it can be
  copied to and from ordinary BEAM code:

      <<version::4, ihl::4, tos::8, total_length::16, id::16, flags_frag::16,
        ttl::8, protocol::8, checksum::16, src::32, dst::32,
        options::binary-size(ihl * 4 - 20), _rest::binary>>
      when version == 4

  Segments:

    * `name::N`, `name::size(N)`, `name::size(N)-unit(U)` - unsigned integer
    * `signed` - signed integer, `big` / `little` - must agree with the
      packet's `byte_order` (fields of up to 8 bits are not checked)
    * `name::binary-size(field * unit - fixed)` - variable-length tail (IPv4
      options); `field` becomes the `header_length: unit` field and `fixed`
      must be the size of the fixed part in bytes
    * a trailing unsized `binary` / `bits` segment is what follows the header
      and is ignored

  Guards: `field == value` (joined with `and`) become `assert: value`.

  Semantics a pattern cannot carry (enums, flags, checksums, lengths, match
  tables, error reasons) are given per field next to the pattern, see
  `ExHdl.Protocol`.
  """

  @doc """
  Returns `{fields, rest_var}`: `fields` is a list of `{name, bits, opts_ast}`
  for `ExHdl.Protocol.Builder.field/4`, `rest_var` the AST of a trailing
  unsized binary segment or nil. `field_opts` is the keyword AST given next
  to the pattern.
  """
  def to_fields(pattern, field_opts \\ []) do
    {bin, guard} = split_guard(pattern)
    {:<<>>, _, segments} = bin

    {segments, rest_var} =
      case List.last(segments) do
        {:"::", _, [{name, _, ctx} = var, spec]} when is_atom(name) and is_atom(ctx) ->
          if unsized_binary?(spec), do: {Enum.drop(segments, -1), var}, else: {segments, nil}

        _ ->
          {segments, nil}
      end

    {fields, _offset} = Enum.map_reduce(segments, 0, &segment/2)
    fields = fields |> apply_header_length() |> apply_guard(guard) |> apply_opts(field_opts)
    {fields, rest_var}
  end

  @doc "Splits `pattern when guard` into the bitstring and the guard (nil if none)."
  def split_guard({:when, _, [{:<<>>, _, _} = bin, guard]}), do: {bin, guard}
  def split_guard({:<<>>, _, _} = bin), do: {bin, nil}

  def split_guard(other),
    do: raise(ArgumentError, "expected a binary pattern <<...>>, got: #{Macro.to_string(other)}")

  defp segment({:"::", _, [target, spec]} = seg, offset) do
    name = field_name!(target, seg)
    mods = flatten(spec)

    if Enum.any?(mods, &binary_type?/1) do
      tail_segment(name, mods, seg, offset)
    else
      int_segment(name, mods, seg, offset)
    end
  end

  # Elixir's default segment is an 8-bit unsigned integer
  defp segment(target, offset) do
    name = field_name!(target, target)
    {{name, 8, [endian: :big]}, offset + 8}
  end

  defp int_segment(name, mods, seg, offset) do
    {size, unit, signed, endian} =
      Enum.reduce(mods, {nil, 1, false, :big}, fn mod, {size, unit, signed, endian} ->
        case mod do
          n when is_integer(n) -> {n, unit, signed, endian}
          {:size, _, [n]} when is_integer(n) -> {n, unit, signed, endian}
          {:unit, _, [u]} when is_integer(u) -> {size, u, signed, endian}
          {:signed, _, _} -> {size, unit, true, endian}
          {:unsigned, _, _} -> {size, unit, false, endian}
          {:integer, _, _} -> {size, unit, signed, endian}
          {:big, _, _} -> {size, unit, signed, :big}
          {:little, _, _} -> {size, unit, signed, :little}
          other -> unsupported!(seg, other)
        end
      end)

    bits = (size || 8) * unit
    opts = [endian: endian] ++ if(signed, do: [type: :"s#{bits}"], else: [])
    {{name, bits, opts}, offset + bits}
  end

  defp tail_segment(name, mods, seg, offset) do
    size =
      Enum.find_value(mods, fn
        {:size, _, [expr]} -> expr
        _ -> nil
      end)

    {hlen_field, unit, fixed} =
      case size do
        {:-, _, [{:*, _, [{f, _, ctx}, u]}, fixed]} when is_atom(ctx) and is_integer(u) ->
          {f, u, fixed}

        {:-, _, [{:*, _, [u, {f, _, ctx}]}, fixed]} when is_atom(ctx) and is_integer(u) ->
          {f, u, fixed}

        _ ->
          raise ArgumentError,
                "#{Macro.to_string(seg)}: a header tail needs size(field * unit - fixed_bytes)"
      end

    unless rem(offset, 8) == 0 and fixed == div(offset, 8) do
      raise ArgumentError,
            "#{Macro.to_string(seg)}: the fixed part is #{offset} bits, not #{inspect(fixed)} bytes"
    end

    {{name, :bytes, [header_length_of: {hlen_field, unit}]}, offset}
  end

  defp apply_header_length(fields) do
    case Enum.find(fields, fn {_, bits, _} -> bits == :bytes end) do
      {tail, :bytes, [header_length_of: {hname, unit}]} ->
        unless List.keymember?(fields, hname, 0),
          do: raise(ArgumentError, "#{tail}: size refers to #{hname}, which is not a field")

        Enum.map(fields, fn
          {^hname, bits, opts} -> {hname, bits, opts ++ [header_length: unit]}
          {name, :bytes, _} -> {name, :bytes, []}
          other -> other
        end)

      nil ->
        fields
    end
  end

  defp apply_guard(fields, nil), do: fields

  defp apply_guard(fields, guard) do
    names = Enum.map(fields, &elem(&1, 0))

    asserts =
      guard
      |> flatten_and()
      |> Enum.map(fn
        {:==, _, [{f, _, ctx}, value]} when is_atom(ctx) -> {f, value}
        {:==, _, [value, {f, _, ctx}]} when is_atom(ctx) -> {f, value}
        other -> unsupported_guard!(other)
      end)

    for {f, _} <- asserts, f not in names do
      raise ArgumentError, "guard on #{inspect(f)}, which is not a field of the pattern"
    end

    Enum.map(fields, fn {name, bits, opts} ->
      case List.keyfind(asserts, name, 0) do
        {_, value} -> {name, bits, opts ++ [assert: value]}
        nil -> {name, bits, opts}
      end
    end)
  end

  defp apply_opts(fields, field_opts) do
    names = Enum.map(fields, &elem(&1, 0))

    unless Keyword.keyword?(field_opts),
      do: raise(ArgumentError, "field options must be a keyword list of field: [opts]")

    for {f, _} <- field_opts, f not in names do
      raise ArgumentError, "options for #{inspect(f)}, which is not a field of the pattern"
    end

    Enum.map(fields, fn {name, bits, opts} ->
      {name, bits, opts ++ Keyword.get(field_opts, name, [])}
    end)
  end

  defp field_name!({:_, _, ctx}, seg) when is_atom(ctx),
    do: raise(ArgumentError, "#{Macro.to_string(seg)}: header fields need a name, not _")

  defp field_name!({name, _, ctx}, _seg) when is_atom(name) and is_atom(ctx), do: name

  defp field_name!(_target, seg) do
    raise ArgumentError,
          "#{Macro.to_string(seg)}: header fields need a name; " <>
            "match constants with a guard, e.g. <<version::4, ...>> when version == 4"
  end

  defp unsized_binary?(spec) do
    mods = flatten(spec)
    Enum.any?(mods, &binary_type?/1) and not Enum.any?(mods, &match?({:size, _, _}, &1))
  end

  defp binary_type?({t, _, ctx}) when t in [:binary, :bytes, :bitstring, :bits] and is_atom(ctx),
    do: true

  defp binary_type?(_), do: false

  defp flatten({:-, _, [l, r]}), do: flatten(l) ++ flatten(r)
  defp flatten(other), do: [other]

  defp flatten_and({:and, _, [l, r]}), do: flatten_and(l) ++ flatten_and(r)
  defp flatten_and(other), do: [other]

  defp unsupported!(seg, mod) do
    raise ArgumentError,
          "#{Macro.to_string(seg)}: unsupported segment option #{Macro.to_string(mod)}"
  end

  defp unsupported_guard!(expr) do
    raise ArgumentError,
          "unsupported guard #{Macro.to_string(expr)}: only field == value, joined with and"
  end
end
