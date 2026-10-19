defmodule ExHdl.Backends.SystemVerilog.Fir do
  @moduledoc """
  Finds FIR filters in a lowered stream kernel: dot products of constant
  taps with values that are one signal at different sample delays.

  A kernel sees its delay line as state (`line`, shifted each sample), so a
  FIR is `dot(window, taps)` where the window holds the sample and the line
  elements, possibly through per-element ops (a clip, a type change). This
  pass gives every lowered signal a value key `{delay, base}`: the state
  element whose next value is `v` is `v` one sample later, and an
  elementwise op of values with the same delay is the op of their bases at
  that delay. Dot terms with the same base form a filter on that base:
  `sum_d h[d] * base[n - d]`.

  Such a filter is generated in transposed form (`ExHdl.Backends.SystemVerilog.Scan`):
  every tap multiplies the current `base[n]` and adds the partial sum of
  the next tap from the previous sample, `P_k[n] = h_k * base[n] + P_k+1[n - 1]`,
  which maps onto a column of DSP48E1 slices (post-adder, PCIN-PCOUT). The
  partial sums advance once per sample, so stalls and gaps in the stream
  do not disturb them. With symmetric (or antisymmetric) taps the terms of
  `h_k` and `h_D-k` share a slice through the pre-adder:
  `P_k[n] = h_k * (base[n] +- base[n - (D - 2k)]) + P_k+1[n - 1]`, the second
  operand read from the kernel's delay line. Zero taps need no multiplier.
  The sum is exact, so the result is bit-identical to the reference.

  Conditions: one channel, the dot is outside the feedback loop, all terms
  are constant taps times delayed values, the undelayed `base[n]` exists as
  a signal, and the delay line starts at zero (so the partial sums reset to
  zero).
  """

  import Bitwise

  # Cycles from the inputs to the partial sum: input register, (pre-adder
  # register,) multiply-add into P.
  @plain_latency 2
  @folded_latency 3

  @doc """
  The FIR plan of a lowered context: `%{dot_id => %{latency:, elems: %{e => [group]}}}`
  with groups `%{x0:, taps:, refs:, fold:}`.
  """
  def plan(c, scan) do
    if scan.channels != 1 do
      %{}
    else
      st = %{c: c, next: next_refs(c, scan), keys: %{}, bases: %{}}

      {st, index} = index(st)

      for id <- c.graph.order,
          node = c.graph.nodes[id],
          node.op == :dot,
          not MapSet.member?(scan.recurrence, id),
          {:ok, p} <- [node_plan(st, index, node)],
          into: %{},
          do: {id, p}
    end
  end

  @doc "Schedule cost overrides for the planned dots."
  def costs(plan), do: Map.new(plan, fn {id, p} -> {id, {:reg, p.latency, :dsp48_chain}} end)

  @doc "Cycles of a group's chain."
  def chain_latency(%{fold: nil}), do: @plain_latency
  def chain_latency(_), do: @folded_latency

  @doc """
  The chain positions of a group, `[{k, h, second}]` for k = 0.. where
  `second` is `nil` or `{sign, ref}` (the pre-adder operand).
  """
  def terms(%{fold: nil, taps: taps}),
    do: taps |> Enum.with_index() |> Enum.map(fn {h, k} -> {k, h, nil} end)

  def terms(%{fold: fold, taps: taps, refs: refs}) do
    d = length(taps) - 1
    sign = if fold == :sym, do: :add, else: :sub

    for k <- 0..div(d, 2) do
      h = Enum.at(taps, k)
      second = if 2 * k == d or h == 0, do: nil, else: {sign, Map.fetch!(refs, d - 2 * k)}
      {k, h, second}
    end
  end

  @doc "The products of a dot element: `[{a_ref, b_ref}]` over the contracted axes."
  def dot_pairs(c, node, e) do
    [a, b] = node.inputs
    {contract_a, _batch_a, contract_b, _batch_b} = node.attrs
    a_shape = c.graph.nodes[a].shape
    b_shape = c.graph.nodes[b].shape
    free_a = Enum.reject(0..(tuple_size(a_shape) - 1)//1, &(&1 in contract_a))
    free_b = Enum.reject(0..(tuple_size(b_shape) - 1)//1, &(&1 in contract_b))
    contract_shape = contract_a |> Enum.map(&elem(a_shape, &1)) |> List.to_tuple()
    i = multi(e, node.shape)
    {ia, ib} = Enum.split(i, length(free_a))

    for j <- indices(contract_shape) do
      ai = place(tuple_size(a_shape), Enum.zip(free_a, ia) ++ Enum.zip(contract_a, j))
      bi = place(tuple_size(b_shape), Enum.zip(free_b, ib) ++ Enum.zip(contract_b, j))
      {elem(c.elems[a], flat(ai, a_shape)), elem(c.elems[b], flat(bi, b_shape))}
    end
  end

  # -- per node -----------------------------------------------------------------------------

  defp node_plan(st, index, node) do
    {_, batch, _, _} = node.attrs

    elems =
      if batch == [] do
        Enum.map(0..(size(node.shape) - 1)//1, &{&1, elem_plan(st, index, node, &1)})
      else
        [{0, :error}]
      end

    if Enum.all?(elems, &match?({_, {:ok, _}}, &1)) and
         Enum.any?(elems, fn {_, {:ok, gs}} -> Enum.any?(gs, &(length(&1.taps) > 1)) end) do
      elems = Map.new(elems, fn {e, {:ok, gs}} -> {e, gs} end)

      latency =
        elems
        |> Map.values()
        |> Enum.map(fn gs ->
          (gs |> Enum.map(&chain_latency/1) |> Enum.max()) + ceil_log2(length(gs))
        end)
        |> Enum.max()

      {:ok, %{latency: latency, elems: elems}}
    else
      :error
    end
  end

  defp elem_plan(st, index, node, e) do
    pairs = dot_pairs(st.c, node, e)

    classified =
      Enum.map(pairs, fn
        {{:lit, 0}, _} -> :zero
        {_, {:lit, 0}} -> :zero
        {{:lit, _}, {:lit, _}} -> :other
        {{:lit, h}, ref} -> {h, ref}
        {ref, {:lit, h}} -> {h, ref}
        _ -> :other
      end)
      |> Enum.reject(&(&1 == :zero))

    if classified == [] or Enum.member?(classified, :other) do
      :error
    else
      grouped =
        Enum.reduce_while(classified, %{}, fn {h, {:sig, name}}, acc ->
          case Map.fetch!(st.keys, name) do
            {d, base} when is_integer(d) ->
              taps = Map.get(acc, base, %{})
              taps = Map.update(taps, d, {h, {:sig, name}}, fn {h0, ref} -> {h0 + h, ref} end)
              {:cont, Map.put(acc, base, taps)}

            _ ->
              {:halt, :error}
          end
        end)

      with %{} <- grouped do
        grouped
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn {base, taps}, {:ok, acc} ->
          case group(st, index, base, taps) do
            {:ok, g} -> {:cont, {:ok, [g | acc]}}
            :error -> {:halt, :error}
          end
        end)
        |> case do
          {:ok, gs} -> {:ok, Enum.reverse(gs)}
          :error -> :error
        end
      end
    end
  end

  # A filter on `base` delayed by the first non-zero tap's delay `s`, so
  # leading zero taps cost nothing. The dot's own operands are preferred
  # (they are ready when the dot is); the first one is the chain input.
  defp group(st, index, base, terms) do
    nonzero = for {k, {h, _}} <- terms, h != 0, do: k

    if nonzero == [] do
      :error
    else
      {s, d} = Enum.min_max(nonzero)
      taps = Enum.map(s..d, fn k -> with({h, _} <- Map.get(terms, k, {0, nil}), do: h) end)

      refs =
        Map.new(s..d, fn k ->
          case terms do
            %{^k => {h, ref}} when h != 0 -> {k - s, ref}
            _ -> {k - s, Map.get(index, {base, k})}
          end
        end)

      if Enum.any?(
           (s + 1)..d//1,
           &(refs[&1 - s] == nil or zero_start(st, index, base, &1) != {:ok, 0})
         ),
         do: :error,
         else: {:ok, %{x0: refs[0], taps: taps, refs: refs, fold: fold(taps)}}
    end
  end

  # The value at delay `k` before the first sample, from the initial state.
  defp zero_start(st, index, base, k) do
    case Map.get(index, {base, k}) do
      nil -> :error
      ref -> eval0(st.c, ref)
    end
  end

  defp fold([_]), do: nil

  defp fold(taps) do
    rev = Enum.reverse(taps)
    d = length(taps) - 1
    center = if rem(d, 2) == 0, do: Enum.at(taps, div(d, 2)), else: 0

    cond do
      taps == rev -> :sym
      taps == Enum.map(rev, &(-&1)) and center == 0 -> :anti
      true -> nil
    end
  end

  # -- value keys -----------------------------------------------------------------------------

  # `{state, %{{base, delay} => ref}}` over every non-static signal.
  defp index(st) do
    Enum.reduce(Map.keys(st.c.sigs) |> Enum.sort(), {st, %{}}, fn name, {st, index} ->
      {st, k} = key(st, name, MapSet.new())

      case k do
        {d, base} when is_integer(d) -> {st, Map.put_new(index, {base, d}, {:sig, name})}
        _ -> {st, index}
      end
    end)
  end

  # `{:static, id}` or `{delay, base}`.
  defp key(st, name, visiting) do
    case st.keys do
      %{^name => k} ->
        {st, k}

      _ ->
        {st, k} = compute_key(st, name, visiting)
        {%{st | keys: Map.put(st.keys, name, k)}, k}
    end
  end

  defp compute_key(st, name, visiting) do
    sig = st.c.sigs[name]

    cond do
      sig.stage == :static ->
        {st, {:static, name}}

      MapSet.member?(visiting, name) ->
        {st, {0, {:sig, name}}}

      true ->
        visiting = MapSet.put(visiting, name)

        case Map.get(st.c.defs, name) do
          {:in, index, e} ->
            intern(st, 0, {:in, index, e})

          {:state, index, e, _init} ->
            case Map.get(st.next, {index, e}) do
              nil ->
                {st, {0, {:sig, name}}}

              ref ->
                case ref_key(st, ref, visiting) do
                  {st, {d, base}} when is_integer(d) -> {st, {d + 1, base}}
                  {st, _} -> {st, {0, {:sig, name}}}
                end
            end

          {:op, op, refs} ->
            {st, ks} =
              Enum.reduce(refs, {st, []}, fn r, {st, ks} ->
                {st, k} = ref_key(st, r, visiting)
                {st, [k | ks]}
              end)

            ks = Enum.reverse(ks)
            delays = for {d, _} <- ks, is_integer(d), uniq: true, do: d

            case delays do
              [d] -> intern(st, d, {op, Enum.map(ks, &base_of/1)})
              _ -> {st, {0, {:sig, name}}}
            end

          _ ->
            {st, {0, {:sig, name}}}
        end
    end
  end

  # Bases are numbered, so that keys stay small on graphs with shared
  # subexpressions.
  defp intern(st, d, structure) do
    case st.bases do
      %{^structure => id} ->
        {st, {d, {:base, id}}}

      bases ->
        id = map_size(bases)
        {%{st | bases: Map.put(bases, structure, id)}, {d, {:base, id}}}
    end
  end

  defp ref_key(st, {:lit, v}, _visiting), do: {st, {:static, {:lit, v}}}
  defp ref_key(st, {:sig, name}, visiting), do: key(st, name, visiting)

  defp base_of({:static, s}), do: {:static, s}
  defp base_of({_d, base}), do: base

  # `%{{state_index, e} => next_ref}`
  defp next_refs(c, scan) do
    next_ids = flatten(scan.next_state)

    for {state, next_id} <- Enum.zip(c.layout.states, next_ids),
        {ref, e} <- c.elems |> Map.fetch!(next_id) |> Tuple.to_list() |> Enum.with_index(),
        into: %{},
        do: {{state.index, e}, ref}
  end

  # -- value at the first sample (state from :init) -----------------------------------------

  defp eval0(_c, {:lit, v}), do: {:ok, v}

  defp eval0(c, {:sig, name}) do
    case Map.get(c.defs, name) do
      {:state, _index, _e, init} ->
        {:ok, init}

      {:op, op, refs} ->
        refs
        |> Enum.reduce_while({:ok, []}, fn r, {:ok, acc} ->
          case eval0(c, r) do
            {:ok, v} -> {:cont, {:ok, [v | acc]}}
            :error -> {:halt, :error}
          end
        end)
        |> case do
          {:ok, vs} -> apply_op(op, Enum.reverse(vs))
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp apply_op(op, args) do
    case {op, args} do
      {:add, [a, b]} -> {:ok, a + b}
      {:subtract, [a, b]} -> {:ok, a - b}
      {:remainder, [a, b]} when b != 0 -> {:ok, rem(a, b)}
      {:multiply, [a, b]} -> {:ok, a * b}
      {:negate, [a]} -> {:ok, -a}
      {:abs, [a]} -> {:ok, abs(a)}
      {:min, [a, b]} -> {:ok, min(a, b)}
      {:max, [a, b]} -> {:ok, max(a, b)}
      {:clip, [x, lo, hi]} -> {:ok, x |> max(lo) |> min(hi)}
      {:select, [p, a, b]} -> {:ok, if(p != 0, do: a, else: b)}
      {:right_shift, [a, k]} -> {:ok, a >>> k}
      {:left_shift, [a, k]} -> {:ok, a <<< k}
      {:bitwise_and, [a, b]} -> {:ok, band(a, b)}
      {:bitwise_or, [a, b]} -> {:ok, bor(a, b)}
      {:bitwise_xor, [a, b]} -> {:ok, bxor(a, b)}
      _ -> :error
    end
  end

  # -- helpers ------------------------------------------------------------------------------

  defp ceil_log2(n) when n <= 1, do: 0
  defp ceil_log2(n), do: 1 + ceil_log2(div(n + 1, 2))

  defp size(shape), do: shape |> Tuple.to_list() |> Enum.product()

  defp indices(shape), do: for(e <- 0..(size(shape) - 1)//1, do: multi(e, shape))

  defp multi(flat, shape) do
    shape
    |> Tuple.to_list()
    |> Enum.reverse()
    |> Enum.map_reduce(flat, fn d, rest -> {rem(rest, d), div(rest, d)} end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp flat(idx, shape) do
    idx
    |> Enum.zip(Tuple.to_list(shape))
    |> Enum.reduce(0, fn {i, d}, acc -> acc * d + i end)
  end

  defp place(rank, pairs) do
    m = Map.new(pairs)
    for k <- 0..(rank - 1)//1, do: Map.fetch!(m, k)
  end

  defp flatten(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&flatten/1)
  defp flatten(id) when is_integer(id), do: [id]
end
