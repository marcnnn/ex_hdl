defmodule ExHdl.Comm.Constellation do
  @moduledoc """
  Mapping of `bits`-bit words (first bit = most significant) to complex
  points, normalised to unit average power, and hard decisions.

  `new/1` takes any point table (PSK, APSK, ...). `square/2` builds
  square QAM from one axis mapping: `axis_levels` lists the amplitude
  level (odd integers) for each axis code, and `layout` says which word
  bits drive which axis: `:interleaved` (I from bits 0, 2, 4, ...; Q from
  1, 3, 5, ..., as DVB-T) or `:split` (I from the first half, Q from the
  second, as IEEE 802.11).
  """
  import Bitwise

  defstruct [:bits, :points, :square]

  @doc "From a list of `{re, im}` points indexed by word; normalised."
  def new(points) do
    n = length(points)
    bits = round(:math.log2(n))
    true = 1 <<< bits == n
    %__MODULE__{bits: bits, points: points |> normalise() |> List.to_tuple()}
  end

  @doc "Square QAM, see the module documentation."
  def square(axis_levels, layout) when layout in [:interleaved, :split] do
    l = length(axis_levels)
    half = round(:math.log2(l))
    true = 1 <<< half == l and Enum.sort(axis_levels) == Enum.to_list(-(l - 1)..(l - 1)//2)
    bits = 2 * half
    levels = List.to_tuple(axis_levels)

    raw =
      for w <- 0..((1 <<< bits) - 1) do
        {i, q} = split(w, bits, layout)
        {elem(levels, i), elem(levels, q)}
      end

    # per axis: word bits contributed by each level index (ascending level)
    code_of_level = axis_levels |> Enum.with_index() |> Enum.sort() |> Enum.map(&elem(&1, 1))

    %__MODULE__{
      bits: bits,
      points: raw |> normalise() |> List.to_tuple(),
      square: %{
        levels: l,
        scale: :math.sqrt(mean_power(raw)),
        i_words: Enum.map(code_of_level, &join(&1, 0, bits, layout)),
        q_words: Enum.map(code_of_level, &join(0, &1, bits, layout))
      }
    }
  end

  @doc "Axis levels with binary-reflected Gray code over ascending levels (802.11)."
  def reflected_gray_axis(bits) do
    l = 1 <<< bits

    for code <- 0..(l - 1) do
      idx = Enum.find(0..(l - 1), &(bxor(&1, &1 >>> 1) == code))
      2 * idx - (l - 1)
    end
  end

  # axis codes (I, Q) of a word
  defp split(w, bits, layout) do
    half = div(bits, 2)

    case layout do
      :split ->
        {w >>> half, w &&& (1 <<< half) - 1}

      :interleaved ->
        Enum.reduce(0..(half - 1), {0, 0}, fn j, {i, q} ->
          {i <<< 1 ||| (w >>> (bits - 1 - 2 * j) &&& 1),
           q <<< 1 ||| (w >>> (bits - 2 - 2 * j) &&& 1)}
        end)
    end
  end

  defp join(i, q, bits, layout) do
    half = div(bits, 2)

    case layout do
      :split ->
        i <<< half ||| q

      :interleaved ->
        Enum.reduce(0..(half - 1), 0, fn j, w ->
          w ||| (i >>> (half - 1 - j) &&& 1) <<< (bits - 1 - 2 * j) |||
            (q >>> (half - 1 - j) &&& 1) <<< (bits - 2 - 2 * j)
        end)
    end
  end

  defp mean_power(points), do: Enum.sum(for({a, b} <- points, do: a * a + b * b)) / length(points)

  defp normalise(points) do
    norm = 1 / :math.sqrt(mean_power(points))
    for {a, b} <- points, do: {a * norm, b * norm}
  end

  @doc "The point of a word."
  def map(%__MODULE__{points: p}, word), do: elem(p, word)

  @doc "Hard decision (reference): the word whose point is nearest; ties to the smaller word."
  def demap(%__MODULE__{points: p}, {re, im}) do
    Enum.min_by(0..(tuple_size(p) - 1), fn w ->
      {a, b} = elem(p, w)
      (a - re) * (a - re) + (b - im) * (b - im)
    end)
  end

  @doc """
  Tables for `demap_tensor/2` (tensors, so they can be passed into a
  compiled computation).
  """
  def tensor_tables(%__MODULE__{square: nil, points: p}) do
    pts = Tuple.to_list(p)
    %{points: Nx.tensor(Enum.map(pts, fn {a, b} -> Complex.new(a, b) end), type: :c64)}
  end

  def tensor_tables(%__MODULE__{square: sq}) do
    %{i_words: Nx.tensor(sq.i_words, type: :u8), q_words: Nx.tensor(sq.q_words, type: :u8)}
  end

  @doc """
  Hard decisions for a complex tensor (usable inside `defn` via
  `deftransform`): square QAM decides each axis on its own, other
  constellations by nearest point. Words as `u8`. Same decisions as
  `demap/2` except exactly on a decision boundary (square QAM: ties go to
  the larger level, not the smaller word).
  """
  def demap_tensor(%__MODULE__{square: nil}, points, t) do
    points
    |> Nx.new_axis(-1)
    |> Nx.subtract(t.points)
    |> Nx.abs()
    |> Nx.argmin(axis: -1, tie_break: :low)
    |> Nx.as_type(:u8)
  end

  def demap_tensor(%__MODULE__{square: sq}, points, t) do
    i = axis_index(Nx.real(points), sq)
    q = axis_index(Nx.imag(points), sq)
    Nx.bitwise_or(Nx.take(t.i_words, i), Nx.take(t.q_words, q))
  end

  # nearest of the levels -(L-1), ..., L-1 (index 0..L-1)
  defp axis_index(a, %{levels: l, scale: scale}) do
    a
    |> Nx.multiply(scale)
    |> Nx.add(l)
    |> Nx.divide(2)
    |> Nx.floor()
    |> Nx.clip(0, l - 1)
    |> Nx.as_type(:s32)
  end
end
