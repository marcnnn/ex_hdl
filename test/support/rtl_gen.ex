defmodule ExHdl.Test.RTLGen do
  @moduledoc false
  # Random expression trees for the property tests, interpreted twice:
  # into ExHdl.RTL.Expr values (the library) and into {value, type} with
  # plain integers following the width table of docs/rtl_dsl.md (the
  # reference). Operand repairs (signedness, 1-bit conditions) are the
  # same on both sides.
  use ExUnitProperties
  import Bitwise

  alias ExHdl.RTL.Expr

  @inputs [
    a: {:u, 8},
    b: {:u, 8},
    c: {:s, 8},
    d: {:s, 8},
    e: {:u, 3},
    f: {:u, 1},
    g: {:u, 16},
    h: {:s, 5},
    w: {:u, 70}
  ]
  def inputs, do: @inputs

  @bin ~w(add sub add_wrap sub_wrap mul and or xor eq ne lt le gt ge)a
  @un ~w(not neg reduce_and reduce_or reduce_xor as_signed as_unsigned to_signed)a

  def ast do
    leaf =
      one_of([
        map(member_of(Keyword.keys(@inputs)), &{:in, &1}),
        map(integer(-8..20), &{:const, &1})
      ])

    tree(leaf, fn sub ->
      one_of([
        tuple({constant(:bin), member_of(@bin), sub, sub}),
        tuple({constant(:un), member_of(@un), sub}),
        tuple({member_of([:shl, :shr]), sub, integer(0..5)}),
        tuple({member_of([:shl_dyn, :shr_dyn]), sub, sub}),
        tuple({constant(:slice), sub, integer(0..20), integer(1..9)}),
        tuple({constant(:cat), sub, sub}),
        tuple({constant(:mux), sub, sub, sub}),
        tuple({member_of([:trunc, :resize]), sub, integer(1..12)}),
        tuple({constant(:index), sub, sub})
      ])
    end)
  end

  def random_inputs do
    @inputs |> Map.new(fn {n, t} -> {n, int(t)} end) |> fixed_map()
  end

  defp int(t), do: integer(Expr.range(t))

  # -- library side ------------------------------------------------------------------

  # Returns an Expr (top-level constants become typed so they can be outputs).
  def build(ast, handles) do
    case b(ast, handles) do
      v when is_integer(v) -> Expr.const(v, Expr.min_type(v, if(v < 0, do: :s, else: :u)))
      e -> e
    end
  end

  defp b({:in, n}, h), do: h[n]
  defp b({:const, v}, _), do: v

  defp b({:bin, op, x, y}, h) do
    {x, y} = same_sign(b(x, h), b(y, h))

    case op do
      :add -> Expr.add(x, y)
      :sub -> Expr.sub(x, y)
      :add_wrap -> Expr.add_wrap(x, y)
      :sub_wrap -> Expr.sub_wrap(x, y)
      :mul -> Expr.mul(x, y)
      :and -> apply(Expr, :band, Tuple.to_list(typed_pair(x, y)))
      :or -> apply(Expr, :bor, Tuple.to_list(typed_pair(x, y)))
      :xor -> apply(Expr, :bxor, Tuple.to_list(typed_pair(x, y)))
      cmp -> apply(Expr, cmp, [x, y])
    end
  end

  defp b({:un, op, x}, h) do
    x = expr(b(x, h))

    case op do
      :not -> Expr.bnot(x)
      :neg -> Expr.neg(Expr.to_signed(x))
      :reduce_and -> Expr.reduce_and(x)
      :reduce_or -> Expr.reduce_or(x)
      :reduce_xor -> Expr.reduce_xor(x)
      :as_signed -> Expr.as_signed(x)
      :as_unsigned -> Expr.as_unsigned(x)
      :to_signed -> Expr.to_signed(x)
    end
  end

  defp b({:shl, x, n}, h), do: Expr.shl(expr(b(x, h)), n)
  defp b({:shr, x, n}, h), do: Expr.shr(expr(b(x, h)), n)
  defp b({:shl_dyn, x, y}, h), do: Expr.shl(expr(b(x, h)), amount(expr(b(y, h))))
  defp b({:shr_dyn, x, y}, h), do: Expr.shr(expr(b(x, h)), amount(expr(b(y, h))))

  defp b({:slice, x, lo, w}, h) do
    x = expr(b(x, h))
    {lo, w} = clamp_slice(Expr.width(x), lo, w)
    Expr.slice(x, lo, w)
  end

  defp b({:cat, x, y}, h), do: Expr.cat([expr(b(x, h)), expr(b(y, h))])

  defp b({:mux, c, x, y}, h) do
    c = Expr.reduce_or(expr(b(c, h)))
    {x, y} = same_sign(b(x, h), b(y, h))
    {x, y} = typed_pair(x, y)
    Expr.mux(c, x, y)
  end

  defp b({:trunc, x, w}, h) do
    x = expr(b(x, h))
    Expr.trunc(x, min(w, Expr.width(x)))
  end

  defp b({:resize, x, w}, h), do: Expr.resize(expr(b(x, h)), w)
  defp b({:index, x, y}, h), do: Expr.bit(expr(b(x, h)), amount(expr(b(y, h))))

  defp expr(v) when is_integer(v),
    do: Expr.const(v, Expr.min_type(v, if(v < 0, do: :s, else: :u)))

  defp expr(e), do: e

  # Unsigned amount of at most 3 bits.
  defp amount(e) do
    u = Expr.as_unsigned(e)
    Expr.trunc(u, min(Expr.width(u), 3))
  end

  defp clamp_slice(width, lo, w) do
    lo = rem(lo, width)
    {lo, min(w, width - lo)}
  end

  # Both integers: type the first. Mixed signedness: convert y to x's.
  defp same_sign(x, y) when is_integer(x) and is_integer(y),
    do: {Expr.const(x, Expr.min_type(x, int_sign(x, y))), y}

  defp same_sign(x, y) when is_integer(x) do
    if x < 0 and not Expr.signed?(y), do: {x, Expr.to_signed(y)}, else: {x, y}
  end

  defp same_sign(x, y) when is_integer(y) do
    if y < 0 and not Expr.signed?(x), do: {Expr.to_signed(x), y}, else: {x, y}
  end

  defp same_sign(x, y) do
    case {Expr.signed?(x), Expr.signed?(y)} do
      {s, s} -> {x, y}
      {true, false} -> {x, Expr.to_signed(y)}
      {false, true} -> {x, Expr.as_unsigned(y)}
    end
  end

  defp typed_pair(x, %Expr{type: t} = y) when is_integer(x), do: {Expr.wrap(x, t), y}
  defp typed_pair(%Expr{type: t} = x, y) when is_integer(y), do: {x, Expr.wrap(y, t)}
  defp typed_pair(x, y), do: {x, y}

  # -- reference side ----------------------------------------------------------------

  # {value, type}; integers stay {:int, v} until a context types them.
  def ref(ast, ins) do
    case r(ast, ins) do
      {:int, v} -> {v, Expr.min_type(v, if(v < 0, do: :s, else: :u))}
      vt -> vt
    end
  end

  defp r({:in, n}, ins), do: {ins[n], @inputs[n]}
  defp r({:const, v}, _), do: {:int, v}

  defp r({:bin, op, x, y}, ins) do
    {x, y} = rsame(r(x, ins), r(y, ins))

    case op do
      op when op in [:add, :sub, :add_wrap, :sub_wrap, :mul] ->
        {{va, {s, wa}}, {vb, {s, wb}}} = min_typed(x, y)

        {t, v} =
          case op do
            :add -> {{s, max(wa, wb) + 1}, va + vb}
            :sub -> {{s, max(wa, wb) + 1}, va - vb}
            :add_wrap -> {{s, max(wa, wb)}, va + vb}
            :sub_wrap -> {{s, max(wa, wb)}, va - vb}
            :mul -> {{s, wa + wb}, va * vb}
          end

        {Expr.wrap(v, t), t}

      op when op in [:and, :or, :xor] ->
        {{va, {s, wa}}, {vb, {s, wb}}} = other_typed(x, y)
        t = {s, max(wa, wb)}
        f = %{and: &band/2, or: &bor/2, xor: &bxor/2}[op]
        {Expr.wrap(f.(va, vb), t), t}

      cmp ->
        {{va, _}, {vb, _}} = min_typed(x, y)
        f = %{eq: &==/2, ne: &!=/2, lt: &</2, le: &<=/2, gt: &>/2, ge: &>=/2}[cmp]
        {if(f.(va, vb), do: 1, else: 0), {:u, 1}}
    end
  end

  defp r({:un, op, x}, ins) do
    {v, {s, w} = t} = typed(r(x, ins))

    case op do
      :not -> {Expr.wrap(bnot(v), t), t}
      :neg -> if s == :s, do: {-v, {:s, w + 1}}, else: {-v, {:s, w + 2}}
      :reduce_and -> {if(Expr.raw(v, t) == (1 <<< w) - 1, do: 1, else: 0), {:u, 1}}
      :reduce_or -> {if(v != 0, do: 1, else: 0), {:u, 1}}
      :reduce_xor -> {parity(Expr.raw(v, t)), {:u, 1}}
      :as_signed -> {Expr.wrap(Expr.raw(v, t), {:s, w}), {:s, w}}
      :as_unsigned -> {Expr.raw(v, t), {:u, w}}
      :to_signed -> if s == :s, do: {v, t}, else: {v, {:s, w + 1}}
    end
  end

  defp r({:shl, x, n}, ins) do
    {v, {s, w}} = typed(r(x, ins))
    t = {s, w + n}
    {Expr.wrap(v <<< n, t), t}
  end

  defp r({:shr, x, n}, ins) do
    {v, t} = typed(r(x, ins))
    {v >>> n, t}
  end

  defp r({:shl_dyn, x, y}, ins) do
    {v, {s, w}} = typed(r(x, ins))
    {a, wa} = ramount(r(y, ins))
    t = {s, w + (1 <<< wa) - 1}
    {Expr.wrap(v <<< a, t), t}
  end

  defp r({:shr_dyn, x, y}, ins) do
    {v, t} = typed(r(x, ins))
    {a, _} = ramount(r(y, ins))
    {v >>> a, t}
  end

  defp r({:slice, x, lo, w}, ins) do
    {v, {_, xw} = t} = typed(r(x, ins))
    {lo, w} = clamp_slice(xw, lo, w)
    {Expr.raw(v, t) >>> lo &&& (1 <<< w) - 1, {:u, w}}
  end

  defp r({:cat, x, y}, ins) do
    {va, ta} = typed(r(x, ins))
    {vb, {_, wb} = tb} = typed(r(y, ins))
    {Expr.raw(va, ta) <<< wb ||| Expr.raw(vb, tb), {:u, Expr.width(ta) + wb}}
  end

  defp r({:mux, c, x, y}, ins) do
    {vc, _} = typed(r(c, ins))
    {x, y} = rsame(r(x, ins), r(y, ins))
    {{va, {s, wa}}, {vb, {s, wb}}} = other_typed(x, y)
    {if(vc != 0, do: va, else: vb), {s, max(wa, wb)}}
  end

  defp r({:trunc, x, w}, ins) do
    {v, {s, xw}} = typed(r(x, ins))
    t = {s, min(w, xw)}
    {Expr.wrap(v, t), t}
  end

  defp r({:resize, x, w}, ins) do
    {v, {s, _}} = typed(r(x, ins))
    {Expr.wrap(v, {s, w}), {s, w}}
  end

  defp r({:index, x, y}, ins) do
    {v, {_, w} = t} = typed(r(x, ins))
    {a, _} = ramount(r(y, ins))
    {if(a < w, do: Expr.raw(v, t) >>> a &&& 1, else: 0), {:u, 1}}
  end

  defp typed({:int, v}), do: {v, Expr.min_type(v, if(v < 0, do: :s, else: :u))}
  defp typed(vt), do: vt

  defp ramount(x) do
    {v, {_, w} = t} = typed(x)
    wa = min(w, 3)
    {Expr.raw(v, t) &&& (1 <<< wa) - 1, wa}
  end

  defp rsame({:int, v}, {:int, w} = y), do: {{v, Expr.min_type(v, int_sign(v, w))}, y}

  defp rsame({:int, v} = x, {vy, {s, w}} = y) do
    if v < 0 and s == :u, do: {x, {vy, {:s, w + 1}}}, else: {x, y}
  end

  defp rsame({vx, {s, w}} = x, {:int, v} = y) do
    if v < 0 and s == :u, do: {{vx, {:s, w + 1}}, y}, else: {x, y}
  end

  defp rsame({_, {s, _}} = x, {_, {s, _}} = y), do: {x, y}
  defp rsame({_, {:s, _}} = x, {vy, {:u, w}}), do: {x, {vy, {:s, w + 1}}}
  defp rsame(x, {vy, {:s, w} = t}), do: {x, {Expr.raw(vy, t), {:u, w}}}

  defp min_typed({:int, v}, {_, {s, _}} = y), do: {{v, Expr.min_type(v, s)}, y}
  defp min_typed({_, {s, _}} = x, {:int, v}), do: {x, {v, Expr.min_type(v, s)}}
  defp min_typed(x, y), do: {x, y}

  defp other_typed({:int, v}, {_, t} = y), do: {{Expr.wrap(v, t), t}, y}
  defp other_typed({_, t} = x, {:int, v}), do: {x, {Expr.wrap(v, t), t}}
  defp other_typed(x, y), do: {x, y}

  defp int_sign(x, y), do: if(x < 0 or y < 0, do: :s, else: :u)

  defp parity(v), do: rem(Enum.count(Integer.digits(v, 2), &(&1 == 1)), 2)
end
