defmodule ExHdl.DSPScanLoopTest do
  @moduledoc """
  The compiled block loop (ExHdl.DSP.run_scan_stacked/5, EXLA) against the
  per-sample reference: bit-identical in fixed point, within float32
  rounding for the float instance (XLA computes cos/sin differently).
  """
  use ExUnit.Case, async: true

  alias ExHdl.{DSP, Num}
  alias ExHdl.DSP.Blocks

  @n 1024
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

  setup_all do
    :rand.seed(:exsss, {4, 5, 6})

    ints = fn ->
      for _ <- 1..@n, do: Enum.random([-32768, 32767, :rand.uniform(65536) - 32769])
    end

    %{i: ints.(), q: ints.()}
  end

  defp blocks(f) do
    [
      {&Blocks.ddc/5, :complex, Nx.u16(62535), [Nx.u16(3001), Num.constant(0.8, f)], [format: f]},
      {&Blocks.fir_complex/3, :complex, {Num.zeros({30}, f), Num.zeros({30}, f)}, [],
       [format: f, taps: @taps]},
      {&Blocks.one_pole/4, :real, Num.zeros({}, f), [Num.constant(0.01, f)], [format: f]}
    ]
  end

  defp run_both(f, %{i: i, q: q}) do
    for {fun, kind, state, params, kopts} <- blocks(f) do
      per_sample =
        if kind == :complex,
          do:
            Enum.zip_with(
              i,
              q,
              &{Num.from_int(Nx.s16(&1), 15, f), Num.from_int(Nx.s16(&2), 15, f)}
            ),
          else: Enum.map(i, &Num.from_int(Nx.s16(&1), 15, f))

      stacked =
        if kind == :complex,
          do:
            {Num.from_int(Nx.tensor(i, type: :s16), 15, f),
             Num.from_int(Nx.tensor(q, type: :s16), 15, f)},
          else: Num.from_int(Nx.tensor(i, type: :s16), 15, f)

      {ref, ref_state} = DSP.run_scan(fun, per_sample, state, params, kernel_opts: kopts)

      {out, out_state} =
        DSP.run_scan_stacked(fun, stacked, state, params, kernel_opts: kopts, compiler: EXLA)

      ref = Enum.map(ref, &Num.to_float/1)

      out =
        case Num.to_float(out) do
          {re, im} -> Enum.zip(re, im)
          values -> values
        end

      {fun, ref, out, Num.to_float(ref_state), Num.to_float(out_state)}
    end
  end

  test "fixed point (Q15): EXLA loop is bit-identical for every block", ctx do
    for {fun, ref, out, ref_state, out_state} <- run_both(Num.q(16, 15, rounding: :nearest), ctx) do
      assert out == ref, "#{inspect(fun)} differs"
      assert out_state == ref_state
    end
  end

  test "fixed point (Q17, truncating): EXLA loop is bit-identical for every block", ctx do
    for {fun, ref, out, _, _} <- run_both(Num.q(18, 17, rounding: :truncate, lut_bits: 12), ctx) do
      assert out == ref, "#{inspect(fun)} differs"
    end
  end

  test "float instance: EXLA loop within float32 rounding", ctx do
    for {fun, ref, out, _, _} <- run_both(Num.float(), ctx) do
      worst =
        Enum.zip_with(ref, out, fn
          {a, b}, {c, d} -> max(abs(a - c), abs(b - d))
          a, c -> abs(a - c)
        end)
        |> Enum.max()

      assert worst < 1.0e-5, "#{inspect(fun)}: worst difference #{worst}"
    end
  end
end
