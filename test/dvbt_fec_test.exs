defmodule ExHdl.DVBT.FECTest do
  @moduledoc """
  Self-consistency of the DVB-T outer/inner coding reference implementations
  (EN 300 744 4.3). Comparison against GNU Radio's gr-dtv is in
  test/dvbt_gnuradio_test.exs.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExHdl.DVBT.{Convolutional, EnergyDispersal, OuterInterleaver, ReedSolomon}

  @moduletag timeout: 300_000

  defp packet, do: map(binary(length: 187), &(<<0x47>> <> &1))

  property "energy dispersal: descramble(scramble(ts)) == ts, first sync byte of 8 inverted" do
    check all packets <- list_of(packet(), length: 16), max_runs: 20 do
      ts = IO.iodata_to_binary(packets)
      s = EnergyDispersal.scramble(ts)
      assert EnergyDispersal.descramble(s) == ts

      assert for(i <- 0..15, do: :binary.at(s, i * 188)) ==
               List.flatten(List.duplicate([0xB8 | List.duplicate(0x47, 7)], 2))
    end
  end

  property "RS(204,188): corrects up to 8 byte errors, detects more" do
    check all payload <- binary(length: 188),
              errors <- integer(0..12),
              seed <- integer(1..1000),
              max_runs: 80 do
      :rand.seed(:exsss, {seed, 1, 2})
      cw = ReedSolomon.encode(payload)
      positions = Enum.take_random(0..203, errors)

      bad =
        Enum.reduce(positions, cw, fn p, acc ->
          <<a::binary-size(p), b, c::binary>> = acc
          <<a::binary, Bitwise.bxor(b, :rand.uniform(255)), c::binary>>
        end)

      case ReedSolomon.decode(bad) do
        {:ok, decoded, n} ->
          assert errors <= 8 or decoded != payload
          if errors <= 8, do: assert({decoded, n} == {payload, errors})

        {:error, :uncorrectable, _} ->
          assert errors > 8
      end
    end
  end

  test "outer interleaver: deinterleave(interleave(x)) == x after 2244 bytes" do
    data = :crypto.strong_rand_bytes(204 * 40)
    d = OuterInterleaver.delay()
    out = data |> OuterInterleaver.interleave() |> OuterInterleaver.deinterleave()
    assert binary_part(out, d, byte_size(data) - d) == binary_part(data, 0, byte_size(data) - d)
  end

  for rate <- [{1, 2}, {2, 3}, {3, 4}, {5, 6}, {7, 8}] do
    property "Viterbi #{elem(rate, 0)}/#{elem(rate, 1)}: corrects sparse bit errors" do
      check all bits <- list_of(integer(0..1), length: 400),
                seed <- integer(1..1000),
                max_runs: 10 do
        :rand.seed(:exsss, {seed, 3, 4})
        coded = Convolutional.encode(bits ++ List.duplicate(0, 6), unquote(rate))
        # a few isolated errors, far apart
        flips = 0..(length(coded) - 1)//97 |> Enum.drop(1) |> Enum.take(3)

        noisy =
          coded
          |> Enum.with_index()
          |> Enum.map(fn {b, i} -> if i in flips, do: 1 - b, else: b end)

        assert Convolutional.decode(noisy, unquote(rate)) |> Enum.take(400) == bits
      end
    end
  end
end
