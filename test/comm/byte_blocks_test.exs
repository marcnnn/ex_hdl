defmodule ExHdl.Comm.ByteBlocksTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias ExHdl.Comm.{ConvInterleaver, LFSR, Scrambler}

  test "LFSR: maximal length sequences have period 2^n - 1" do
    for {n, taps} <- [{7, [4, 7]}, {11, [9, 11]}, {15, [14, 15]}] do
      r = LFSR.new(length: n, taps: taps, seed: 1)
      {_, r2} = LFSR.bits(r, (1 <<< n) - 1)
      assert r2.state == r.state
    end
  end

  test "LFSR: 802.11 scrambler (x^7 + x^4 + 1, all ones) starts 00001110 11110010" do
    {bits, _} = LFSR.bits(LFSR.new(length: 7, taps: [4, 7], seed: 0b1111111), 16)
    assert bits == [0, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1, 1, 0, 0, 1, 0]
  end

  property "scrambler: native kernel equals the reference" do
    check all period <- integer(1..64),
              keep <- binary(length: period),
              mask <- binary(length: period),
              periods <- integer(0..8),
              data <- binary(length: period * periods) do
      s = Scrambler.new(keep, mask)
      ref = Scrambler.apply(s, data, native: false)
      if ExHdl.SIMD.available?(), do: assert(Scrambler.apply(s, data, native: true) == ref)

      # keep = 0xFF everywhere: applying twice restores the input
      s = Scrambler.new(:binary.copy(<<0xFF>>, period), mask)
      assert Scrambler.apply(s, Scrambler.apply(s, data)) == data
    end
  end

  property "convolutional interleaver: deinterleave(interleave(x)) is x delayed" do
    check all i <- integer(1..16),
              m <- integer(0..8),
              data <- binary(min_length: 1, max_length: 600) do
      c = ConvInterleaver.new(branches: i, depth: m)
      d = ConvInterleaver.delay(c)
      padded = data <> :binary.copy(<<0>>, d)

      for native <- if(ExHdl.SIMD.available?(), do: [false, true], else: [false]) do
        out =
          c
          |> ConvInterleaver.interleave(padded, native: native)
          |> then(&ConvInterleaver.deinterleave(c, &1, native: native))

        assert binary_part(out, d, byte_size(data)) == data

        assert ConvInterleaver.interleave(c, padded, native: native) ==
                 ConvInterleaver.interleave(c, padded, native: false)
      end
    end
  end
end
