defmodule ExHdl.Protocol.Bitstring do
  @moduledoc """
  Translates Elixir bitstring syntax (`<<...>>`) and guards (`when ...`) into
  `ExHdl.Protocol` field declarations.

  Supported segment forms:
    * `name::bits` - unsigned integer of `bits` width
    * `name::bits - type(:flag | :u8 | :s16 | {:enum, ...})`
    * `name::bits - flag` - shorthand for `type: :flag`
    * `name::signed-bits` - signed integer (`type: :s<bits>`)
    * `name::bits - assert(val)` or `(name = val)::bits` or `name::bits - val`
    * `name::bits - error(reason)`
    * `name::bits - header_length(unit)`
    * `name::bits - length(:total)`
    * `name::bits - checksum(:header)`
    * `name::bits - checksum(:segment, optional: true, pseudo: [...])`
    * `name::bits - match(n)`
    * `name::bytes` or `name::binary` - variable-length tail

  Supported guards (`when ...`):
    * `field == val` - assertions on field values
    * `header_length(field, unit)` - variable header multiplier
    * `length(field, :total)` - total layer length
    * `header_checksum(field)` - RFC 1071 header checksum
    * `segment_checksum(field, opts)` - segment checksum (UDP)
    * `hw_match(field, n)` or `match(field, n)` - hardware match table
    * `error(field, reason)` - error tuple on mismatch
    * `type(field, type_val)` - custom field type
  """

  @doc """
  Parses a `{:<<>>, meta, segments}` or `{:when, _, [bitstring, guard_expr]}`
  AST into a list of `{name, bits, opts}`.
  """
  def to_fields({:when, _meta, [{:<<>>, _, _} = bitstring, guard_expr]}) do
    fields = to_fields(bitstring)
    guard_directives = parse_guards(guard_expr)

    Enum.map(fields, fn {name, bits, opts} ->
      extra_opts = Map.get(guard_directives, name, [])
      merged_opts = Enum.reduce(extra_opts, opts, fn {k, v}, acc -> put_opt(acc, k, v) end)
      {name, bits, merged_opts}
    end)
  end

  def to_fields({:<<>>, _meta, segments}) do
    {fields, _} =
      Enum.map_reduce(segments, 0, fn segment, offset ->
        field = parse_segment(segment, offset)
        bits = elem(field, 1)
        next_offset = offset + if(bits == :bytes, do: 0, else: bits)
        {field, next_offset}
      end)

    fields
  end

  @doc """
  Transforms an AST block: replaces any `{:<<>>, meta, segments}` or
  `{:when, _, [bitstring, guard]}` with calls to
  `ExHdl.Protocol.Builder.field(__MODULE__, name, bits, opts)`.
  Expressions that are not bitstrings are preserved as-is.
  """
  def transform_ast({:when, _meta, [{:<<>>, _, _}, _guard_expr]} = expr) do
    fields = to_fields(expr)

    quote do
      unquote_splicing(emit_fields(fields))
    end
  end

  def transform_ast({:<<>>, _meta, _segments} = bitstring) do
    fields = to_fields(bitstring)

    quote do
      unquote_splicing(emit_fields(fields))
    end
  end

  def transform_ast({:__block__, meta, exprs}) do
    transformed_exprs =
      Enum.flat_map(exprs, fn
        {:when, _meta, [{:<<>>, _, _}, _guard_expr]} = expr ->
          fields = to_fields(expr)
          emit_fields(fields)

        {:<<>>, _meta, _segments} = bitstring ->
          fields = to_fields(bitstring)
          emit_fields(fields)

        other ->
          [transform_ast(other)]
      end)

    {:__block__, meta, transformed_exprs}
  end

  def transform_ast(other), do: other

  @doc """
  Transforms the body of `defpacket`:
  If a top-level bitstring or guarded bitstring is present without an explicit
  `header` block, it expands into `header do ... end`.
  """
  def transform_packet_block({:when, _meta, [{:<<>>, _, _}, _guard_expr]} = expr) do
    quote do
      header do
        unquote(expr)
      end
    end
  end

  def transform_packet_block({:<<>>, _meta, _segments} = bitstring) do
    quote do
      header do
        unquote(bitstring)
      end
    end
  end

  def transform_packet_block({:__block__, meta, exprs}) do
    transformed_exprs =
      Enum.map(exprs, fn
        {:when, _wmeta, [{:<<>>, _, _}, _guard_expr]} = expr ->
          quote do
            header do
              unquote(expr)
            end
          end

        {:<<>>, _bmeta, _segments} = bitstring ->
          quote do
            header do
              unquote(bitstring)
            end
          end

        {:header, hmeta, [h_opts, [do: h_block]]} ->
          {:header, hmeta, [h_opts, [do: transform_ast(h_block)]]}

        {:header, hmeta, [[do: h_block]]} ->
          {:header, hmeta, [[do: transform_ast(h_block)]]}

        other ->
          other
      end)

    {:__block__, meta, transformed_exprs}
  end

  def transform_packet_block(other), do: other

  defp emit_fields(fields) do
    Enum.map(fields, fn {name, bits, opts} ->
      quote do
        ExHdl.Protocol.Builder.field(__MODULE__, unquote(name), unquote(bits), unquote(opts))
      end
    end)
  end

  defp parse_segment({:"::", _, [target, spec]}, offset) do
    {name, initial_opts} = parse_target(target, offset)
    modifiers = flatten_modifiers(spec)
    {bits, opts} = parse_modifiers(modifiers, initial_opts)
    {name, bits, opts}
  end

  defp parse_segment(target, offset) do
    {name, initial_opts} = parse_target(target, offset)
    {name, 8, initial_opts}
  end

  defp parse_target({:=, _, [{name, _, _}, assert_val]}, _offset)
       when is_atom(name) and is_integer(assert_val) do
    {name, [assert: assert_val]}
  end

  defp parse_target({:=, _, [assert_val, {name, _, _}]}, _offset)
       when is_atom(name) and is_integer(assert_val) do
    {name, [assert: assert_val]}
  end

  defp parse_target({name, _, _}, _offset) when is_atom(name), do: {name, []}
  defp parse_target(name, _offset) when is_atom(name), do: {name, []}

  defp parse_target(assert_val, offset) when is_integer(assert_val) do
    {:"_anon_assert_#{assert_val}_#{offset}", [assert: assert_val]}
  end

  defp flatten_modifiers({:-, _, [left, right]}),
    do: flatten_modifiers(left) ++ flatten_modifiers(right)

  defp flatten_modifiers(other), do: [other]

  defp put_opt(opts, key, val) do
    Keyword.delete(opts, key) ++ [{key, val}]
  end

  defp parse_guards(guard_expr) do
    flatten_guards(guard_expr)
    |> Enum.map(&parse_single_guard/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, fn {field, opts}, acc ->
      Map.update(acc, field, opts, &(&1 ++ opts))
    end)
  end

  defp flatten_guards({:and, _, [left, right]}), do: flatten_guards(left) ++ flatten_guards(right)
  defp flatten_guards({:&&, _, [left, right]}), do: flatten_guards(left) ++ flatten_guards(right)
  defp flatten_guards(other), do: [other]

  defp parse_single_guard({:==, _, [{field, _, _}, val]}) when is_atom(field),
    do: {field, [assert: val]}

  defp parse_single_guard({:==, _, [val, {field, _, _}]}) when is_atom(field),
    do: {field, [assert: val]}

  defp parse_single_guard({:header_length, _, [{field, _, _}, unit]}),
    do: {field, [header_length: unit]}

  defp parse_single_guard({:length, _, [{field, _, _}, len]}),
    do: {field, [length: len]}

  defp parse_single_guard({:header_checksum, _, [{field, _, _}]}),
    do: {field, [checksum: :header]}

  defp parse_single_guard({:segment_checksum, _, [{field, _, _}, opts]}) when is_list(opts),
    do: {field, [checksum: :segment] ++ opts}

  defp parse_single_guard({:segment_checksum, _, [{field, _, _}]}),
    do: {field, [checksum: :segment]}

  defp parse_single_guard({:checksum, _, [{field, _, _}, :header]}),
    do: {field, [checksum: :header]}

  defp parse_single_guard({:checksum, _, [{field, _, _}, :segment, opts]}) when is_list(opts),
    do: {field, [checksum: :segment] ++ opts}

  defp parse_single_guard({:checksum, _, [{field, _, _}, :segment]}),
    do: {field, [checksum: :segment]}

  defp parse_single_guard({call, _, [{field, _, _}, n]}) when call in [:match, :hw_match],
    do: {field, [match: n]}

  defp parse_single_guard({:error, _, [{field, _, _}, reason]}),
    do: {field, [error: reason]}

  defp parse_single_guard({:type, _, [{field, _, _}, type_val]}),
    do: {field, [type: type_val]}

  defp parse_single_guard({:flag, _, [{field, _, _}]}),
    do: {field, [type: :flag]}

  defp parse_single_guard({:optional, _, [{field, _, _}, opt]}),
    do: {field, [optional: opt]}

  defp parse_single_guard({:pseudo, _, [{field, _, _}, ps]}),
    do: {field, [pseudo: ps]}

  defp parse_single_guard(_other), do: nil

  defp parse_modifiers(modifiers, initial_opts) do
    {bits, opts} =
      Enum.reduce(modifiers, {nil, initial_opts}, fn mod, {bits, opts} ->
        case mod do
          n when is_integer(n) and is_nil(bits) ->
            {n, opts}

          n when is_integer(n) ->
            {bits, put_opt(opts, :assert, n)}

          {:size, _, [n]} when is_integer(n) ->
            {n, opts}

          b when b in [:binary, :bytes] ->
            {:bytes, opts}

          {:binary, _, _} ->
            {:bytes, opts}

          {:bytes, _, _} ->
            {:bytes, opts}

          :flag ->
            {bits, put_opt(opts, :type, :flag)}

          {:flag, _, _} ->
            {bits, put_opt(opts, :type, :flag)}

          {:signed, _, _} ->
            {bits, if(bits, do: put_opt(opts, :type, :"s#{bits}"), else: put_opt(opts, :signed, true))}

          :signed ->
            {bits, if(bits, do: put_opt(opts, :type, :"s#{bits}"), else: put_opt(opts, :signed, true))}

          s when is_tuple(s) and tuple_size(s) == 3 and elem(s, 0) in [:little, :big] ->
            {bits, opts}

          {:assert, _, [val]} ->
            {bits, put_opt(opts, :assert, val)}

          {:error, _, [err]} ->
            {bits, put_opt(opts, :error, err)}

          {:header_length, _, [unit]} ->
            {bits, put_opt(opts, :header_length, unit)}

          {:length, _, [len]} ->
            {bits, put_opt(opts, :length, len)}

          {:match, _, [m]} ->
            {bits, put_opt(opts, :match, m)}

          {:optional, _, [opt]} ->
            {bits, put_opt(opts, :optional, opt)}

          {:pseudo, _, [ps]} ->
            {bits, put_opt(opts, :pseudo, ps)}

          {:checksum, _, [csum, csum_opts]} when is_list(csum_opts) ->
            merged = Enum.reduce(csum_opts, put_opt(opts, :checksum, csum), fn {k, v}, acc -> put_opt(acc, k, v) end)
            {bits, merged}

          {:checksum, _, [csum]} ->
            {bits, put_opt(opts, :checksum, csum)}

          {:type, _, [[enum: cases]]} ->
            {bits, put_opt(opts, :type, {:enum, cases})}

          {:type, _, [{:enum, cases}]} ->
            {bits, put_opt(opts, :type, {:enum, cases})}

          {:type, _, [type_val]} ->
            {bits, put_opt(opts, :type, type_val)}

          t when is_list(t) and length(t) > 0 and is_tuple(hd(t)) ->
            merged = Enum.reduce(t, opts, fn {k, v}, acc -> put_opt(acc, k, v) end)
            {bits, merged}

          {atom, _, _} when is_atom(atom) ->
            str = Atom.to_string(atom)

            cond do
              str =~ ~r/^[us]\d+$/ ->
                {bits, put_opt(opts, :type, atom)}

              atom == :flag ->
                {bits, put_opt(opts, :type, :flag)}

              true ->
                {bits, opts}
            end

          _other ->
            {bits, opts}
        end
      end)

    if Keyword.get(opts, :signed) && bits && !Keyword.has_key?(opts, :type) do
      {bits, opts |> Keyword.delete(:signed) |> put_opt(:type, :"s#{bits}")}
    else
      {bits, opts}
    end
  end
end
