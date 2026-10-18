defmodule ExHdl.Types.IntSet do
  @moduledoc """
  Sets of integers as a set-theoretic type domain.

  A set is a sorted list of disjoint, non-adjacent closed intervals
  `{lo, hi}`, where `lo` may be `:neg_inf` and `hi` may be `:pos_inf`. The
  representation is canonical, so `equal?/2` is structural equality, and it
  is closed under union, intersection and negation (complement within
  `integer()`). This is the integer counterpart of how
  `Module.Types.Descr` stores atoms as finite or cofinite sets.

  Besides the set algebra, this module has the arithmetic transfer functions
  used by `ExHdl.Passes.WidthCheck` (`add/2`, `multiply/2`, ...). They take
  finite sets and return a superset of `{f(x, y) | x in a, y in b}` (exact
  for most ops). Results are kept to at most `max_intervals/0` intervals by
  `widen/2`, which only ever adds values.
  """
  @behaviour ExHdl.Types.SetAlgebra

  import Bitwise
  import Kernel, except: [min: 2, max: 2, abs: 1]

  @type bound :: integer() | :neg_inf | :pos_inf
  @type t :: [{bound(), bound()}]

  @max_intervals 64

  @doc "Upper bound on intervals kept by the arithmetic operations."
  def max_intervals, do: @max_intervals

  # -- constructors -------------------------------------------------------------

  @impl true
  def none, do: []
  @impl true
  def term, do: [{:neg_inf, :pos_inf}]
  def integer, do: term()
  def non_neg_integer, do: [{0, :pos_inf}]
  def pos_integer, do: [{1, :pos_inf}]
  def neg_integer, do: [{:neg_inf, -1}]

  def singleton(k) when is_integer(k), do: [{k, k}]

  def range(lo, hi) when is_integer(lo) and is_integer(hi) and lo <= hi, do: [{lo, hi}]
  def range(lo, hi) when is_integer(lo) and is_integer(hi), do: []

  def from_range(lo..hi//1), do: range(lo, hi)

  def from_list(ints) do
    ints
    |> Enum.sort()
    |> Enum.dedup()
    |> Enum.map(&{&1, &1})
    |> normalize_sorted()
  end

  @doc "All values of an Nx integer type, e.g. `{:s, 16}`."
  def of_type({:s, bits}), do: range(-(1 <<< (bits - 1)), (1 <<< (bits - 1)) - 1)
  def of_type({:u, bits}), do: range(0, (1 <<< bits) - 1)

  @impl true
  def leaf({:int, :neg_inf, :pos_inf}), do: integer()
  def leaf({:int, lo, :pos_inf}), do: [{lo, :pos_inf}]
  def leaf({:int, :neg_inf, hi}), do: [{:neg_inf, hi}]
  def leaf({:int, lo, hi}), do: range(lo, hi)
  def leaf(:integer), do: integer()
  def leaf(:term), do: term()
  def leaf(:none), do: none()

  # -- set algebra ----------------------------------------------------------------

  @impl true
  def union(a, b), do: (a ++ b) |> Enum.sort_by(&elem(&1, 0), &le/2) |> normalize_sorted()

  @impl true
  def intersection([], _), do: []
  def intersection(_, []), do: []

  def intersection([{a_lo, a_hi} | a_rest] = a, [{b_lo, b_hi} | b_rest] = b) do
    lo = max_b(a_lo, b_lo)
    hi = min_b(a_hi, b_hi)
    tail = if le(a_hi, b_hi), do: intersection(a_rest, b), else: intersection(a, b_rest)
    if le(lo, hi), do: [{lo, hi} | tail], else: tail
  end

  @impl true
  def negation(set), do: complement(set, :neg_inf)

  defp complement([], from), do: [{from, :pos_inf}]
  defp complement([{:neg_inf, hi} | rest], :neg_inf), do: complement_after(rest, hi)
  defp complement([{lo, hi} | rest], from), do: [{from, pred(lo)} | complement_after(rest, hi)]

  defp complement_after(_rest, :pos_inf), do: []
  defp complement_after(rest, hi), do: complement(rest, succ(hi))

  @impl true
  def difference(a, b), do: intersection(a, negation(b))

  @impl true
  def empty?(set), do: set == []

  @impl true
  def subtype?(a, b), do: difference(a, b) == []

  @impl true
  def equal?(a, b), do: a == b

  def disjoint?(a, b), do: intersection(a, b) == []

  @impl true
  def member?(set, k) when is_integer(k),
    do: Enum.any?(set, fn {lo, hi} -> le(lo, k) and le(k, hi) end)

  def member?(_set, _), do: false

  @doc "Number of elements, or `:infinity`."
  def size(set) do
    Enum.reduce_while(set, 0, fn
      {lo, hi}, acc when is_integer(lo) and is_integer(hi) -> {:cont, acc + hi - lo + 1}
      _, _ -> {:halt, :infinity}
    end)
  end

  @doc "`{min, max}` of a non-empty set."
  def bounds([{lo, _} | _] = set), do: {lo, set |> List.last() |> elem(1)}

  @doc """
  Smallest `{:u, bits}` or `{:s, bits}` (two's complement) holding every
  value of a finite set.
  """
  def bit_width([]), do: {:u, 1}

  def bit_width(set) do
    {lo, hi} = bounds(finite!(set))

    if lo >= 0,
      do: {:u, Kernel.max(1, bit_length(hi))},
      else: {:s, Kernel.max(bit_length(-lo - 1), bit_length(Kernel.max(hi, 0))) + 1}
  end

  def to_list(set), do: Enum.flat_map(set, fn {lo, hi} -> Enum.to_list(lo..hi//1) end)

  # -- printing ---------------------------------------------------------------------

  @doc """
  Prints in Elixir type syntax: typespec ranges and the builtin integer
  types where they apply, `lo..+inf` / `-inf..hi` otherwise.
  """
  @impl true
  def to_quoted_string([]), do: "none()"

  def to_quoted_string(set) do
    set
    |> Enum.map(fn
      {:neg_inf, :pos_inf} -> "integer()"
      {0, :pos_inf} -> "non_neg_integer()"
      {1, :pos_inf} -> "pos_integer()"
      {:neg_inf, -1} -> "neg_integer()"
      {k, k} -> Integer.to_string(k)
      {lo, hi} -> "#{bound_string(lo)}..#{bound_string(hi)}"
    end)
    |> Enum.join(" or ")
  end

  defp bound_string(:neg_inf), do: "-inf"
  defp bound_string(:pos_inf), do: "+inf"
  defp bound_string(k), do: Integer.to_string(k)

  # -- arithmetic transfer functions (finite sets) ----------------------------------

  def add(a, b), do: lift2(a, b, fn {p, q}, {r, s} -> [{p + r, q + s}] end)
  def subtract(a, b), do: lift2(a, b, fn {p, q}, {r, s} -> [{p - s, q - r}] end)
  def multiply(a, b), do: lift2(a, b, fn x, y -> [corners(x, y, &*/2)] end)
  def min(a, b), do: lift2(a, b, fn {p, q}, {r, s} -> [{Kernel.min(p, r), Kernel.min(q, s)}] end)
  def max(a, b), do: lift2(a, b, fn {p, q}, {r, s} -> [{Kernel.max(p, r), Kernel.max(q, s)}] end)

  def negate(a), do: a |> finite!() |> Enum.reverse() |> Enum.map(fn {lo, hi} -> {-hi, -lo} end)

  def abs(a),
    do: union(intersection(a, non_neg_integer()), negate(intersection(a, neg_integer())))

  @doc "`min(max(x, lo), hi)`."
  def clip(x, lo, hi), do: x |> max(lo) |> min(hi)

  @doc "Arithmetic shift right (floor division by 2^k). `k` must be non-negative."
  def right_shift(a, k), do: lift2(a, k, fn x, y -> [corners(x, y, &(&1 >>> &2))] end)

  @doc "Shift left (multiplication by 2^k). `k` must be non-negative."
  def left_shift(a, k), do: lift2(a, k, fn x, y -> [corners(x, y, &(&1 <<< &2))] end)

  def bitwise_and(a, b) do
    lift2(a, b, fn
      {p, p}, {r, r} -> [{p &&& r, p &&& r}]
      x, {m, m} -> and_mask(x, m)
      {m, m}, y -> and_mask(y, m)
      {p, q}, {r, s} when p >= 0 and r >= 0 -> [{0, Kernel.min(q, s)}]
      {p, q}, _ when p >= 0 -> [{0, q}]
      _, {r, s} when r >= 0 -> [{0, s}]
      {p, q}, {r, s} -> [{-(1 <<< bits(p, q, r, s)), (1 <<< bits(p, q, r, s)) - 1}]
    end)
  end

  def bitwise_or(a, b), do: lift2(a, b, &or_like(&1, &2, fn x, y -> x ||| y end))
  def bitwise_xor(a, b), do: lift2(a, b, &or_like(&1, &2, fn x, y -> bxor(x, y) end))

  @doc "Result of a comparison: `{0}`, `{1}` or `{0, 1}`."
  def compare(op, a, b) do
    {a_lo, a_hi} = bounds(finite!(a))
    {b_lo, b_hi} = bounds(finite!(b))

    {always, never} =
      case op do
        :less -> {a_hi < b_lo, a_lo >= b_hi}
        :less_equal -> {a_hi <= b_lo, a_lo > b_hi}
        :greater -> {a_lo > b_hi, a_hi <= b_lo}
        :greater_equal -> {a_lo >= b_hi, a_hi < b_lo}
        :equal -> {a == b and size(a) == 1, disjoint?(a, b)}
        :not_equal -> {disjoint?(a, b), a == b and size(a) == 1}
      end

    cond do
      always -> singleton(1)
      never -> singleton(0)
      true -> range(0, 1)
    end
  end

  @doc """
  Merges the smallest gaps until at most `max` intervals remain. The result
  is a superset of `set`.
  """
  def widen(set, max \\ @max_intervals)
  def widen(set, max) when length(set) <= max, do: set

  def widen(set, max) do
    gaps =
      set
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index()
      |> Enum.map(fn {[{_, hi}, {lo, _}], i} -> {lo - hi, i} end)

    # Gap i lies between interval i and i + 1.
    merge =
      gaps |> Enum.sort() |> Enum.take(length(set) - max) |> Map.new(fn {_, i} -> {i, true} end)

    set
    |> Enum.with_index()
    |> Enum.reduce([], fn
      {{_lo, hi}, i}, [{prev_lo, _} | acc] when is_map_key(merge, i - 1) -> [{prev_lo, hi} | acc]
      {iv, _i}, acc -> [iv | acc]
    end)
    |> Enum.reverse()
  end

  # -- helpers ------------------------------------------------------------------------

  defp lift2(a, b, fun) do
    a = finite!(a) |> widen(16)
    b = finite!(b) |> widen(16)

    for(x <- a, y <- b, iv <- fun.(x, y), do: iv)
    |> Enum.sort()
    |> normalize_sorted()
    |> widen()
  end

  defp corners({p, q}, {r, s}, fun) do
    values = [fun.(p, r), fun.(p, s), fun.(q, r), fun.(q, s)]
    {Enum.min(values), Enum.max(values)}
  end

  # x & (2^n - 1) for non-negative x keeps the low n bits; exact when the
  # interval spans less than one period.
  defp and_mask({p, q}, m) when p >= 0 and m >= 0 and (m &&& m + 1) == 0 do
    period = m + 1

    cond do
      q - p >= m -> [{0, m}]
      div(p, period) == div(q, period) -> [{p &&& m, q &&& m}]
      true -> [{0, q &&& m}, {p &&& m, m}]
    end
  end

  defp and_mask({p, q}, m) when p >= 0 and m >= 0, do: [{0, Kernel.min(q, m)}]
  defp and_mask(_x, m) when m >= 0, do: [{0, m}]
  defp and_mask({p, q}, m), do: [{-(1 <<< bits(p, q, m, m)), (1 <<< bits(p, q, m, m)) - 1}]

  defp or_like({p, p}, {r, r}, op), do: [{op.(p, r), op.(p, r)}]

  defp or_like({p, q}, {r, s}, _op) when p >= 0 and r >= 0,
    do: [{0, (1 <<< bit_length(Kernel.max(q, s))) - 1}]

  defp or_like({p, q}, {r, s}, _op),
    do: [{-(1 <<< bits(p, q, r, s)), (1 <<< bits(p, q, r, s)) - 1}]

  # Two's complement width (without sign) covering all four bounds.
  defp bits(p, q, r, s),
    do: [p, q, r, s] |> Enum.map(&bit_length(if &1 < 0, do: -&1 - 1, else: &1)) |> Enum.max()

  defp bit_length(0), do: 0
  defp bit_length(n), do: 1 + bit_length(n >>> 1)

  defp finite!(set) do
    case set do
      [{lo, _} | _] when not is_integer(lo) ->
        raise ArgumentError, "arithmetic needs a finite set"

      _ ->
        :ok
    end

    case List.last(set) do
      {_, hi} when not is_integer(hi) -> raise ArgumentError, "arithmetic needs a finite set"
      _ -> set
    end
  end

  # Input sorted by lo; merges overlapping and adjacent intervals.
  defp normalize_sorted([]), do: []

  defp normalize_sorted([first | rest]) do
    rest
    |> Enum.reduce([first], fn {lo, hi}, [{c_lo, c_hi} | acc] ->
      if le(lo, succ(c_hi)),
        do: [{c_lo, max_b(c_hi, hi)} | acc],
        else: [{lo, hi}, {c_lo, c_hi} | acc]
    end)
    |> Enum.reverse()
  end

  defp le(:neg_inf, _), do: true
  defp le(_, :pos_inf), do: true
  defp le(_, :neg_inf), do: false
  defp le(:pos_inf, _), do: false
  defp le(a, b), do: a <= b

  defp max_b(a, b), do: if(le(a, b), do: b, else: a)
  defp min_b(a, b), do: if(le(a, b), do: a, else: b)

  defp succ(:pos_inf), do: :pos_inf
  defp succ(:neg_inf), do: :neg_inf
  defp succ(k), do: k + 1

  defp pred(:neg_inf), do: :neg_inf
  defp pred(k), do: k - 1
end
