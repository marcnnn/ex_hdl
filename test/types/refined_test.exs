defmodule ExHdl.Types.RefinedTest do
  use ExUnit.Case, async: true
  # Must come before `use SetLaws`: tags are captured when tests are defined.
  @moduletag :elixir_types
  use ExHdl.Test.SetLaws, algebra: ExHdl.Types.Refined, max_runs: 100

  alias ExHdl.Types.{ElixirDescr, IntSet, Refined}
  alias ExHdl.Test.TypeGen
  alias Module.Types.Descr, as: D

  def types, do: TypeGen.refined_expr()
  def values, do: TypeGen.value()

  defp build(expr), do: ExHdl.Types.Expr.build(expr, Refined)

  describe "erasure to plain Elixir types" do
    property "is a union homomorphism" do
      check all a <- types(), b <- types() do
        {a, b} = {build(a), build(b)}

        assert D.equal?(
                 Refined.erase(Refined.union(a, b)),
                 D.union(Refined.erase(a), Refined.erase(b))
               )
      end
    end

    property "over-approximates intersection and preserves subtyping" do
      check all a <- types(), b <- types() do
        {a, b} = {build(a), build(b)}

        assert D.subtype?(
                 Refined.erase(Refined.intersection(a, b)),
                 D.intersection(Refined.erase(a), Refined.erase(b))
               )

        if Refined.subtype?(a, b), do: assert(D.subtype?(Refined.erase(a), Refined.erase(b)))
      end
    end

    property "keeps every member (soundness)" do
      check all a <- types(), v <- values() do
        a = build(a)

        if Refined.member?(a, v), do: assert(ElixirDescr.member?(Refined.erase(a), v))
      end
    end

    test "does not commute with negation: refinement needs cofinite integer sets" do
      # not(0..9) still contains integers, so erasing it gives integer(),
      # while not(erase(0..9)) = not(integer()) excludes them.
      a = Refined.integer(IntSet.range(0, 9))
      erased_neg = Refined.erase(Refined.negation(a))
      refute D.subtype?(erased_neg, D.negation(Refined.erase(a)))
    end
  end

  test "prints refined types" do
    t = Refined.union(Refined.from_descr(D.atom([:ok])), Refined.integer(IntSet.range(0, 65535)))
    assert Refined.to_quoted_string(t) == ":ok or 0..65535"
  end
end
