defmodule ExHdl.DSPWidthCheckTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias ExHdl.DSP
  alias ExHdl.DSP.Primitives
  alias ExHdl.Types.IntSet
  alias ExHdl.Test.DSP, as: K

  defp t(type, shape \\ {}), do: Nx.template(shape, type)
  defp ddc_args(opts \\ []), do: [{t(:s16), t(:s16)}, t(:u16), t(:u16), t(:s16), opts]

  defp widest_s32(graph) do
    graph.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == {:s, 32}))
    |> Enum.map(fn %{range: set} ->
      set |> IntSet.bounds() |> then(fn {lo, hi} -> max(-lo, hi) end)
    end)
    |> Enum.max()
  end

  describe "ddc_step" do
    test "case splitting proves it overflow-free with a tight bound" do
      graph = DSP.analyze!(&K.ddc_step/5, ddc_args())

      # max |i*cos - q*sin| over the table: about sqrt(2) * 2^30, far below
      # the 2 * 32768 * 32767 that plain interval arithmetic assumes.
      assert widest_s32(graph) == 1_518_469_120

      [out_i, out_q, next_phase] = ExHdl.IR.Dataflow.output_ids(graph)
      assert IntSet.bounds(graph.nodes[out_i].range) == {-32768, 32767}
      assert IntSet.bounds(graph.nodes[out_q].range) == {-32768, 32767}
      assert graph.nodes[next_phase].range == IntSet.range(0, 65535)
    end

    test "without case splitting only interval bounds are available" do
      graph = DSP.analyze!(&K.ddc_step/5, ddc_args(), case_split: false)
      assert widest_s32(graph) == 2 * 32768 * 32767
    end

    test "NCO amplitude 32768 is safe because cos and sin never peak together" do
      assert {:error, e} =
               DSP.analyze(&K.ddc_step/5, ddc_args(amplitude: 32768), case_split: false)

      assert e.message =~
               "subtract needs -2147483648..2147483648, but s32 holds -2147483648..2147483647"

      graph = DSP.analyze!(&K.ddc_step/5, ddc_args(amplitude: 32768))
      assert widest_s32(graph) == 1_518_469_120
    end

    test "a real overflow is still rejected" do
      args = [{t(:s16), t(:s16)}, t(:u16), t(:u16), t(:s16)]

      assert {:error, e} =
               DSP.analyze(&K.ddc_step_no_preshift/4, args, name: "ddc_step_no_preshift")

      assert [%{kind: :overflow, range: {lo, hi}}] = e.violations
      assert hi == 1_518_469_120 * 32768 and lo == -hi
      assert e.message =~ "ddc_step_no_preshift: 1 fixed-point problem(s)"
      assert e.message =~ "multiply needs"
    end

    test "the plan's implicit phase wrap is rejected" do
      assert {:error, e} = DSP.analyze(&K.plan_phase_update/2, [t(:u16), t(:u16)])
      assert e.message =~ "add needs 0..131070, but u16 holds 0..65535"
      assert e.message =~ "wrap/2"
    end

    test "ExHdl.DSP.Compiler refuses to run an unsafe kernel" do
      fun = Nx.Defn.jit(&K.ddc_step_no_preshift/4, compiler: DSP.Compiler)
      args = [{Nx.s16(1), Nx.s16(1)}, Nx.u16(0), Nx.u16(0), Nx.s16(1)]
      assert_raise DSP.RangeError, ~r/multiply needs/, fn -> apply(fun, args) end
    end

    property "reference execution equals exact integer math" do
      edge16 = one_of([integer(-32768..32767), member_of([-32768, -32767, 0, 32767])])
      phase = one_of([integer(0..65535), member_of([0, 16384, 32768, 49152, 65535])])

      check all(
              rows <-
                list_of(tuple({edge16, edge16, phase, phase, edge16}),
                  min_length: 1,
                  max_length: 64
                )
            ) do
        assert_matches_model(rows)
      end
    end

    test "reference execution equals exact integer math on all worst-case corners" do
      edges = [-32768, -32767, 32767]
      # Phases where the NCO outputs +-32767 on one component.
      phases = [0, 16384, 32768, 49152]

      rows = for i <- edges, q <- edges, g <- [-32768, 32767], p <- phases, do: {i, q, p, 0, g}
      assert_matches_model(rows)
    end
  end

  # Runs ddc_step vectorised through ExHdl.DSP.Compiler and compares every
  # element with an arbitrary-precision Elixir model of the same formula.
  defp assert_matches_model(rows) do
    col = fn idx, type -> Nx.tensor(Enum.map(rows, &elem(&1, idx)), type: type) end
    fun = Nx.Defn.jit(&K.ddc_step/5, compiler: DSP.Compiler)

    {{out_i, out_q}, next} =
      fun.({col.(0, :s16), col.(1, :s16)}, col.(2, :u16), col.(3, :u16), col.(4, :s16), [])

    expected = Enum.map(rows, &model/1)
    actual = Enum.zip([Nx.to_list(out_i), Nx.to_list(out_q), Nx.to_list(next)])
    assert actual == expected
  end

  @table Primitives.sine_values(1024, 32767) |> List.to_tuple()

  defp model({i, q, acc, inc, gain}) do
    phase = rem(acc + inc, 65536)
    idx = phase >>> 6
    c = elem(@table, band(idx + 256, 1023))
    s = elem(@table, idx)
    mix_i = i * c - q * s
    mix_q = i * s + q * c
    out = fn m -> (((m >>> 15) * gain) >>> 15) |> max(-32768) |> min(32767) end
    {out.(mix_i), out.(mix_q), phase}
  end

  describe "primitives" do
    property "wrap and add_wrap equal modular arithmetic" do
      check all(
              a <- integer(0..65535),
              b <- integer(0..65535),
              x <- integer(-(1 <<< 31)..((1 <<< 31) - 1))
            ) do
        assert Nx.to_number(Primitives.add_wrap(Nx.u16(a), Nx.u16(b), :u16)) == rem(a + b, 65536)

        signed = Integer.mod(x + 32768, 65536) - 32768
        assert Nx.to_number(Primitives.wrap(Nx.s64(x), :s16)) == signed
        assert Nx.to_number(Primitives.wrap(Nx.s64(x), :u8)) == Integer.mod(x, 256)
      end
    end

    test "full-range complex Q15 multiply overflows, symmetric Q15 on one side does not" do
      fun = &Primitives.complex_widening_mul_q15/2
      args = [{t(:s16), t(:s16)}, {t(:s16), t(:s16)}]

      # Only the imaginary part a_i*b_q + a_q*b_i can reach 2^31; the real
      # part peaks at 2^30 + 32768*32767.
      assert {:error, e} = DSP.analyze(fun, args)
      assert [%{kind: :overflow, range: {_, 2_147_483_648}}] = e.violations
      assert e.message =~ "add needs"

      assert {:ok, _} =
               DSP.analyze(fun, args, param_ranges: %{2 => -32767..32767, 3 => -32767..32767})
    end
  end

  describe "other violations" do
    import Nx.Defn

    defn small_table(i), do: Nx.take(Nx.tensor([1, 2, 3, 4], type: :s16), i)
    defn narrow(x), do: Nx.as_type(x, :s8)
    defn narrow_ok(x), do: Nx.as_type(Nx.bitwise_and(x, 63) + 1, :s8)
    defn float_math(x), do: x * 0.5
    defn masked_table(i), do: Nx.take(Nx.tensor([1, 2, 3, 4], type: :s16), Nx.bitwise_and(i, 3))

    test "table index out of bounds" do
      assert {:error, e} = DSP.analyze(&small_table/1, [t(:u8)])
      assert [%{kind: :index}] = e.violations
      assert e.message =~ "take index can be 0..255, table has 4 entries"
      assert {:ok, _} = DSP.analyze(&masked_table/1, [t(:u8)])
    end

    test "narrowing as_type that would wrap" do
      assert {:error, e} = DSP.analyze(&narrow/1, [t(:s16)])
      assert [%{kind: :narrowing}] = e.violations
      assert e.message =~ "as_type to s8 would wrap values in -32768..32767"
      assert {:ok, _} = DSP.analyze(&narrow_ok/1, [t(:s16)])
    end

    test "floating point is rejected" do
      assert {:error, e} = DSP.analyze(&float_math/1, [t(:s16)])
      assert e.message =~ "floating point"
    end
  end
end
