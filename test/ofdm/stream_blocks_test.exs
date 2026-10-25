defmodule ExHdl.OFDM.StreamBlocksTest do
  @moduledoc """
  Guard removal and bit unpacking (`ExHdl.OFDM.Guard`, `ExHdl.OFDM.Unpack`)
  in Verilator against list models, random valid and ready.
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias ExHdl.OFDM.{Guard, Unpack}
  alias ExHdl.RTL.{Bench, Cosim}
  alias ExHdl.Test.{AxisSink, AxisSource}

  @moduletag :verilator
  @moduletag timeout: 600_000

  @traffic [{1.0, 1.0, 1}, {0.6, 0.5, 2}, {0.3, 0.9, 3}, {0.95, 0.2, 4}]

  defp run(mod, beats, count, {vp, rp, seed}) do
    :rand.seed(:exsss, {seed, 9, 9})
    {:ok, s} = Cosim.open(mod)

    bench =
      Bench.new(s, src: AxisSource.new(beats, p: vp), sink: AxisSink.new(p: rp))
      |> Bench.run_until(&(AxisSink.count(Bench.agent(&1, :sink)) == count), 1_000_000)

    Cosim.close(s)
    {AxisSink.items(Bench.agent(bench, :sink)), bench.cycle}
  end

  test "guard removal: cp samples dropped, tlast on the last of fft, any traffic" do
    {fft, cp, n} = {16, 3, 5}
    mod = Guard.build(name: "guard_16_3", width: 32, fft: fft, cp: cp)
    :rand.seed(:exsss, {1, 1, 1})
    data = for _ <- 1..((fft + cp) * n), do: :rand.uniform(1 <<< 32) - 1

    expected =
      data
      |> Enum.chunk_every(fft + cp)
      |> Enum.flat_map(fn sym ->
        sym
        |> Enum.drop(cp)
        |> Enum.with_index()
        |> Enum.map(fn {x, i} -> {x, if(i == fft - 1, do: 1, else: 0)} end)
      end)

    for traffic <- @traffic do
      {out, cycles} = run(mod, Enum.map(data, &{&1, 0}), length(expected), traffic)
      assert out == expected, "traffic #{inspect(traffic)}"
      if elem(traffic, 0) == 1.0, do: assert(cycles <= length(data) + 12)
    end
  end

  for v <- [1, 2, 4, 6] do
    @v v
    test "unpack #{v} bits, most significant first, tlast on the last bit of a word" do
      mod = Unpack.build(name: "unpack_#{@v}", bits: @v)
      :rand.seed(:exsss, {2, 2, @v})
      words = for _ <- 1..60, do: :rand.uniform(1 <<< @v) - 1
      beats = Enum.with_index(words, fn w, i -> {w, if(rem(i, 7) == 6, do: 1, else: 0)} end)

      expected =
        for {w, l} <- beats, k <- (@v - 1)..0//-1, do: {w >>> k &&& 1, if(k == 0, do: l, else: 0)}

      for traffic <- @traffic do
        {out, cycles} = run(mod, beats, length(expected), traffic)
        assert out == expected, "traffic #{inspect(traffic)}"
        if elem(traffic, 0) == 1.0, do: assert(cycles <= length(expected) + 12)
      end
    end
  end
end
