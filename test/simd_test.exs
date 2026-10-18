defmodule ExHdl.SIMDTest do
  @moduledoc """
  The Highway SIMD kernels (ExHdl.SIMD via ExHdl.CPU.run_block/5) against the
  compiled Nx reference of the same block and format: bit-identical for
  random inputs, parameters, table widths, rounding modes and lengths
  (including lengths that are not a multiple of the vector width).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExHdl.{CPU, DSP, Num}
  alias ExHdl.DSP.Blocks
  alias ExHdl.Num.Fixed

  @moduletag :simd

  @taps [
    0.0,
    0.0012,
    0.0028,
    0.0042,
    0.0039,
    0.0,
    -0.0083,
    -0.0186,
    -0.0254,
    -0.0212,
    0.0,
    0.0396,
    0.0919,
    0.1451,
    0.1849,
    0.1996,
    0.1849,
    0.1451,
    0.0919,
    0.0396,
    0.0,
    -0.0212,
    -0.0254,
    -0.0186,
    -0.0083,
    0.0,
    0.0039,
    0.0042,
    0.0028,
    0.0012,
    0.0
  ]

  defp int16, do: one_of([integer(-32768..32767), member_of([-32768, -32767, 0, 32767])])
  defp samples(n), do: list_of(int16(), length: n)
  defp fx(ints), do: %Fixed{t: Nx.tensor(ints, type: :s16), frac: 15}

  defp format do
    gen all rounding <- member_of([:nearest, :truncate]), lut <- integer(4..14) do
      Num.q(16, 15, rounding: rounding, lut_bits: lut)
    end
  end

  defp same!(fun, samples, state, params, kopts) do
    {simd, simd_state, impl} = CPU.run_block(fun, samples, state, params, kopts)
    {ref, ref_state} = DSP.run_scan_stacked(fun, samples, state, params, kernel_opts: kopts)
    assert impl == :simd
    assert Num.to_float(simd) == Num.to_float(ref)
    assert Num.to_float(simd_state) == Num.to_float(ref_state)
  end

  test "the NIF is loaded and uses a real SIMD target" do
    assert ExHdl.SIMD.available?()
    # SCALAR/EMU128 means Highway fell back to emulation, e.g. an ARMv7 build
    # without the NEON override in the Makefile.
    refute ExHdl.SIMD.target() in ["SCALAR", "EMU128"]
  end

  property "ddc is bit-identical to the Nx reference" do
    check all n <- integer(1..300),
              i <- samples(n),
              q <- samples(n),
              f <- format(),
              phase <- integer(0..65535),
              inc <- integer(0..65535),
              gain <- int16(),
              max_runs: 60 do
      same!(&Blocks.ddc/5, {fx(i), fx(q)}, Nx.u16(phase), [Nx.u16(inc), fx(gain)], format: f)
    end
  end

  property "fir_complex is bit-identical to the Nx reference, including the delay line" do
    check all n <- integer(1..300),
              i <- samples(n),
              q <- samples(n),
              hist_i <- samples(30),
              hist_q <- samples(30),
              f <- format(),
              max_runs: 40 do
      same!(&Blocks.fir_complex/3, {fx(i), fx(q)}, {fx(hist_i), fx(hist_q)}, [],
        format: f,
        taps: @taps
      )
    end
  end

  property "one_pole is bit-identical to the Nx reference" do
    check all n <- integer(1..300),
              x <- samples(n),
              y0 <- int16(),
              alpha <- int16(),
              f <- format(),
              max_runs: 60 do
      same!(&Blocks.one_pole/4, fx(x), fx(y0), [fx(alpha)], format: f)
    end
  end

  test "formats the kernels do not cover fall back to the Nx loop" do
    f = Num.q(18, 17)
    x = Num.from_int(Nx.tensor([1, 2, 3], type: :s16), 15, f)

    assert {_, _, :nx} =
             CPU.run_block(&Blocks.one_pole/4, x, Num.zeros({}, f), [Num.constant(0.5, f)],
               format: f
             )
  end
end
