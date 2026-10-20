defmodule ExHdl.RTL.ExprTest do
  use ExUnit.Case, async: true

  import ExHdl.RTL.Expr
  alias ExHdl.RTL.{Expr, WidthError}

  doctest ExHdl.RTL.Expr

  defp sig(name, type), do: input_like(name, type)

  setup do
    %{a: sig(:a, {:u, 8}), b: sig(:b, {:u, 4}), c: sig(:c, {:s, 8}), f: sig(:f, {:u, 1})}
  end

  test "arithmetic grows, wrapping variants keep the width", %{a: a, b: b, c: c} do
    assert add(a, b).type == {:u, 9}
    assert sub(a, b).type == {:u, 9}
    assert add_wrap(a, b).type == {:u, 8}
    assert sub_wrap(a, b).type == {:u, 8}
    assert mul(a, b).type == {:u, 12}
    assert neg(c).type == {:s, 9}
    assert add(c, c).type == {:s, 9}
  end

  test "integers take the smallest width in arithmetic and the operand's type elsewhere", %{
    a: a,
    c: c
  } do
    assert add(a, 1).type == {:u, 9}
    assert add(a, 1000).type == {:u, 11}
    assert add(c, -1).type == {:s, 9}
    assert band(a, 0xF0).type == {:u, 8}
    assert eq(a, 300).type == {:u, 1}
    assert_raise WidthError, ~r/300 does not fit u8/, fn -> band(a, 300) end
    assert_raise WidthError, ~r/negative constant/, fn -> add(a, -1) end
  end

  test "signedness never mixes", %{a: a, c: c} do
    assert_raise WidthError, ~r/different signedness \(u8 and s8\).*as_signed/, fn ->
      add(a, c)
    end

    assert_raise WidthError, ~r/different signedness/, fn -> band(a, c) end
    assert_raise WidthError, ~r/negation of unsigned/, fn -> neg(a) end
    assert to_signed(a).type == {:s, 9}
    assert as_signed(a).type == {:s, 8}
    assert as_unsigned(c).type == {:u, 8}
  end

  test "bitwise and comparison results", %{a: a, b: b} do
    assert bor(a, b).type == {:u, 8}
    assert bnot(b).type == {:u, 4}
    assert lt(a, b).type == {:u, 1}
    assert reduce_xor(a).type == {:u, 1}
    assert_raise WidthError, ~r/needs a 1-bit unsigned value, got u8/, fn -> land(a, a) end
  end

  test "shifts", %{a: a, b: b, c: c} do
    assert shl(a, 3).type == {:u, 11}
    assert shr(a, 3).type == {:u, 8}
    assert shr(c, 3).type == {:s, 8}
    assert shl(a, b).type == {:u, 8 + 15}
    assert shr(a, b).type == {:u, 8}
  end

  test "slices, concatenation, replication", %{a: a, b: b, c: c} do
    assert a[0..3].type == {:u, 4}
    assert a[7].type == {:u, 1}
    assert a[7..4//-1] == a[4..7]
    assert c[0..7].type == {:u, 8}
    assert a[b].type == {:u, 1}
    assert cat([a, b]).type == {:u, 12}
    assert rep(b, 3).type == {:u, 12}
    assert_raise WidthError, ~r/out of range/, fn -> a[4..8] end
    assert_raise WidthError, ~r/needs a width/, fn -> cat([a, 1]) end
  end

  test "width conversion is explicit", %{a: a, b: b, c: c} do
    assert trunc(a, 3).type == {:u, 3}
    assert zext(b, 8).type == {:u, 8}
    assert sext(c, 12).type == {:s, 12}
    assert resize(a, 4).type == {:u, 4}
    assert resize(c, 16).type == {:s, 16}
    assert_raise WidthError, ~r/trunc to 9 bits/, fn -> trunc(a, 9) end
    assert_raise WidthError, ~r/zext of signed/, fn -> zext(c, 9) end
    assert_raise WidthError, ~r/sext of unsigned/, fn -> sext(a, 9) end

    assert_raise WidthError, ~r/u9 value does not fit u8.*trunc\/2/, fn ->
      coerce!(add(a, 1), {:u, 8}, "q")
    end

    assert coerce!(b, {:u, 8}, "q").type == {:u, 8}
  end

  test "muxes", %{a: a, b: b, f: f} do
    assert mux(f, a, b).type == {:u, 8}
    assert mux(f, a, 3).type == {:u, 8}
    assert mux(b[0..1], [a, b, 7]).type == {:u, 8}
    assert_raise WidthError, ~r/mux condition/, fn -> mux(a, a, b) end

    assert_raise WidthError, ~r/4 items, selector has 1 bits|5 items, selector has 2 bits/, fn ->
      mux(b[0..1], [a, a, a, a, a])
    end
  end

  test "constants fold", %{a: a, b: b, f: f} do
    assert mux(const(1, 1), a, b) == a
    assert mux(const(0, 1), a, b).op == :resize
    assert a[const(3, 3)] == a[3]
    assert land(f, const(0, 1)) == const(0, 1)
    assert lor(f, const(0, 1)) == f
    assert add(const(200, 8), const(100, 8)) == const(300, 9)
    assert ge(a, 0) == const(1, 1)
    assert lt(b, 16) == const(1, 1)
    assert eq(b, 20) == const(0, 1)
    assert eq(b, 3).op == :eq
  end

  test "indexing a constant folds when the result can't depend on the index", %{a: a, b: b} do
    assert const(0, 8)[b] == const(0, 1)
    assert const(15, 4)[a[0..1]] == const(1, 1)
    # b can be 4..15, which reads 0
    assert const(15, 4)[b].op == :index
    assert const(6, 4)[a[0..1]].op == :index
  end

  test "eval follows the width rules", %{a: a, b: b, c: c} do
    v = %{a: 200, b: 9, c: -3}
    ev = &Expr.eval(&1, fn n -> v[n] end)
    assert ev.(add(a, b)) == 209
    assert ev.(add_wrap(a, 100)) == 44
    assert ev.(sub(b, a)) == Bitwise.band(9 - 200, 511)
    assert ev.(mul(c, c)) == 9
    assert ev.(neg(c)) == 3
    assert ev.(shr(c, 1)) == -2
    assert ev.(as_unsigned(c)) == 253
    assert ev.(cat([b, a])) == 9 * 256 + 200
    assert ev.(a[4..7]) == 12
    assert ev.(bit(a, b)) == 0
    assert ev.(reduce_xor(b)) == 0
    assert ev.(sext(c, 12)) == -3
    assert ev.(trunc(a, 4)) == 8
  end

  test "types" do
    assert u(8) == {:u, 8}
    assert s(3) == {:s, 3}
    assert_raise WidthError, fn -> u(0) end
    assert min_type(-128, :s) == {:s, 8}
    assert min_type(127, :s) == {:s, 8}
    assert min_type(128, :s) == {:s, 9}
    assert min_type(0, :u) == {:u, 1}
  end
end
