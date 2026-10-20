defmodule ExHdl.RegsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  alias ExHdl.Regs

  # A register with random non-overlapping fields covering parts of 32
  # bits, random access types and resets.
  defp layout do
    gen all(
          widths <- list_of(integer(1..12), min_length: 1, max_length: 8),
          gaps <- list_of(integer(0..3), length: length(widths)),
          accesses <- list_of(member_of([:rw, :rw, :wo, :w1c, :w1s, :ro, :rc]), length: 8),
          seeds <- list_of(integer(0..0xFFFF), length: 8)
        ) do
      {fields, _} =
        widths
        |> Enum.zip(gaps)
        |> Enum.with_index()
        |> Enum.flat_map_reduce(0, fn {{w, g}, i}, lo ->
          lo = lo + g

          if lo + w <= 32 do
            {[{:"f#{i}", lo, w, Enum.at(accesses, i), rem(Enum.at(seeds, i), 1 <<< w)}], lo + w}
          else
            {[], lo}
          end
        end)

      fields
    end
    |> filter(&(&1 != []))
  end

  defp map_of(fields) do
    Regs.build("p", [], fn ->
      Regs.__register__(:r, [], fn ->
        for {n, lo, w, a, reset} <- fields do
          Regs.field(n, lo..(lo + w - 1), a, reset: if(a in [:ro], do: 0, else: reset))
        end
      end)
    end)
  end

  defp values(fields) do
    fields
    |> Enum.map(fn {n, _lo, w, _a, _} -> {n, integer(0..((1 <<< w) - 1))} end)
    |> fixed_map()
  end

  property "decode(encode(v)) returns the written rw fields" do
    check all(fields <- layout(), vals <- values(fields), max_runs: 200) do
      m = map_of(fields)
      rw = for {n, _, _, :rw, _} <- fields, into: %{}, do: {n, vals[n]}
      word = Regs.encode(m, :r, rw)
      assert word in 0..0xFFFF_FFFF
      decoded = Regs.decode(m, :r, word)
      assert Map.take(decoded, Map.keys(rw)) == rw
    end
  end

  property "encode places each field under its mask and nowhere else" do
    check all(fields <- layout(), vals <- values(fields), max_runs: 200) do
      m = map_of(fields)
      writable = for {n, _, _, a, _} <- fields, a in [:rw, :wo, :w1c, :w1s], do: n

      for n <- writable do
        f = Regs.field!(m, :r, n)
        others = for {o, _, _, a, _} <- fields, o != n, a in [:w1c, :w1s], into: %{}, do: {o, 0}
        rest = Regs.encode(m, :r, Map.put(others, n, 0))
        word = Regs.encode(m, :r, Map.put(others, n, vals[n]))
        assert bxor(word, rest) == vals[n] <<< f.lo
        assert (bxor(word, rest) &&& bnot(Regs.mask(f))) == 0
      end
    end
  end

  property "update changes only the named fields, decode reads every readable field" do
    check all(
            fields <- layout(),
            vals <- values(fields),
            word <- integer(0..0xFFFF_FFFF),
            max_runs: 200
          ) do
      m = map_of(fields)
      named = for {n, _, _, a, _} <- fields, a in [:rw, :wo], into: %{}, do: {n, vals[n]}
      new = Regs.update(m, :r, word, named)
      mask = named |> Map.keys() |> Enum.map(&Regs.mask(Regs.field!(m, :r, &1))) |> Enum.sum()

      assert (new &&& bnot(mask)) == (word &&& bnot(mask))

      for {n, v} <- named do
        f = Regs.field!(m, :r, n)
        assert (new >>> f.lo &&& (1 <<< f.width) - 1) == v
      end

      decoded = Regs.decode(m, :r, word)

      for {n, lo, w, a, _} <- fields do
        if a == :wo,
          do: refute(Map.has_key?(decoded, n)),
          else: assert(decoded[n] == (word >>> lo &&& (1 <<< w) - 1))
      end
    end
  end

  property "masks of a register are disjoint" do
    check all(fields <- layout(), max_runs: 100) do
      m = map_of(fields)
      masks = Enum.map(Regs.register!(m, :r).fields, &Regs.mask/1)
      assert Enum.reduce(masks, 0, &bor/2) == Enum.sum(masks)
    end
  end
end
