defmodule ExHdl.Frame.Linear do
  @moduledoc """
  Evaluates an Nx expression on affine forms instead of numbers: every
  element of every tensor is `sum(coeff * input element) + const`, or a
  rounding step applied to such a form. Used to recognise linear frame
  kernels (decimating and interpolating FIRs, resamplers) from their Nx
  graph without knowing which function built it.

  An element is

    * an affine form: a map from `{param, flat_index}` to an integer
      coefficient, `:c` holding the constant;
    * `{:shr, e, k}`: `floor(e / 2^k)` (an arithmetic right shift);
    * `{:clip, e, lo, hi}`.

  Integer types only. Views (slice, reshape, concatenate, broadcast,
  transpose, squeeze), `add`, `subtract`, `negate`, products and dots with
  a constant side, shifts by constants, `clip` and `as_type` are
  supported; a `clip` of an input element to (at least) its type's range
  is the identity. Anything else raises `ExHdl.Frame.Linear.NotLinear`.
  """
  import Bitwise

  alias Nx.Defn.Expr

  defmodule NotLinear do
    defexception [:message]
  end

  @doc """
  Evaluates the container of expressions `exprs` (from `Nx.Defn.debug_expr/1`)
  and returns the same container with every tensor replaced by
  `%{shape:, type:, elems: tuple}`.
  """
  def eval(exprs) do
    {result, _memo} =
      Nx.Defn.Composite.traverse(exprs, %{ranges: %{}}, fn t, memo -> value(t, memo) end)

    result
  end

  @doc "Range `{lo, hi}` of an element given the ranges of the parameters (`%{param => {lo, hi}}`)."
  def range(%{} = form, ranges) do
    Enum.reduce(form, {0, 0}, fn
      {:c, c}, {lo, hi} ->
        {lo + c, hi + c}

      {{p, _}, k}, {lo, hi} ->
        {plo, phi} = Map.fetch!(ranges, p)
        {a, b} = if k >= 0, do: {k * plo, k * phi}, else: {k * phi, k * plo}
        {lo + a, hi + b}
    end)
  end

  def range({:shr, e, k}, ranges) do
    {lo, hi} = range(e, ranges)
    {lo >>> k, hi >>> k}
  end

  def range({:clip, e, lo, hi}, ranges) do
    {a, b} = range(e, ranges)
    {min(max(a, lo), hi), max(min(b, hi), lo)}
  end

  # -- evaluation ---------------------------------------------------------------------

  defp value(%Nx.Tensor{data: %Expr{id: id}} = t, memo) do
    case memo do
      %{^id => v} ->
        {v, memo}

      _ ->
        {v, memo} = node(t, memo)
        {v, Map.put(memo, id, v)}
    end
  end

  defp value(%Nx.Tensor{} = t, memo), do: {constant_tensor(t), memo}
  defp value(n, memo) when is_number(n), do: {scalar(n), memo}

  defp node(%Nx.Tensor{data: %Expr{op: op, args: args}, shape: shape, type: type} = t, memo) do
    check_type!(type, op)

    case op do
      :parameter ->
        [index] = args
        memo = put_in(memo, [:ranges, index], type_range(type))
        {mk(shape, type, for(i <- 0..(size(shape) - 1)//1, do: %{{index, i} => 1})), memo}

      :tensor ->
        [tensor] = args
        {constant_tensor(tensor), memo}

      :constant ->
        [number] = args
        {mk(shape, type, List.duplicate(%{c: number}, size(shape))), memo}

      :metadata ->
        [expr, _] = args
        value(expr, memo)

      :optional ->
        [_call, expr, _fun] = args
        value(expr, memo)

      _ ->
        {inputs, memo} = inputs(args, memo)
        {apply_op(op, inputs, t, memo.ranges), memo}
    end
  end

  # tensor arguments evaluated, everything else passed through
  defp inputs(args, memo) do
    Enum.map_reduce(args, memo, fn
      %Nx.Tensor{} = t, memo ->
        value(t, memo)

      list, memo when is_list(list) ->
        if Enum.all?(list, &match?(%Nx.Tensor{}, &1)),
          do: Enum.map_reduce(list, memo, &value/2),
          else: {list, memo}

      other, memo ->
        {other, memo}
    end)
  end

  defp apply_op(op, inputs, %Nx.Tensor{shape: shape, type: type}, ranges) do
    case {op, inputs} do
      {:reshape, [a]} ->
        mk(shape, type, a.elems)

      {:squeeze, [a, _]} ->
        mk(shape, type, a.elems)

      {:as_type, [a]} ->
        mk(shape, type, a.elems)

      {:slice, [a, start, lengths, strides]} ->
        unless Enum.all?(start, &is_integer/1),
          do: raise(NotLinear, "slice with a computed start index")

        slice(a, start, lengths, strides, shape, type)

      {:concatenate, [list, axis]} ->
        concatenate(list, axis, shape, type)

      {:broadcast, [a, _shape, axes]} ->
        broadcast(a, axes, shape, type)

      {:transpose, [a, axes]} ->
        transpose(a, axes, shape, type)

      {:add, [a, b]} ->
        zip(a, b, shape, type, &add/2)

      {:subtract, [a, b]} ->
        zip(a, b, shape, type, fn x, y -> add(x, scale(y, -1)) end)

      {:negate, [a]} ->
        mk(shape, type, map(a.elems, &scale(&1, -1)))

      {:multiply, [a, b]} ->
        zip(a, b, shape, type, &mul/2)

      {:left_shift, [a, b]} ->
        zip(a, b, shape, type, fn x, y -> mul(x, %{c: 1 <<< const!(y, "left_shift")}) end)

      {:right_shift, [a, b]} ->
        zip(a, b, shape, type, fn x, y -> shr(x, const!(y, "right_shift")) end)

      {:clip, [a, lo, hi]} ->
        lo = const!(single(lo), "clip")
        hi = const!(single(hi), "clip")
        mk(shape, type, map(a.elems, &clip(&1, lo, hi, ranges)))

      {:dot, [a, ca, ba, b, cb, bb]} ->
        if ba != [] or bb != [], do: raise(NotLinear, "batched dot")
        dot(a, ca, b, cb, shape, type)

      _ ->
        raise NotLinear, "#{op} is not linear (or not supported by the linear analysis)"
    end
  end

  # -- element arithmetic -------------------------------------------------------------

  defp add(%{} = a, %{} = b), do: Map.merge(a, b, fn _, x, y -> x + y end) |> prune()
  defp add(_, _), do: raise(NotLinear, "addition after a rounding step")

  defp scale(%{} = a, k), do: a |> Map.new(fn {key, v} -> {key, v * k} end) |> prune()
  defp scale(_, _), do: raise(NotLinear, "arithmetic after a rounding step")

  defp mul(%{} = a, %{} = b) do
    cond do
      constant?(a) -> scale(b, Map.get(a, :c, 0))
      constant?(b) -> scale(a, Map.get(b, :c, 0))
      true -> raise NotLinear, "product of two inputs"
    end
  end

  defp mul(_, _), do: raise(NotLinear, "product after a rounding step")

  defp shr(%{} = a, 0), do: a

  defp shr(e, k) do
    if constant?(e), do: %{c: Map.get(e, :c, 0) >>> k} |> prune(), else: {:shr, e, k}
  end

  # a clip that cannot change the value (the form's range is inside) is dropped
  defp clip(%{} = e, lo, hi, ranges) do
    {a, b} = range(e, ranges)

    cond do
      a >= lo and b <= hi -> e
      constant?(e) -> %{c: e |> Map.get(:c, 0) |> max(lo) |> min(hi)} |> prune()
      true -> {:clip, e, lo, hi}
    end
  end

  defp clip(e, lo, hi, _ranges), do: {:clip, e, lo, hi}

  defp constant?(%{} = a), do: Enum.all?(Map.keys(a), &(&1 == :c))
  defp constant?(_), do: false

  defp const!(%{} = a, what) do
    if constant?(a), do: Map.get(a, :c, 0), else: raise(NotLinear, "#{what} by a computed amount")
  end

  defp const!(_, what), do: raise(NotLinear, "#{what} by a computed amount")

  defp prune(m), do: m |> Enum.reject(fn {_, v} -> v == 0 end) |> Map.new()

  defp single(%{elems: elems}) do
    case Tuple.to_list(elems) |> Enum.uniq() do
      [e] -> e
      _ -> raise NotLinear, "clip with per-element bounds"
    end
  end

  # -- tensors --------------------------------------------------------------------------

  defp mk(shape, type, elems) when is_list(elems), do: mk(shape, type, List.to_tuple(elems))
  defp mk(shape, type, elems), do: %{shape: shape, type: type, elems: elems}

  defp map(elems, fun), do: elems |> Tuple.to_list() |> Enum.map(fun)

  defp scalar(n) when is_integer(n), do: mk({}, {:s, 64}, [%{c: n} |> prune()])
  defp scalar(n), do: raise(NotLinear, "float constant #{n}")

  defp constant_tensor(%Nx.Tensor{type: type, shape: shape} = t) do
    check_type!(type, :tensor)

    mk(
      shape,
      type,
      t |> Nx.backend_copy(Nx.BinaryBackend) |> Nx.to_flat_list() |> Enum.map(&prune(%{c: &1}))
    )
  end

  defp check_type!({kind, _}, _op) when kind in [:s, :u], do: :ok

  defp check_type!(type, op),
    do: raise(NotLinear, "#{op}: type #{inspect(type)}; the linear analysis needs integers")

  defp type_range({:s, b}), do: {-(1 <<< (b - 1)), (1 <<< (b - 1)) - 1}
  defp type_range({:u, b}), do: {0, (1 <<< b) - 1}

  defp size(shape), do: shape |> Tuple.to_list() |> Enum.product()

  defp strides_of(shape) do
    dims = Tuple.to_list(shape)
    {strides, _} = List.foldr(dims, {[], 1}, fn d, {acc, s} -> {[s | acc], s * d} end)
    strides
  end

  defp coords(shape) do
    dims = Tuple.to_list(shape)

    Enum.reduce(Enum.reverse(dims), [[]], fn d, acc ->
      for i <- 0..(d - 1)//1, rest <- acc, do: [i | rest]
    end)
    |> Enum.sort()
  end

  defp flat(coord, strides),
    do: Enum.zip(coord, strides) |> Enum.map(fn {c, s} -> c * s end) |> Enum.sum()

  defp slice(a, start, _lengths, strides, shape, type) do
    in_strides = strides_of(a.shape)

    elems =
      for c <- coords(shape) do
        src = Enum.zip_with([c, start, strides], fn [i, s, st] -> s + i * st end)
        elem(a.elems, flat(src, in_strides))
      end

    mk(shape, type, elems)
  end

  defp concatenate(list, axis, shape, type) do
    out_strides = strides_of(shape)
    n = size(shape)

    {pairs, _} =
      Enum.flat_map_reduce(list, 0, fn a, offset ->
        pairs =
          for {c, k} <- Enum.with_index(coords(a.shape)) do
            dst = List.update_at(c, axis, &(&1 + offset))
            {flat(dst, out_strides), elem(a.elems, k)}
          end

        {pairs, offset + elem(a.shape, axis)}
      end)

    map = Map.new(pairs)
    mk(shape, type, for(i <- 0..(n - 1)//1, do: Map.fetch!(map, i)))
  end

  defp broadcast(a, axes, shape, type) do
    in_strides = strides_of(a.shape)
    in_dims = Tuple.to_list(a.shape)

    elems =
      for c <- coords(shape) do
        src =
          axes
          |> Enum.zip(in_dims)
          |> Enum.map(fn {ax, d} -> if d == 1, do: 0, else: Enum.at(c, ax) end)

        elem(a.elems, flat(src, in_strides))
      end

    mk(shape, type, elems)
  end

  defp transpose(a, axes, shape, type) do
    in_strides = strides_of(a.shape)

    elems =
      for c <- coords(shape) do
        # output axis i is input axis axes[i]
        src =
          for k <- 0..(tuple_size(a.shape) - 1)//1,
              do: Enum.at(c, Enum.find_index(axes, &(&1 == k)))

        elem(a.elems, flat(src, in_strides))
      end

    mk(shape, type, elems)
  end

  # Nx broadcasting: shapes aligned at the right, size-1 axes repeat.
  defp zip(a, b, shape, type, fun) do
    ea = expand(a, shape)
    eb = expand(b, shape)
    mk(shape, type, Enum.zip_with(ea, eb, fun))
  end

  defp expand(%{shape: s, elems: elems}, s), do: Tuple.to_list(elems)

  defp expand(%{shape: s, elems: elems}, shape) do
    pad = tuple_size(shape) - tuple_size(s)
    dims = List.duplicate(1, pad) ++ Tuple.to_list(s)
    in_strides = strides_of(List.to_tuple(dims))

    for c <- coords(shape) do
      src = Enum.zip_with(c, dims, fn i, d -> if d == 1, do: 0, else: i end)
      elem(elems, flat(src, in_strides))
    end
  end

  defp dot(a, ca, b, cb, shape, type) do
    a_free = Enum.reject(0..(tuple_size(a.shape) - 1)//1, &(&1 in ca))
    b_free = Enum.reject(0..(tuple_size(b.shape) - 1)//1, &(&1 in cb))
    sa = strides_of(a.shape)
    sb = strides_of(b.shape)
    contract = coords(List.to_tuple(Enum.map(ca, &elem(a.shape, &1))))
    na = length(a_free)

    elems =
      for c <- coords(shape) do
        {ia, ib} = Enum.split(c, na)

        Enum.reduce(contract, %{}, fn k, acc ->
          ca_coord = place(a_free, ia, ca, k, tuple_size(a.shape))
          cb_coord = place(b_free, ib, cb, k, tuple_size(b.shape))
          add(acc, mul(elem(a.elems, flat(ca_coord, sa)), elem(b.elems, flat(cb_coord, sb))))
        end)
      end

    mk(shape, type, elems)
  end

  defp place(free, free_idx, contract, k, rank) do
    m = Map.new(Enum.zip(free, free_idx) ++ Enum.zip(contract, k))
    for ax <- 0..(rank - 1)//1, do: Map.fetch!(m, ax)
  end
end
