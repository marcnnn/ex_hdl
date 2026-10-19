defmodule ExHdl.DVBT.Inner do
  @moduledoc """
  DVB-T inner interleaving and mapping (ETSI EN 300 744, 4.3.4 and 4.3.5),
  non-hierarchical, for QPSK, 16-QAM and 64-QAM, as configurations of
  `ExHdl.Comm.Permutation` and `ExHdl.Comm.Constellation`.

  Symbols are integers of `v` bits (2, 4, 6), one per data carrier, with the
  first bit as the most significant one (as in gr-dtv's byte streams).

    * bit interleaver: per block of 126 symbols, bit `e` of output word `w`
      is bit `e` of input word `H_e(w)`, `H_e(w) = (w + offset_e) mod 126`,
      after the demultiplexer: one bit permutation over 126 * v bits
    * symbol interleaver: pseudo-random permutation `H(q)` of the data
      carriers of one OFDM symbol, applied forwards on even and backwards on
      odd symbols
    * mapping: Gray-coded QPSK/QAM, I from the even and Q from the odd word
      bits, normalised to unit average power
  """
  import Bitwise
  alias ExHdl.Comm.{Constellation, Permutation}

  @offsets [0, 63, 105, 42, 21, 84]

  @doc "Bits per carrier."
  def bits_per_symbol(:qpsk), do: 2
  def bits_per_symbol(:qam16), do: 4
  def bits_per_symbol(:qam64), do: 6

  @doc """
  Groups the punctured code bits into `v`-bit words as gr-dtv's inner coder
  does: consecutive bits, the first one as most significant bit. (The
  standard's demultiplexer order for 16/64-QAM is applied by the bit
  interleaver below.)
  """
  def group_bits(bits, constellation) do
    v = bits_per_symbol(constellation)

    bits
    |> Enum.chunk_every(v, v, :discard)
    |> Enum.map(fn word -> Enum.reduce(word, 0, &(&2 <<< 1 ||| &1)) end)
  end

  # Demultiplexer (EN 300 744 figure 7): input bit i of a word goes to
  # sub-stream demux[i]; non-hierarchical.
  defp demux(:qpsk), do: [0, 1]
  defp demux(:qam16), do: [0, 2, 1, 3]
  defp demux(:qam64), do: [0, 2, 4, 1, 3, 5]

  @doc """
  The bit interleaver of a constellation as a permutation of the 126 * v
  bits of a block (bit j of word w at index w * v + j, j = 0 the MSB):
  output word w, sub-stream e is input bit i (demux[i] = e) of input word
  (w + offset_e) mod 126.
  """
  def bit_interleaver(constellation) do
    cached({:bit_interleaver, constellation}, fn ->
      v = bits_per_symbol(constellation)
      dm = demux(constellation)

      table =
        for w <- 0..125, e <- 0..(v - 1) do
          i = Enum.find_index(dm, &(&1 == e))
          rem(w + Enum.at(@offsets, e), 126) * v + i
        end

      Permutation.new(table)
    end)
  end

  @doc "Bit interleaving of a list of words (length a multiple of 126)."
  def bit_interleave(words, constellation),
    do: permute_bits(words, constellation, bit_interleaver(constellation))

  @doc "Inverse of `bit_interleave/2`."
  def bit_deinterleave(words, constellation),
    do: permute_bits(words, constellation, Permutation.inverse(bit_interleaver(constellation)))

  defp permute_bits(words, constellation, perm) do
    v = bits_per_symbol(constellation)

    words
    |> Enum.flat_map(fn w -> for k <- (v - 1)..0//-1, do: w >>> k &&& 1 end)
    |> then(&Permutation.apply(perm, &1))
    |> Enum.chunk_every(v)
    |> Enum.map(fn bits -> Enum.reduce(bits, 0, &(&2 <<< 1 ||| &1)) end)
  end

  @doc """
  The symbol interleaver of a mode: block (OFDM symbol) l uses
  `y_H(q) = y'_q` for even l, `y_q = y'_H(q)` for odd l.
  """
  def symbol_permutation(mode) do
    cached({:symbol_interleaver, mode}, fn ->
      h = h_table(mode)
      inverse = h |> Enum.with_index() |> Enum.sort() |> Enum.map(&elem(&1, 1))
      Permutation.new([inverse, h])
    end)
  end

  defp h_table(:"2k"), do: permutation(2048, 1512, 11, [4, 3, 9, 6, 2, 8, 1, 5, 7, 0], [0, 3])

  defp h_table(:"8k"),
    do: permutation(8192, 6048, 13, [7, 1, 4, 2, 9, 6, 8, 10, 0, 3, 11, 5], [0, 1, 4, 6])

  # EN 300 744 4.3.4.2: R'_i is an (nr - 1)-bit LFSR word, R_i a bit
  # permutation of it (perm[j] = position in R_i of bit j of R'_i),
  # H(q) = (i mod 2) * 2^(nr-1) + R_i, keeping values below n_max.
  defp permutation(m_max, n_max, nr, perm, taps) do
    width = nr - 1

    words =
      Enum.scan(0..(m_max - 1), 0, fn i, prev ->
        cond do
          i < 2 ->
            0

          i == 2 ->
            1

          true ->
            feedback = Enum.reduce(taps, 0, fn t, acc -> bxor(acc, prev >>> t &&& 1) end)
            prev >>> 1 ||| feedback <<< (width - 1)
        end
      end)

    words
    |> Enum.with_index()
    |> Enum.map(fn {r_prime, i} ->
      r =
        perm
        |> Enum.with_index()
        |> Enum.reduce(0, fn {target, j}, acc -> acc ||| (r_prime >>> j &&& 1) <<< target end)

      rem(i, 2) <<< width ||| r
    end)
    |> Enum.filter(&(&1 < n_max))
  end

  @doc """
  Symbol interleaving of one OFDM symbol's data words. `symbol` is the OFDM
  symbol number within its frame (even/odd decides the direction).
  """
  def symbol_interleave(words, perm, symbol), do: Permutation.apply(perm, words, symbol)

  @doc "Inverse of `symbol_interleave/3`."
  def symbol_deinterleave(words, perm, symbol),
    do: Permutation.apply(Permutation.inverse(perm), words, symbol)

  @doc """
  The constellation (EN 300 744 figure 9): per axis the first bit is the
  sign (0 positive), the rest selects the magnitude, outer levels first.
  """
  def constellation(c) do
    axis =
      case c do
        :qpsk -> [1, -1]
        :qam16 -> [3, 1, -3, -1]
        :qam64 -> [7, 5, 1, 3, -7, -5, -1, -3]
      end

    cached({:constellation, c}, fn -> Constellation.square(axis, :interleaved) end)
  end

  @doc "Mapping of a word to a constellation point `{re, im}`."
  def map_symbol(word, c), do: Constellation.map(constellation(c), word)

  @doc "Hard decision: the word whose constellation point is nearest."
  def demap_symbol(point, c), do: Constellation.demap(constellation(c), point)

  defp cached(key, fun) do
    key = {__MODULE__, key}

    case :persistent_term.get(key, nil) do
      nil ->
        v = fun.()
        :persistent_term.put(key, v)
        v

      v ->
        v
    end
  end
end
