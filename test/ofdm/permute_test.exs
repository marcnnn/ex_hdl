defmodule ExHdl.OFDM.PermuteTest do
  @moduledoc """
  `ExHdl.OFDM.Permute` in Verilator against `ExSdr.Comm.Permutation.apply/2`:
  random tables, then the DVB-T symbol and bit interleavers, with random
  valid and ready.
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias ExHdl.OFDM.Permute
  alias ExHdl.RTL.{Bench, Cosim}
  alias ExHdl.Test.{AxisSink, AxisSource}
  alias ExSdr.Comm.Permutation
  alias ExSdr.DVBT.Inner

  @moduletag :verilator
  @moduletag timeout: 600_000

  # items through the module with random traffic: [{item, last}]
  defp run(mod, items, block, {vp, rp, seed}) do
    :rand.seed(:exsss, {seed, 5, 6})
    beats = Enum.map(items, &{&1, 0})
    {:ok, s} = Cosim.open(mod)

    bench =
      Bench.new(s, src: AxisSource.new(beats, p: vp), sink: AxisSink.new(p: rp))
      |> Bench.run_until(&(AxisSink.count(Bench.agent(&1, :sink)) == length(items)), 2_000_000)

    Cosim.close(s)
    out = AxisSink.items(Bench.agent(bench, :sink))
    assert length(out) == length(items)

    assert Enum.map(out, &elem(&1, 1)) ==
             for(i <- 1..length(items), do: if(rem(i, block) == 0, do: 1, else: 0))

    {Enum.map(out, &elem(&1, 0)), bench.cycle}
  end

  @traffic [{1.0, 1.0, 1}, {0.6, 0.5, 2}, {0.3, 0.9, 3}, {0.95, 0.2, 4}]

  test "random tables, one and three of them, any block order of use" do
    for {count, n, width} <- [{1, 7, 3}, {3, 16, 6}, {2, 1, 4}] do
      :rand.seed(:exsss, {count, n, 1})
      tables = for _ <- 1..count, do: Enum.shuffle(0..(n - 1))
      perm = Permutation.new(tables)
      mod = Permute.build(name: "t#{count}_#{n}", width: width, tables: tables)
      items = for _ <- 1..(n * count * 4), do: :rand.uniform(1 <<< width) - 1

      for traffic <- @traffic do
        {out, _} = run(mod, items, n, traffic)
        assert out == Permutation.apply(perm, items), "count #{count} n #{n} #{inspect(traffic)}"
      end
    end
  end

  test "a first block other than 0 starts at that table" do
    tables = [Enum.shuffle(0..9), Enum.shuffle(0..9), Enum.shuffle(0..9)]
    mod = Permute.build(name: "first", width: 4, tables: tables, first_block: 2)
    items = for i <- 1..60, do: rem(i * 7, 16)
    {out, _} = run(mod, items, 10, {0.8, 0.8, 9})
    assert out == Permutation.apply(Permutation.new(tables), items, 2)
  end

  test "full rate: one item per clock in steady state" do
    tables = [Enum.shuffle(0..63)]
    mod = Permute.build(name: "rate", width: 8, tables: tables)
    items = for i <- 1..(64 * 10), do: rem(i * 37, 256)
    {out, cycles} = run(mod, items, 64, {1.0, 1.0, 1})
    assert out == Permutation.apply(Permutation.new(tables), items)
    # reset, one block of latency, pipeline: no stall between blocks
    assert cycles <= 64 * 10 + 64 + 12
  end

  test "DVB-T symbol deinterleaver (2k, alternating H and its inverse) on words of 2 bits" do
    cells = Permutation.inverse(Inner.symbol_permutation(:"2k"))

    mod =
      Permute.build(
        name: "dvbt_cells",
        width: 2,
        tables: cells.tables |> Enum.map(&Tuple.to_list/1)
      )

    :rand.seed(:exsss, {3, 3, 3})
    items = for _ <- 1..(1512 * 4), do: :rand.uniform(4) - 1
    {out, _} = run(mod, items, 1512, {0.9, 0.8, 5})
    assert out == Permutation.apply(cells, items)

    assert out ==
             items
             |> Enum.chunk_every(1512)
             |> Enum.with_index()
             |> Enum.flat_map(fn {w, l} ->
               Inner.symbol_deinterleave(w, Inner.symbol_permutation(:"2k"), l)
             end)
  end

  for c <- [:qpsk, :qam16, :qam64] do
    @c c
    test "DVB-T bit deinterleaver, #{c}: bits in blocks of 126 words" do
      v = Inner.bits_per_symbol(@c)
      bits = Permutation.inverse(Inner.bit_interleaver(@c))

      mod =
        Permute.build(
          name: "dvbt_bits_#{@c}",
          width: 1,
          tables: Enum.map(bits.tables, &Tuple.to_list/1)
        )

      :rand.seed(:exsss, {4, 4, v})
      items = for _ <- 1..(126 * v * 3), do: :rand.uniform(2) - 1
      {out, _} = run(mod, items, 126 * v, {0.7, 0.7, v})
      assert out == Permutation.apply(bits, items)
    end
  end

  @tag :yosys
  @tag timeout: 300_000
  test "resources: DVB-T interleavers are a few block RAMs and no DSP" do
    util = fn m ->
      {:ok, u} =
        ExHdl.Synth.Yosys.utilization(ExHdl.Backends.SystemVerilog.RTL.generate(m), m.name)

      u
    end

    cells = Permutation.inverse(Inner.symbol_permutation(:"2k"))
    tables = Enum.map(cells.tables, &Tuple.to_list/1)

    assert %{dsp: 0, bram18: 3, lut: lut} =
             util.(Permute.build(name: "cells", width: 2, tables: tables))

    assert lut < 200

    bits = Permutation.inverse(Inner.bit_interleaver(:qam64))
    tables = Enum.map(bits.tables, &Tuple.to_list/1)
    assert %{dsp: 0, bram18: 1} = util.(Permute.build(name: "bits", width: 1, tables: tables))
  end
end
