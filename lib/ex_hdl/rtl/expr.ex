defmodule ExHdl.RTL.WidthError do
  @moduledoc "Raised at elaboration time when an expression breaks a width or signedness rule."
  defexception [:message]
end

defmodule ExHdl.RTL.Assigned do
  @moduledoc """
  Returned by `target <~ value`. Using it as a value means an operator
  with lower precedence than `<~` (`== != < > and or &&& ||| <<< >>>`)
  took the assignment as its operand; every operator rejects it.
  """
  defstruct [:target]

  @doc false
  def raise!(%__MODULE__{target: t}) do
    raise ExHdl.RTL.WidthError,
          "the assignment to #{t} was used as an operand: `<~` binds tighter than " <>
            "== != < <= > >= and or &&& ||| <<< >>>, so write `#{t} <~ (a == b)`"
  end
end

defmodule ExHdl.RTL.Expr do
  @moduledoc """
  Typed hardware expressions and the width rules.

  Every expression has a type `{:u, width}` or `{:s, width}` (two's
  complement). Widths are explicit and exact:

    * Operands of the same signedness are extended losslessly to a common
      width (zero extension for unsigned, sign extension for signed).
    * Signedness never changes implicitly: mixing `u` and `s` raises, use
      `as_signed/1`, `as_unsigned/1` or `to_signed/1`.
    * Nothing narrows implicitly: `trunc/2`, `resize/2` or a slice is
      required, and assignments reject wider right-hand sides.
    * Arithmetic grows: `a + b` and `a - b` are one bit wider than the wider
      operand, `a * b` is `wa + wb` bits. `add_wrap/2` and `sub_wrap/2`
      keep the wider operand's width and wrap.
    * Plain integers adapt: in arithmetic and comparisons an integer gets
      the smallest width that holds it (with the other operand's
      signedness), elsewhere (bitwise ops, muxes, assignments) the other
      operand's type. An integer that does not fit raises.

  Inside `ExHdl.RTL.module/3` bodies the Elixir operators (`+ - * == < &&&
  ||| ~~~ <<< >>>`, `bxor/2`, `and`/`or`/`not`) build expressions; the named
  functions here are imported by `use ExHdl.RTL`.

      iex> import ExHdl.RTL.Expr
      iex> a = const(200, 8)
      iex> add(a, 1).type
      {:u, 9}
      iex> add_wrap(a, 100)
      #RTL<44:u8>
      iex> cat([a, const(1, 1)]).type
      {:u, 9}

  Slices use Access: `a[3]` is bit 3, `a[4..7]` bits 4 to 7 (both
  unsigned; ranges are written low..high as Elixir ranges ascend). A signal index `a[i]` selects a bit dynamically
  (out-of-range indices read 0).
  """

  import Bitwise

  alias ExHdl.RTL.WidthError

  defstruct [:op, :args, :type]

  @type type :: {:u, pos_integer()} | {:s, pos_integer()}
  @type t :: %__MODULE__{op: atom(), args: list(), type: type()}
  @type value :: t() | integer() | boolean()

  @max_width 65_536

  @behaviour Access

  # -- types -----------------------------------------------------------------------------

  @doc "Unsigned type of `width` bits."
  def u(width), do: type!({:u, width})

  @doc "Signed (two's complement) type of `width` bits."
  def s(width), do: type!({:s, width})

  @doc "Normalizes a type: a positive integer means unsigned of that width."
  def type!(w) when is_integer(w), do: type!({:u, w})

  def type!({sign, w} = t) when sign in [:u, :s] and is_integer(w) and w >= 1 and w <= @max_width,
    do: t

  def type!(other),
    do: raise(WidthError, "invalid type #{inspect(other)}; use a width, u(w) or s(w)")

  @doc "Width in bits of an expression or type."
  def width(%__MODULE__{type: {_, w}}), do: w
  def width({_, w}), do: w

  @doc "True for signed expressions or types."
  def signed?(%__MODULE__{type: {s, _}}), do: s == :s
  def signed?({s, _}), do: s == :s

  @doc false
  def input_like(name, type), do: %__MODULE__{op: :sig, args: [name, nil], type: type!(type)}

  # -- constants -------------------------------------------------------------------------

  @doc "A constant of an explicit type. Raises if `value` does not fit."
  def const(value, type) when is_integer(value) do
    type = type!(type)
    check_fits!(value, type, "constant")
    %__MODULE__{op: :const, args: [value], type: type}
  end

  def const(true, type), do: const(1, type)
  def const(false, type), do: const(0, type)

  @doc false
  def label(value, type, label),
    do: %__MODULE__{op: :const, args: [value, label], type: type!(type)}

  @doc "Smallest type with signedness `sign` that holds `value`."
  def min_type(value, :u) when value >= 0, do: {:u, max(bit_length(value), 1)}

  def min_type(value, :u),
    do: raise(WidthError, "negative constant #{value} used with an unsigned operand")

  def min_type(value, :s) when value >= 0, do: {:s, bit_length(value) + 1}
  def min_type(value, :s), do: {:s, bit_length(-value - 1) + 1}

  defp bit_length(0), do: 0
  defp bit_length(v), do: length(Integer.digits(v, 2))

  @doc "Range of values of a type."
  def range({:u, w}), do: 0..((1 <<< w) - 1)
  def range({:s, w}), do: -(1 <<< (w - 1))..((1 <<< (w - 1)) - 1)

  defp check_fits!(value, type, what) do
    unless value in range(type),
      do: raise(WidthError, "#{what} #{value} does not fit #{fmt(type)}")
  end

  @doc "Wraps an integer into the range of a type (two's complement)."
  def wrap(v, {:u, w}), do: v &&& (1 <<< w) - 1

  def wrap(v, {:s, w}) do
    m = v &&& (1 <<< w) - 1
    if m >= 1 <<< (w - 1), do: m - (1 <<< w), else: m
  end

  @doc "Formats a type as `u8` / `s16`."
  def fmt({sign, w}), do: "#{sign}#{w}"

  # -- coercion --------------------------------------------------------------------------

  @doc false
  # Turns an operand into an expression; integers need a context type.
  def lift(%__MODULE__{} = e, _ctx), do: e
  def lift(true, _), do: const(1, {:u, 1})
  def lift(false, _), do: const(0, {:u, 1})
  def lift(v, {:min, sign}) when is_integer(v), do: const(v, min_type(v, sign))
  def lift(v, {_, _} = type) when is_integer(v), do: const(v, type)

  def lift(v, nil) when is_integer(v),
    do: raise(WidthError, "integer #{v} needs a width here; use const(#{v}, width)")

  def lift(%ExHdl.RTL.Assigned{} = a, _), do: ExHdl.RTL.Assigned.raise!(a)

  def lift(%{__bundle__: _}, _),
    do: raise(WidthError, "a bundle is not an expression; use connect/2 or a field")

  def lift(nil, _),
    do:
      raise(
        WidthError,
        "not a hardware expression: nil. Inside module/3 and rtl/1 the operators and `if` " <>
          "build hardware when an operand is hardware; test generator values (such as an " <>
          "accumulator that starts as nil) with is_nil/1, case or Kernel.==/2"
      )

  def lift(other, _), do: raise(WidthError, "not a hardware expression: #{inspect(other)}")

  @doc false
  # Lifts both operands of a binary operator. `mode` is :min (integers get
  # the smallest width) or :same (integers take the other operand's type).
  def pair(a, b, mode, op) do
    case {a, b} do
      {%__MODULE__{}, %__MODULE__{}} ->
        same_sign!(a, b, op)

      {%__MODULE__{type: {sign, _} = t}, _} ->
        same_sign!(a, lift(b, ctx(mode, sign, t)), op)

      {_, %__MODULE__{type: {sign, _} = t}} ->
        same_sign!(lift(a, ctx(mode, sign, t)), b, op)

      _ ->
        {lift(a, nil), lift(b, nil)}
    end
  end

  defp ctx(:min, sign, _t), do: {:min, sign}
  defp ctx(:same, _sign, t), do: t

  defp same_sign!(%{type: {s, _}} = a, %{type: {s, _}} = b, _op), do: {a, b}

  defp same_sign!(a, b, op) do
    raise WidthError,
          "#{op}: operands have different signedness (#{fmt(a.type)} and #{fmt(b.type)}); " <>
            "convert one with as_signed/1, as_unsigned/1 or to_signed/1"
  end

  @doc false
  # Coerces `value` for assignment to (or use as) `type`: same signedness,
  # not wider. `what` names the destination in error messages.
  def coerce!(value, {sign, w} = type, what) do
    e = lift(value, type)

    case e.type do
      ^type ->
        e

      {^sign, ew} when ew < w ->
        extend(e, w)

      {^sign, ew} ->
        raise WidthError,
              "#{what}: #{fmt(e.type)} value does not fit #{fmt(type)} " <>
                "(#{ew - w} bit(s) too wide); use trunc/2 or resize/2"

      _ ->
        raise WidthError,
              "#{what}: #{fmt(e.type)} value for #{fmt(type)}; signedness differs, " <>
                "use as_signed/1, as_unsigned/1 or to_signed/1"
    end
  end

  defp extend(%{type: {_, w}} = e, w), do: e

  defp extend(%{op: :const, args: [v | _], type: {sign, _}}, w),
    do: %__MODULE__{op: :const, args: [v], type: {sign, w}}

  defp extend(%{type: {sign, _}} = e, w), do: %__MODULE__{op: :resize, args: [e], type: {sign, w}}

  defp node(op, args, type) do
    type!(type)
    fold(%__MODULE__{op: op, args: args, type: type})
  end

  # Constant folding: operations on constants become constants, and
  # operands that make the result constant (or one operand) are applied,
  # so no dead logic reaches the backends.
  defp fold(%__MODULE__{op: op} = e) when op in [:sig, :const, :mem_read], do: e

  defp fold(%__MODULE__{args: args, type: t} = e) do
    if Enum.all?(sub_args(args), &plain_const?/1) do
      %__MODULE__{op: :const, args: [eval(e, fn _ -> 0 end)], type: t}
    else
      fold_partial(e)
    end
  end

  defp sub_args(args),
    do:
      Enum.flat_map(args, fn
        %__MODULE__{} = a -> [a]
        l when is_list(l) -> sub_args(l)
        _ -> []
      end)

  defp plain_const?(%__MODULE__{op: :const, args: [_]}), do: true
  defp plain_const?(_), do: false

  defp cval(%__MODULE__{op: :const, args: [v]}), do: v
  defp cval(_), do: nil

  defp fold_partial(%__MODULE__{op: :mux, args: [c, a, b], type: {_, w}} = e) do
    case cval(c) do
      1 -> extend(a, w)
      0 -> extend(b, w)
      nil -> if a == b, do: extend(a, w), else: e
    end
  end

  defp fold_partial(%__MODULE__{op: :muxn, args: [sel, items, d], type: _} = e) do
    case cval(sel) do
      nil -> e
      i -> Enum.at(items, i, d)
    end
  end

  defp fold_partial(%__MODULE__{op: :index, args: [a, i]} = e) do
    w = width(a.type)
    _..hi//_ = range(i.type)

    case {cval(a), cval(i)} do
      {_, i} when is_integer(i) and i < w ->
        slice(a, i, 1)

      {_, i} when is_integer(i) ->
        const(0, {:u, 1})

      {0, _} ->
        const(0, {:u, 1})

      # out-of-range indices read 0, so all ones only folds if none can occur
      {c, _} when is_integer(c) and hi < w ->
        if c == wrap(-1, a.type), do: const(1, {:u, 1}), else: e

      _ ->
        e
    end
  end

  defp fold_partial(%__MODULE__{op: op, args: [a, b], type: t} = e)
       when op in [:land, :lor, :and, :or, :mul] do
    {w, all} = {width(t), wrap(-1, t)}

    case {op, cval(a), cval(b)} do
      {:land, 0, _} -> const(0, t)
      {:land, _, 0} -> const(0, t)
      {:land, 1, _} -> b
      {:land, _, 1} -> a
      {:lor, 1, _} -> const(1, t)
      {:lor, _, 1} -> const(1, t)
      {:lor, 0, _} -> b
      {:lor, _, 0} -> a
      {:and, 0, _} -> const(0, t)
      {:and, _, 0} -> const(0, t)
      {:or, ^all, _} -> const(all, t)
      {:or, _, ^all} -> const(all, t)
      {:or, 0, _} -> extend(b, w)
      {:or, _, 0} -> extend(a, w)
      {:mul, 0, _} -> const(0, t)
      {:mul, _, 0} -> const(0, t)
      _ -> e
    end
  end

  defp fold_partial(%__MODULE__{op: :shr_dyn, args: [a, b], type: t} = e) do
    case {cval(a), cval(b)} do
      {0, _} -> const(0, t)
      {_, nil} -> e
      {_, n} -> shr(a, n)
    end
  end

  defp fold_partial(%__MODULE__{op: :shl_dyn, args: [a, b], type: {_, w} = t} = e) do
    case {cval(a), cval(b)} do
      {0, _} -> const(0, t)
      {_, nil} -> e
      {_, n} -> extend(shl(a, n), w)
    end
  end

  # A comparison that is constant over the non-constant operand's range.
  defp fold_partial(%__MODULE__{op: op, args: [a, b]} = e)
       when op in [:eq, :ne, :lt, :le, :gt, :ge] do
    case {cval(a), cval(b)} do
      {nil, nil} -> e
      {nil, c} -> const_compare(e, op, range(a.type), c, false)
      {c, nil} -> const_compare(e, op, range(b.type), c, true)
    end
  end

  defp fold_partial(e), do: e

  defp const_compare(e, op, lo..hi//_, c, swapped) do
    f = fn x ->
      {l, r} = if swapped, do: {c, x}, else: {x, c}

      case op do
        :eq -> l == r
        :ne -> l != r
        :lt -> l < r
        :le -> l <= r
        :gt -> l > r
        :ge -> l >= r
      end
    end

    constant =
      case op do
        :eq -> if c in lo..hi, do: nil, else: false
        :ne -> if c in lo..hi, do: nil, else: true
        _ -> if f.(lo) == f.(hi), do: f.(lo), else: nil
      end

    case constant do
      nil -> e
      true -> const(1, {:u, 1})
      false -> const(0, {:u, 1})
    end
  end

  # -- arithmetic ------------------------------------------------------------------------

  @doc "Exact sum: one bit wider than the wider operand."
  def add(a, b), do: arith(:add, a, b, 1, "+")

  @doc "Difference, one bit wider than the wider operand. Unsigned results wrap (top bit = borrow)."
  def sub(a, b), do: arith(:sub, a, b, 1, "-")
  @doc "Sum in the wider operand's width, wrapping."
  def add_wrap(a, b), do: arith(:add, a, b, 0, "add_wrap")
  @doc "Difference in the wider operand's width, wrapping."
  def sub_wrap(a, b), do: arith(:sub, a, b, 0, "sub_wrap")

  defp arith(op, a, b, grow, name) do
    {a, b} = pair(a, b, :min, name)
    {sign, _} = a.type
    node(op, [a, b], {sign, max(width(a), width(b)) + grow})
  end

  @doc "Exact product, `wa + wb` bits."
  def mul(a, b) do
    {a, b} = pair(a, b, :min, "*")
    {sign, _} = a.type
    node(:mul, [a, b], {sign, width(a) + width(b)})
  end

  @doc "Exact negation of a signed value, one bit wider."
  def neg(%__MODULE__{type: {:s, w}} = a), do: node(:neg, [a], {:s, w + 1})

  def neg(%__MODULE__{type: t}),
    do: raise(WidthError, "negation of unsigned #{fmt(t)}; use to_signed/1 first")

  def neg(v), do: raise(WidthError, "negation of #{inspect(v)}")

  # -- bitwise ---------------------------------------------------------------------------

  @doc "Bitwise and, width of the wider operand."
  def band(a, b), do: bitwise(:and, a, b, "&&&")
  @doc "Bitwise or."
  def bor(a, b), do: bitwise(:or, a, b, "|||")
  @doc "Bitwise xor (Elixir 1.18 deprecates `^^^`)."
  def bxor(a, b) when is_integer(a) and is_integer(b), do: Bitwise.bxor(a, b)
  def bxor(a, b), do: bitwise(:xor, a, b, "bxor")

  defp bitwise(op, a, b, name) do
    {a, b} = pair(a, b, :same, name)
    {sign, _} = a.type
    node(op, [a, b], {sign, max(width(a), width(b))})
  end

  @doc "Bitwise not, same type."
  def bnot(a) do
    a = lift(a, nil)
    node(:not, [a], a.type)
  end

  @doc "And-reduction to one bit."
  def reduce_and(a), do: node(:reduce_and, [lift(a, nil)], {:u, 1})
  @doc "Or-reduction to one bit (true if any bit is set)."
  def reduce_or(a), do: node(:reduce_or, [lift(a, nil)], {:u, 1})
  @doc "Xor-reduction (parity) to one bit."
  def reduce_xor(a), do: node(:reduce_xor, [lift(a, nil)], {:u, 1})

  @doc "Logical and of two 1-bit values."
  def land(a, b), do: logic(:land, a, b, "and")
  @doc "Logical or of two 1-bit values."
  def lor(a, b), do: logic(:lor, a, b, "or")

  @doc "Logical not of a 1-bit value."
  def lnot(a) do
    a = bit!(lift(a, {:u, 1}), "not")
    node(:lnot, [a], {:u, 1})
  end

  defp logic(op, a, b, name) do
    a = bit!(lift(a, {:u, 1}), name)
    b = bit!(lift(b, {:u, 1}), name)
    node(op, [a, b], {:u, 1})
  end

  @doc false
  def bit!(%__MODULE__{type: {:u, 1}} = e, _what), do: e

  def bit!(%__MODULE__{type: t}, what),
    do:
      raise(WidthError, "#{what}: needs a 1-bit unsigned value, got #{fmt(t)}; compare with != 0")

  # -- shifts ----------------------------------------------------------------------------

  @doc """
  Left shift. By an integer `n`: exact, `wa + n` bits. By an unsigned
  signal `b`: exact, `wa + 2^wb - 1` bits.
  """
  def shl(a, n) when is_integer(n) and n >= 0 do
    a = lift(a, nil)
    {sign, w} = a.type
    if n == 0, do: a, else: node(:shl, [a, n], {sign, w + n})
  end

  def shl(a, %__MODULE__{type: {:u, wb}} = b) do
    a = lift(a, nil)
    {sign, w} = a.type
    node(:shl_dyn, [a, b], {sign, w + (1 <<< wb) - 1})
  end

  def shl(_a, b),
    do:
      raise(
        WidthError,
        "shift amount must be a non-negative integer or unsigned, got #{inspect(b)}"
      )

  @doc "Right shift keeping the width (arithmetic for signed values)."
  def shr(a, n) when is_integer(n) and n >= 0 do
    a = lift(a, nil)
    if n == 0, do: a, else: node(:shr, [a, n], a.type)
  end

  def shr(a, %__MODULE__{type: {:u, _}} = b) do
    a = lift(a, nil)
    node(:shr_dyn, [a, b], a.type)
  end

  def shr(_a, b),
    do:
      raise(
        WidthError,
        "shift amount must be a non-negative integer or unsigned, got #{inspect(b)}"
      )

  # -- comparison ------------------------------------------------------------------------

  for op <- [:eq, :ne, :lt, :le, :gt, :ge] do
    @doc "Comparison `#{op}`, 1-bit result; operands need the same signedness."
    def unquote(op)(a, b) do
      {a, b} = pair(a, b, :min, unquote(Atom.to_string(op)))
      node(unquote(op), [a, b], {:u, 1})
    end
  end

  # -- selection -------------------------------------------------------------------------

  @doc """
  `mux(c, a, b)` is `a` when the 1-bit `c` is 1, else `b` (same signedness,
  result in the wider width). `mux(sel, list)` selects `list[sel]`; indices
  past the end of the list read `default` (option, default 0).

  Integers take the type of the expression operands. When there is none
  (`mux(c, 4, 3)`, a table of plain integers) they get the smallest type
  holding all of them, signed if one is negative: `mux(c, 4, 3)` is `u3`.
  """
  def mux(sel, list) when is_list(list), do: mux(sel, list, [])

  def mux(sel, list, opts) when is_list(list) and is_list(opts), do: mux_list(sel, list, opts)

  def mux(c, a, b) when is_integer(a) and is_integer(b) do
    t = const_type([a, b])
    mux(c, const(a, t), const(b, t))
  end

  def mux(c, a, b) do
    c = bit!(lift(c, {:u, 1}), "mux condition")
    {a, b} = pair(a, b, :same, "mux")
    {sign, _} = a.type
    node(:mux, [c, a, b], {sign, max(width(a), width(b))})
  end

  defp mux_list(_sel, [], _opts), do: raise(WidthError, "mux list is empty")

  defp mux_list(sel, list, opts) do
    sel = lift(sel, nil)

    unless match?({:u, _}, sel.type),
      do: raise(WidthError, "mux selector must be unsigned, got #{fmt(sel.type)}")

    exprs = Enum.filter(list, &match?(%__MODULE__{}, &1))

    exprs =
      cond do
        exprs != [] ->
          exprs

        Enum.all?(list, &is_integer/1) ->
          # a table of plain integers: the smallest type holding all of them
          [const(0, const_type(list))]

        true ->
          raise WidthError, "mux list needs an expression or only integers to define the type"
      end

    {sign, _} = hd(exprs).type

    Enum.each(exprs, fn e ->
      unless signed?(e) == (sign == :s),
        do: raise(WidthError, "mux list mixes signed and unsigned values")
    end)

    w = exprs |> Enum.map(&width/1) |> Enum.max()
    t = {sign, w}
    items = Enum.map(list, &coerce!(&1, t, "mux item"))
    default = coerce!(Keyword.get(opts, :default, 0), t, "mux default")

    if length(items) > 1 <<< width(sel),
      do:
        raise(WidthError, "mux list has #{length(items)} items, selector has #{width(sel)} bits")

    node(:muxn, [sel, items, default], t)
  end

  # Smallest common type of integer constants (signed if one is negative).
  defp const_type(values) do
    sign = if Enum.any?(values, &(&1 < 0)), do: :s, else: :u
    {sign, values |> Enum.map(&width(min_type(&1, sign))) |> Enum.max()}
  end

  @doc """
  Concatenation, first element in the most significant bits (as SV `{a, b}`). Unsigned.

  `nil` items are skipped: they are the zero-width pieces `slice(a, lo, 0)`,
  `rep(a, 0)` and `cat([])` return, so generator code needs no special case
  for an empty field. A concatenation of no items is `nil` itself.
  """
  def cat(list) when is_list(list) do
    case Enum.reject(list, &is_nil/1) do
      [] ->
        nil

      list ->
        items = Enum.map(list, &lift(&1, nil))
        node(:cat, [items], {:u, items |> Enum.map(&width/1) |> Enum.sum()})
    end
  end

  @doc "`n` copies of `a` concatenated. Unsigned; `n = 0` gives the zero-width `nil` (see `cat/1`)."
  def rep(_a, 0), do: nil

  def rep(a, n) when is_integer(n) and n >= 1 do
    a = lift(a, nil)
    node(:rep, [a, n], {:u, width(a) * n})
  end

  @doc """
  Bits `lo` to `lo + width - 1` of `a`, unsigned. `w = 0` (with `lo` at most
  the width of `a`) gives the zero-width `nil`, which `cat/1` skips.
  """
  def slice(a, lo, 0) when is_integer(lo) and lo >= 0 do
    a = lift(a, nil)

    if lo > width(a),
      do: raise(WidthError, "empty slice at bit #{lo} out of range for #{fmt(a.type)} value")

    nil
  end

  def slice(a, lo, w) when is_integer(lo) and is_integer(w) and lo >= 0 and w >= 1 do
    a = lift(a, nil)

    if lo + w > width(a),
      do:
        raise(
          WidthError,
          "slice [#{lo + w - 1}:#{lo}] out of range for #{fmt(a.type)} value"
        )

    node(:slice, [a, lo, w], {:u, w})
  end

  @doc """
  Indexed part select, SystemVerilog `a[sel +: w]`: `w` bits of `a`
  starting at bit `sel` (an integer or an unsigned signal), unsigned.
  Bits beyond the top of `a` read 0. A signal `sel` builds a right
  shifter; for byte lanes scale it with a constant shift
  (`part(word, lane <<< 3, 8)`).
  """
  def part(a, sel, w) when is_integer(w) and w >= 1 do
    a = a |> lift(nil) |> as_unsigned()
    aw = width(a)

    case sel do
      s when is_integer(s) and s >= aw ->
        const(0, {:u, w})

      0 when w >= aw ->
        resize(a, w)

      s when is_integer(s) and s >= 0 ->
        resize(slice(a, s, min(w, aw - s)), w)

      %__MODULE__{type: {:u, _}} ->
        shifted = shr(a, sel)
        if w <= aw, do: slice(shifted, 0, w), else: zext(shifted, w)

      other ->
        raise WidthError,
              "part/3: start bit must be a non-negative integer or unsigned, got #{inspect(other)}"
    end
  end

  @doc "Bit `i` of `a` (1-bit unsigned); `i` may be an unsigned signal."
  def bit(a, i) when is_integer(i), do: slice(a, i, 1)

  def bit(a, %__MODULE__{type: {:u, _}} = i), do: node(:index, [lift(a, nil), i], {:u, 1})

  def bit(_a, i),
    do: raise(WidthError, "bit index must be an integer or unsigned, got #{inspect(i)}")

  @impl Access
  def fetch(%__MODULE__{} = e, i) when is_integer(i), do: {:ok, bit(e, i)}

  def fetch(%__MODULE__{} = e, %Range{first: lo, last: hi, step: 1}) when hi >= lo - 1,
    do: {:ok, slice(e, lo, hi - lo + 1)}

  def fetch(%__MODULE__{} = e, %Range{first: hi, last: lo, step: -1}) when hi >= lo,
    do: {:ok, slice(e, lo, hi - lo + 1)}

  def fetch(%__MODULE__{}, %Range{} = r),
    do: raise(WidthError, "slice #{inspect(r)}: write bit ranges low..high, e.g. a[0..7]")

  def fetch(%__MODULE__{} = e, %__MODULE__{} = i), do: {:ok, bit(e, i)}

  @impl Access
  def get_and_update(_, _, _), do: raise(WidthError, "slices cannot be updated; use cat/1")

  @impl Access
  def pop(_, _), do: raise(WidthError, "slices cannot be popped")

  # -- width conversion ------------------------------------------------------------------

  @doc "Drops high bits: `w` must not exceed the width. Keeps signedness."
  def trunc(a, w) do
    a = lift(a, nil)
    {sign, aw} = a.type

    if w > aw,
      do: raise(WidthError, "trunc to #{w} bits of a #{aw}-bit value; use zext/sext/resize")

    if w == aw, do: a, else: node(:resize, [a], {sign, w})
  end

  @doc "Zero-extends an unsigned value to `w >= width` bits."
  def zext(a, w) do
    a = lift(a, nil)

    case a.type do
      {:u, aw} when w >= aw -> extend(a, w)
      {:u, aw} -> raise WidthError, "zext to #{w} bits of a #{aw}-bit value; use trunc/2"
      t -> raise WidthError, "zext of signed #{fmt(t)}; use sext/2 or as_unsigned/1"
    end
  end

  @doc "Sign-extends a signed value to `w >= width` bits."
  def sext(a, w) do
    a = lift(a, nil)

    case a.type do
      {:s, aw} when w >= aw -> extend(a, w)
      {:s, aw} -> raise WidthError, "sext to #{w} bits of a #{aw}-bit value; use trunc/2"
      t -> raise WidthError, "sext of unsigned #{fmt(t)}; use zext/2 or as_signed/1"
    end
  end

  @doc "Extends (by signedness) or truncates to `w` bits. The explicit escape hatch."
  def resize(a, w) do
    a = lift(a, nil)
    type!({:u, w})
    {sign, aw} = a.type

    cond do
      w == aw -> a
      w > aw -> extend(a, w)
      true -> node(:resize, [a], {sign, w})
    end
  end

  @doc "Reinterprets the bits as signed, same width."
  def as_signed(a) do
    a = lift(a, nil)
    if signed?(a), do: a, else: node(:cast, [a], {:s, width(a)})
  end

  @doc "Reinterprets the bits as unsigned, same width."
  def as_unsigned(a) do
    a = lift(a, nil)
    if signed?(a), do: node(:cast, [a], {:u, width(a)}), else: a
  end

  @doc "Lossless conversion of an unsigned value to signed (one bit wider)."
  def to_signed(a) do
    a = lift(a, nil)
    if signed?(a), do: a, else: as_signed(zext(a, width(a) + 1))
  end

  # -- reads -----------------------------------------------------------------------------

  @doc false
  # Signal names read by an expression (with their owners), in first-use order.
  def reads(e, acc \\ [])
  def reads(%__MODULE__{op: :sig, args: [name, _]}, acc), do: [name | acc]
  def reads(%__MODULE__{op: :const}, acc), do: acc
  def reads(%__MODULE__{op: :mem_read, args: [_mem, addr]}, acc), do: reads(addr, acc)
  def reads(%__MODULE__{args: args}, acc), do: Enum.reduce(args, acc, &reads_arg/2)

  defp reads_arg(%__MODULE__{} = e, acc), do: reads(e, acc)
  defp reads_arg(list, acc) when is_list(list), do: Enum.reduce(list, acc, &reads_arg/2)
  defp reads_arg(_, acc), do: acc

  @doc false
  def owners(e, acc \\ [])
  def owners(%__MODULE__{op: :sig, args: [name, owner]}, acc), do: [{name, owner} | acc]
  def owners(%__MODULE__{args: args}, acc), do: Enum.reduce(args, acc, &owners_arg/2)

  defp owners_arg(%__MODULE__{} = e, acc), do: owners(e, acc)
  defp owners_arg(list, acc) when is_list(list), do: Enum.reduce(list, acc, &owners_arg/2)
  defp owners_arg(_, acc), do: acc

  @doc false
  def memories(e, acc \\ [])

  def memories(%__MODULE__{op: :mem_read, args: [mem, addr]}, acc),
    do: memories(addr, [mem | acc])

  def memories(%__MODULE__{args: args}, acc), do: Enum.reduce(args, acc, &mems_arg/2)

  defp mems_arg(%__MODULE__{} = e, acc), do: memories(e, acc)
  defp mems_arg(list, acc) when is_list(list), do: Enum.reduce(list, acc, &mems_arg/2)
  defp mems_arg(_, acc), do: acc

  # -- evaluation ------------------------------------------------------------------------

  @doc """
  Evaluates an expression with `lookup.(name)` giving signal values (and
  `mem.(name, addr)` memory words). The reference semantics shared by the
  simulator and the SystemVerilog backend.
  """
  def eval(%__MODULE__{op: op, args: args, type: t}, lookup, mem \\ fn _, _ -> 0 end) do
    ev = &eval(&1, lookup, mem)

    case {op, args} do
      {:sig, [name, _]} ->
        lookup.(name)

      {:const, [v | _]} ->
        v

      {:add, [a, b]} ->
        wrap(ev.(a) + ev.(b), t)

      {:sub, [a, b]} ->
        wrap(ev.(a) - ev.(b), t)

      {:mul, [a, b]} ->
        wrap(ev.(a) * ev.(b), t)

      {:neg, [a]} ->
        wrap(-ev.(a), t)

      {:and, [a, b]} ->
        wrap(Bitwise.band(ev.(a), ev.(b)), t)

      {:or, [a, b]} ->
        wrap(Bitwise.bor(ev.(a), ev.(b)), t)

      {:xor, [a, b]} ->
        wrap(Bitwise.bxor(ev.(a), ev.(b)), t)

      {:not, [a]} ->
        wrap(Bitwise.bnot(ev.(a)), t)

      {:land, [a, b]} ->
        Bitwise.band(ev.(a), ev.(b))

      {:lor, [a, b]} ->
        Bitwise.bor(ev.(a), ev.(b))

      {:lnot, [a]} ->
        1 - ev.(a)

      {:reduce_and, [a]} ->
        if(raw(ev.(a), a.type) == (1 <<< width(a)) - 1, do: 1, else: 0)

      {:reduce_or, [a]} ->
        if(ev.(a) != 0, do: 1, else: 0)

      {:reduce_xor, [a]} ->
        parity(raw(ev.(a), a.type))

      {:shl, [a, n]} ->
        wrap(ev.(a) <<< n, t)

      {:shr, [a, n]} ->
        wrap(ev.(a) >>> n, t)

      {:shl_dyn, [a, b]} ->
        wrap(ev.(a) <<< ev.(b), t)

      {:shr_dyn, [a, b]} ->
        wrap(ev.(a) >>> ev.(b), t)

      {:eq, [a, b]} ->
        bool(ev.(a) == ev.(b))

      {:ne, [a, b]} ->
        bool(ev.(a) != ev.(b))

      {:lt, [a, b]} ->
        bool(ev.(a) < ev.(b))

      {:le, [a, b]} ->
        bool(ev.(a) <= ev.(b))

      {:gt, [a, b]} ->
        bool(ev.(a) > ev.(b))

      {:ge, [a, b]} ->
        bool(ev.(a) >= ev.(b))

      {:mux, [c, a, b]} ->
        if(ev.(c) == 1, do: ev.(a), else: ev.(b))

      {:muxn, [sel, items, d]} ->
        ev.(Enum.at(items, ev.(sel), d))

      {:cat, [items]} ->
        Enum.reduce(items, 0, fn i, acc -> acc <<< width(i) ||| raw(ev.(i), i.type) end)

      {:rep, [a, n]} ->
        rep_bits(raw(ev.(a), a.type), width(a), n)

      {:slice, [a, lo, w]} ->
        raw(ev.(a), a.type) >>> lo &&& (1 <<< w) - 1

      {:index, [a, i]} ->
        idx(ev.(a), a.type, ev.(i))

      {:resize, [a]} ->
        wrap(ev.(a), t)

      {:cast, [a]} ->
        wrap(raw(ev.(a), a.type), t)

      {:mem_read, [m, addr]} ->
        mem.(m, ev.(addr))
    end
  end

  defp idx(v, {_, w} = t, i) when i < w, do: raw(v, t) >>> i &&& 1
  defp idx(_v, _t, _i), do: 0

  @doc false
  def raw(v, {_, w}), do: v &&& (1 <<< w) - 1

  defp bool(true), do: 1
  defp bool(false), do: 0

  defp parity(0), do: 0
  defp parity(v), do: rem(Enum.count(Integer.digits(v, 2), &(&1 == 1)), 2)

  defp rep_bits(v, w, n), do: Enum.reduce(1..n, 0, fn _, acc -> acc <<< w ||| v end)
end

defimpl Inspect, for: ExHdl.RTL.Expr do
  def inspect(%{op: :sig, args: [name, _], type: t}, _),
    do: "#RTL<#{name}:#{ExHdl.RTL.Expr.fmt(t)}>"

  def inspect(%{op: :const, args: [v | _], type: t}, _),
    do: "#RTL<#{v}:#{ExHdl.RTL.Expr.fmt(t)}>"

  def inspect(%{op: op, type: t}, _), do: "#RTL<#{op}:#{ExHdl.RTL.Expr.fmt(t)}>"
end
