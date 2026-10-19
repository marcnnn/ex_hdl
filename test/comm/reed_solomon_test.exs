defmodule ExHdl.Comm.ReedSolomonTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExHdl.Comm.{GF, ReedSolomon}

  # Codes of several standards and fields.
  @codes [
    dvb: [m: 8, field_poly: 0x11D, n: 255, k: 239, shortening: 51],
    atsc: [m: 8, field_poly: 0x11D, n: 255, k: 235, shortening: 48],
    ccsds: [m: 8, field_poly: 0x187, n: 255, k: 223, fcr: 112, prim: 11],
    gf16: [m: 4, field_poly: 0x13, n: 15, k: 9, fcr: 1]
  ]

  test "GF rejects non-primitive polynomials" do
    assert_raise ArgumentError, fn -> GF.new(8, 0x11B) end
    assert GF.order(GF.new(8, 0x11D)) == 255
  end

  test "generator has the parity roots" do
    for {_, opts} <- @codes do
      code = ReedSolomon.new(opts)
      for r <- code.roots, do: assert(GF.eval(code.field, code.generator, r) == 0)
    end
  end

  for {name, opts} <- @codes do
    property "#{name}: corrects up to t errors" do
      code = ReedSolomon.new(unquote(opts))
      q = GF.order(code.field) + 1
      t = div(code.n - code.k, 2)
      len = ReedSolomon.length(code)

      check all msg <- list_of(integer(0..(q - 1)), length: ReedSolomon.message_length(code)),
                count <- integer(0..t),
                positions <- uniq_list_of(integer(0..(len - 1)), length: count),
                values <- list_of(integer(1..(q - 1)), length: count),
                max_runs: 50 do
        cw = ReedSolomon.encode(code, msg)
        assert length(cw) == len

        noisy =
          Enum.zip(positions, values)
          |> Enum.reduce(cw, fn {p, v}, acc -> List.update_at(acc, p, &Bitwise.bxor(&1, v)) end)

        assert {:ok, ^msg, ^count} = ReedSolomon.decode(code, noisy)
      end
    end
  end

  for {name, opts} <- @codes, opts[:m] == 8 do
    test "#{name}: native decoder equals the Elixir reference" do
      code = ReedSolomon.new(unquote(opts))
      len = ReedSolomon.length(code)
      t = div(code.n - code.k, 2)

      codewords =
        for i <- 1..60 do
          msg = :crypto.strong_rand_bytes(ReedSolomon.message_length(code))
          <<cw::binary>> = ReedSolomon.encode_bytes(code, msg)
          errors = rem(i, t + 4)

          Enum.reduce(Enum.take_random(0..(len - 1), errors), cw, fn p, acc ->
            <<a::binary-size(p), b, rest::binary>> = acc
            <<a::binary, Bitwise.bxor(b, 1 + :rand.uniform(254))::8, rest::binary>>
          end)
        end

      ref =
        Enum.reduce(codewords, {[], 0, 0}, fn cw, {o, c, f} ->
          case ReedSolomon.decode_bytes(code, cw) do
            {:ok, m, n} -> {[m | o], c + n, f}
            {:error, _, m} -> {[m | o], c, f + 1}
          end
        end)
        |> then(fn {o, c, f} -> {o |> Enum.reverse() |> IO.iodata_to_binary(), c, f} end)

      {_, corrected, failed} = ref
      assert corrected > 0 and failed > 0

      if ExHdl.SIMD.available?() do
        assert ReedSolomon.decode_all_bytes(code, IO.iodata_to_binary(codewords), native: true) ==
                 ref
      end
    end
  end
end
