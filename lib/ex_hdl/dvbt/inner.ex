defmodule ExHdl.DVBT.Inner do
  @moduledoc """
  DVB-T inner interleaving and mapping (ETSI EN 300 744, 4.3.4 and 4.3.5),
  non-hierarchical, for QPSK, 16-QAM and 64-QAM.

  Symbols are integers of `v` bits (2, 4, 6), one per data carrier, with the
  first bit as the most significant one (as in gr-dtv's byte streams).

    * bit interleaver: per block of 126 symbols, bit `e` of output word `w`
      is bit `e` of input word `H_e(w)`, `H_e(w) = (w + offset_e) mod 126`
    * symbol interleaver: pseudo-random permutation `H(q)` of the data
      carriers of one OFDM symbol, applied forwards on even and backwards on
      odd symbols
    * mapping: Gray-coded QPSK/QAM, normalised to unit average power
  """
  import Bitwise

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

  @doc "Bit interleaving of a list of words (length a multiple of 126)."
  def bit_interleave(words, constellation), do: bit_permute(words, constellation, :forward)

  @doc "Inverse of `bit_interleave/2`."
  def bit_deinterleave(words, constellation), do: bit_permute(words, constellation, :inverse)

  # Output word w, sub-stream e (e = 0 most significant): the bit that
  # input bit i (demux[i] == e) of input word H_e(w) carries.
  defp bit_permute(words, constellation, direction) do
    v = bits_per_symbol(constellation)
    dm = demux(constellation)
    offsets = Enum.take(@offsets, v)

    words
    |> Enum.chunk_every(126)
    |> Enum.flat_map(fn block ->
      block = List.to_tuple(block)

      for w <- 0..125 do
        case direction do
          :forward ->
            Enum.reduce(Enum.with_index(dm), 0, fn {e, i}, acc ->
              src = rem(w + Enum.at(offsets, e), 126)
              acc ||| (elem(block, src) >>> (v - 1 - i) &&& 1) <<< (v - 1 - e)
            end)

          :inverse ->
            # input bit i of word w sits in sub-stream e at output word
            # w - offset_e
            Enum.reduce(Enum.with_index(dm), 0, fn {e, i}, acc ->
              src = Integer.mod(w - Enum.at(offsets, e), 126)
              acc ||| (elem(block, src) >>> (v - 1 - e) &&& 1) <<< (v - 1 - i)
            end)
        end
      end
    end)
  end

  @doc "The symbol interleaver permutation `H(q)` for the data carriers of a mode."
  def symbol_permutation(mode)

  def symbol_permutation(:"2k"),
    do: permutation(2048, 1512, 11, [4, 3, 9, 6, 2, 8, 1, 5, 7, 0], [0, 3])

  def symbol_permutation(:"8k"),
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
    |> List.to_tuple()
  end

  @doc """
  Symbol interleaving of one OFDM symbol's data words. `symbol` is the OFDM
  symbol number within its frame (even/odd decides the direction).
  """
  def symbol_interleave(words, h, symbol) do
    words = List.to_tuple(words)
    n = tuple_size(h)

    if rem(symbol, 2) == 0 do
      # y_H(q) = y'_q
      Enum.reduce(0..(n - 1), :array.new(n), fn q, acc ->
        :array.set(elem(h, q), elem(words, q), acc)
      end)
      |> :array.to_list()
    else
      # y_q = y'_H(q)
      for q <- 0..(n - 1), do: elem(words, elem(h, q))
    end
  end

  @doc "Inverse of `symbol_interleave/3`."
  def symbol_deinterleave(words, h, symbol) do
    words = List.to_tuple(words)
    n = tuple_size(h)

    if rem(symbol, 2) == 0 do
      for q <- 0..(n - 1), do: elem(words, elem(h, q))
    else
      Enum.reduce(0..(n - 1), :array.new(n), fn q, acc ->
        :array.set(elem(h, q), elem(words, q), acc)
      end)
      |> :array.to_list()
    end
  end

  @doc """
  Gray mapping of a word to a constellation point `{re, im}`, normalised to
  unit average power (EN 300 744 figure 9): even-indexed bits y0, y2, y4
  select the in-phase level, odd-indexed bits y1, y3, y5 the quadrature level.
  """
  def map_symbol(word, constellation) do
    v = bits_per_symbol(constellation)
    bits = for k <- (v - 1)..0//-1, do: word >>> k &&& 1
    i_bits = Enum.take_every(bits, 2)
    q_bits = bits |> Enum.drop(1) |> Enum.take_every(2)
    {level(i_bits) * norm(constellation), level(q_bits) * norm(constellation)}
  end

  # Gray: first bit is the sign (0 -> positive), the rest selects the
  # magnitude, outer levels first: 1 bit: 1; 2 bits: 3/1; 3 bits: 7/5/1/3.
  defp level([s]), do: sign(s)
  defp level([s, a]), do: sign(s) * if(a == 0, do: 3, else: 1)
  defp level([s, a, b]), do: sign(s) * Enum.at([7, 5, 1, 3], a * 2 + b)

  defp sign(0), do: 1
  defp sign(1), do: -1

  defp norm(:qpsk), do: 1 / :math.sqrt(2)
  defp norm(:qam16), do: 1 / :math.sqrt(10)
  defp norm(:qam64), do: 1 / :math.sqrt(42)

  @doc "Hard decision: the word whose constellation point is nearest."
  def demap_symbol({re, im}, constellation) do
    v = bits_per_symbol(constellation)

    Enum.min_by(0..((1 <<< v) - 1), fn w ->
      {a, b} = map_symbol(w, constellation)
      (a - re) * (a - re) + (b - im) * (b - im)
    end)
  end
end
