defmodule ExHdl.Types.IntSetTest do
  use ExUnit.Case, async: true
  use ExHdl.Test.SetLaws, algebra: ExHdl.Types.IntSet, max_runs: 300

  import Bitwise
  alias ExHdl.Types.IntSet
  alias ExHdl.Test.TypeGen

  def types, do: TypeGen.int_expr()
  def values, do: TypeGen.int_value()

  property "representation is canonical: sorted, disjoint, non-adjacent" do
    check all expr <- types() do
      set = ExHdl.Types.Expr.build(expr, IntSet)

      set
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [{_, hi}, {lo, _}] ->
        assert is_integer(hi) and is_integer(lo) and lo > hi + 1
      end)
    end
  end

  test "prints in Elixir type syntax" do
    assert IntSet.to_quoted_string(IntSet.none()) == "none()"
    assert IntSet.to_quoted_string(IntSet.range(0, 65535)) == "0..65535"
    assert IntSet.to_quoted_string(IntSet.negation(IntSet.non_neg_integer())) == "neg_integer()"

    assert IntSet.to_quoted_string(IntSet.negation(IntSet.range(1, 5))) == "-inf..0 or 6..+inf"

    assert IntSet.to_quoted_string(IntSet.from_list([-3, 7, 8, 9])) == "-3 or 7..9"
  end

  # Soundness of the range analysis: every concrete result is in the set.
  @binary_ops [
    add: &+/2,
    subtract: &-/2,
    multiply: &*/2,
    min: &min/2,
    max: &max/2,
    bitwise_and: &band/2,
    bitwise_or: &bor/2,
    bitwise_xor: &bxor/2
  ]

  for {op, fun} <- @binary_ops do
    @op op
    @fun fun
    property "#{op} is sound" do
      check all a <- TypeGen.finite_int_set(), b <- TypeGen.finite_int_set() do
        result = apply(IntSet, @op, [a, b])

        for x <- IntSet.to_list(a),
            y <- IntSet.to_list(b),
            do: assert(IntSet.member?(result, @fun.(x, y)))
      end
    end
  end

  property "shifts, negate, abs, clip and widen are sound" do
    check all a <- TypeGen.finite_int_set(), k <- integer(0..6), max <- integer(1..4) do
      ks = IntSet.range(0, k)
      rs = IntSet.right_shift(a, ks)
      ls = IntSet.left_shift(a, ks)
      clipped = IntSet.clip(a, IntSet.singleton(-5), IntSet.singleton(5))
      widened = IntSet.widen(a, max)

      assert length(widened) <= max
      assert IntSet.subtype?(a, widened)

      for x <- IntSet.to_list(a) do
        for s <- 0..k, do: assert(IntSet.member?(rs, x >>> s) and IntSet.member?(ls, x <<< s))
        assert IntSet.member?(IntSet.negate(a), -x)
        assert IntSet.member?(IntSet.abs(a), abs(x))
        assert IntSet.member?(clipped, x |> max(-5) |> min(5))
      end
    end
  end

  test "low-bit masks are exact" do
    assert IntSet.bitwise_and(IntSet.range(1000, 1030), IntSet.singleton(1023)) == [
             {0, 6},
             {1000, 1023}
           ]

    assert IntSet.bitwise_and(IntSet.range(256, 1279), IntSet.singleton(1023)) == [{0, 1023}]
  end
end
