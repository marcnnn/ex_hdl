defmodule ExHdl.DSPBlocksTest do
  @moduledoc """
  The format-generic blocks (ExHdl.DSP.Blocks) instantiated as Q15 must be
  bit-identical to the hand-written Q15 kernels, and the analyses must work
  on them unchanged.
  """
  use ExUnit.Case, async: true

  alias ExHdl.{DSP, Num}
  alias ExHdl.DSP.Blocks
  alias ExHdl.Test.DSP, as: K

  @n 1024
  @taps_q15 [0, 39, 91, 139, 129, 0, -271, -609, -832, -696, 0, 1297, 3011, 4755, 6059, 6542] ++
              Enum.reverse([
                0,
                39,
                91,
                139,
                129,
                0,
                -271,
                -609,
                -832,
                -696,
                0,
                1297,
                3011,
                4755,
                6059
              ])

  setup_all do
    :rand.seed(:exsss, {7, 8, 9})
    # random values with plenty of full-scale extremes
    ints = fn ->
      for _ <- 1..@n, do: Enum.random([-32768, 32767, :rand.uniform(65536) - 32769])
    end

    %{i: ints.(), q: ints.()}
  end

  defp raw(outputs), do: Enum.map(outputs, fn {a, b} -> {value(a), value(b)} end)
  defp value(%Num.Fixed{t: t}), do: Nx.to_number(t)
  defp value(t), do: Nx.to_number(t)

  defp q15_pairs(i, q), do: Enum.zip_with(i, q, &{Nx.s16(&1), Nx.s16(&2)})

  defp fixed_pairs(i, q, f),
    do: Enum.zip_with(i, q, &{Num.from_int(Nx.s16(&1), 15, f), Num.from_int(Nx.s16(&2), 15, f)})

  for {rounding, lut} <- [truncate: 10, nearest: 10, truncate: 12] do
    test "ddc as Q15 (#{rounding}, #{lut}-bit table) is bit-identical to the hand-written kernel",
         %{i: i, q: q} do
      f = Num.q(16, 15, rounding: unquote(rounding), lut_bits: unquote(lut))
      old_opts = [lut_bits: unquote(lut), round: unquote(rounding) == :nearest]

      {old, _} =
        DSP.run_scan(&K.ddc_step/5, q15_pairs(i, q), Nx.u16(62535), [Nx.u16(3001), Nx.s16(26214)],
          kernel_opts: old_opts
        )

      {new, _} =
        DSP.run_scan(
          &Blocks.ddc/5,
          fixed_pairs(i, q, f),
          Nx.u16(62535),
          [Nx.u16(3001), Num.constant(0.8, f)],
          kernel_opts: [format: f]
        )

      assert raw(new) == raw(old)
    end
  end

  for rounding <- [:nearest, :truncate] do
    test "fir_complex as Q15 (#{rounding}) is bit-identical to the hand-written kernel", %{
      i: i,
      q: q
    } do
      f = Num.q(16, 15, rounding: unquote(rounding))
      z = Nx.broadcast(Nx.s16(0), {30})

      {old, _} =
        DSP.run_scan(&K.fir_ccf_step/3, q15_pairs(i, q), {z, z}, [],
          kernel_opts: [taps: @taps_q15, round: unquote(rounding) == :nearest]
        )

      taps = Enum.map(@taps_q15, &(&1 / 32768))

      {new, _} =
        DSP.run_scan(
          &Blocks.fir_complex/3,
          fixed_pairs(i, q, f),
          {Num.zeros({30}, f), Num.zeros({30}, f)},
          [],
          kernel_opts: [format: f, taps: taps]
        )

      assert raw(new) == raw(old)
    end
  end

  for {rounding, kernel} <- [nearest: :one_pole_rounded_step, truncate: :one_pole_step] do
    test "one_pole as Q15 (#{rounding}) is bit-identical to the hand-written kernel", %{i: i} do
      f = Num.q(16, 15, rounding: unquote(rounding))

      {old, _} =
        DSP.run_scan(
          &apply(K, unquote(kernel), [&1, &2, &3]),
          Enum.map(i, &Nx.s16/1),
          Nx.s16(0),
          [Nx.s16(328)]
        )

      {new, _} =
        DSP.run_scan(
          &Blocks.one_pole/4,
          Enum.map(i, &Num.from_int(Nx.s16(&1), 15, f)),
          Num.zeros({}, f),
          [Num.from_int(Nx.s16(328), 15, f)],
          kernel_opts: [format: f]
        )

      assert Enum.map(new, &value/1) == Enum.map(old, &Nx.to_number/1)
    end
  end

  test "the analyses work on generic blocks: ddc as Q15 runs at one sample per cycle" do
    f = Num.q(16, 15)
    s = %Num.Fixed{t: Nx.template({}, :s16), frac: 15}
    args = [{s, s}, Nx.template({}, :u16), Nx.template({}, :u16), s, [format: f]]
    assert {:ok, %{loop_latency: 1, ii: 1}} = DSP.analyze_scan(&Blocks.ddc/5, args, state: 1)
  end

  test "the float instance runs the same algorithm" do
    f = Num.float()
    x = {Num.from_int(Nx.s16(16384), 15, f), Num.from_int(Nx.s16(0), 15, f)}
    # phase 16384 = 90 degrees: 0.5 * e^(j*pi/2) * 0.8 = 0.4j
    {{re, im}, phase} = Blocks.ddc(x, Nx.u16(0), Nx.u16(16384), Num.constant(0.8, f), format: f)
    assert_in_delta Nx.to_number(re), 0.0, 1.0e-6
    assert_in_delta Nx.to_number(im), 0.4, 1.0e-6
    assert Nx.to_number(phase) == 16384
  end
end
