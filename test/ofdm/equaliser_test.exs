defmodule ExHdl.OFDM.EqualiserTest do
  @moduledoc """
  Pilot-aided equalisation and hard decisions (`ExHdl.OFDM.Equaliser`) in
  Verilator against the stage of `FixedFrontEnd` (`ExHdl.Test.OFDMRef.words/5`),
  fed with the FFT of the DVB-T test signal, with random valid and ready.
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias ExHdl.OFDM.Equaliser
  alias ExHdl.RTL.{Bench, Cosim}
  alias ExHdl.Test.{AxisSink, AxisSource}
  alias ExHdl.Test.OFDMRef, as: R
  alias ExSdr.Comm.OFDM.FixedFrontEnd, as: F

  @moduletag :verilator
  @moduletag timeout: 900_000

  @symbols 8

  defp fft_output(constellation, snr \\ 12.0) do
    spec = ExSdr.DVBT.Receiver.front_end_spec(constellation)
    {sc16, cfo} = R.signal(constellation, @symbols, snr: snr)
    fe = F.prepare(spec, @symbols, compiler: Nx.Defn.Evaluator)
    inc = F.phase_increment(cfo, 2048)
    y = R.correct(sc16, inc, 0) |> R.strip(spec, @symbols) |> R.fft()
    expected = R.words(y, spec, fe.tables, @symbols) |> Nx.to_flat_list()
    {spec, y, expected}
  end

  defp beats({re, im}) do
    res = Nx.to_flat_list(re.t)
    ims = Nx.to_flat_list(im.t)

    for {{r, i}, n} <- Enum.with_index(Enum.zip(res, ims)),
        do: {(i &&& 0xFFFF) <<< 16 ||| (r &&& 0xFFFF), if(rem(n, 2048) == 2047, do: 1, else: 0)}
  end

  defp run(mod, beats, count, {vp, rp, seed}) do
    :rand.seed(:exsss, {seed, 7, 8})
    {:ok, s} = Cosim.open(mod)

    bench =
      Bench.new(s, src: AxisSource.new(beats, p: vp), sink: AxisSink.new(p: rp))
      |> Bench.run_until(&(AxisSink.count(Bench.agent(&1, :sink)) == count), 2_000_000)

    Cosim.close(s)
    {AxisSink.items(Bench.agent(bench, :sink)), bench.cycle}
  end

  test "QPSK: words of the data carriers, tlast per symbol, any traffic" do
    {spec, y, expected} = fft_output(:qpsk)
    assert expected |> Enum.uniq() |> length() == 4
    {:ok, eq} = Equaliser.build(spec, name: "eq_qpsk")
    assert eq.design.ii == 1
    assert eq.plan.total == 4 * 1688

    for traffic <- [{1.0, 1.0, 1}, {0.7, 0.5, 2}, {0.9, 0.2, 3}] do
      {out, cycles} = run(eq.module, beats(y), length(expected), traffic)
      assert Enum.map(out, &elem(&1, 0)) == expected, "traffic #{inspect(traffic)}"
      lasts = for i <- 1..length(expected), do: if(rem(i, 1512) == 0, do: 1, else: 0)
      assert Enum.map(out, &elem(&1, 1)) == lasts
      if elem(traffic, 0) == 1.0, do: assert(cycles < @symbols * 2048 + 2200)
    end
  end

  for {c, v} <- [qam16: 4, qam64: 6] do
    @c c
    @v v
    test "#{c}: boundaries scaled by |h|^2, same words as the software front end" do
      {spec, y, expected} = fft_output(@c, 28.0)
      assert expected |> Enum.uniq() |> length() > 2 * @v
      {:ok, eq} = Equaliser.build(spec, name: "eq_#{@c}")
      assert eq.design.ii == 1
      {out, _} = run(eq.module, beats(y), length(expected), {0.8, 0.6, 4})
      assert Enum.map(out, &elem(&1, 0)) == expected
    end
  end
end
