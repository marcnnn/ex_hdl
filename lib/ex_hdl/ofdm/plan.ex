defmodule ExHdl.OFDM.Plan do
  @moduledoc """
  The row schedule of the pilot-aided equaliser (`ExHdl.OFDM.Equalise`),
  from the same tables as `ExSdr.Comm.OFDM.FixedFrontEnd.prepare/3`.

  `spec` is a front end spec map as ExSdr's `FrontEnd` takes it (only
  fields are read, so this module needs no ExSdr module):

    * `spec.ofdm`: `%{fft, cp, bins, classes: [%{pilots: [{carrier, {re, im}}], data: [carrier]}]}`
    * `spec.constellation.square`: `%{levels, scale, i_words, q_words}`

  Per pilot class (the symbol's index modulo the number of classes) the
  equaliser walks the symbol's carriers in the order of the channel
  interpolation: the first two pilots, then the data carriers up to the
  second pilot, then the next pilot and its data carriers, and so on.
  Every pilot is computed once (`Y * conj(P) / |P|^2`) and shifted into
  a pair of registers (left and right neighbour), every data carrier
  interpolates between them. Data carriers come out in ascending
  carrier order, as in `FixedFrontEnd`.

  A row is `%{kind: :pilot | :data, bin, a, b, last}`: the FFT bin to read,
  for a pilot the quantised `conj(P) / |P|^2` (`a` real, `b` imaginary part,
  in the coefficient format), for a data carrier the quantised
  interpolation weight (`a`); `last` marks the symbol's last row.
  Numbers are computed as in `FixedFrontEnd.tables/3` (float32 weights and
  pilot values, then `NxFixed.Num.quantize_constants/2`), so the integers
  are the ones of the software front end.
  """
  alias NxFixed.Num

  @doc """
  `%{classes: [rows], bases: [first row of each class in the table],
  total: rows over all classes, data: data carriers per symbol}`.
  Option `:coef` (the coefficient format, default q(16, 15)).
  """
  def build(spec, opts \\ []) do
    coef = Keyword.get(opts, :coef, Num.q(16, 15, lut_bits: 12))
    o = spec.ofdm
    bins = List.to_tuple(o.bins)
    n = length(o.bins)

    classes =
      for c <- o.classes do
        pilots = Enum.sort(c.pilots)
        ks = Enum.map(pilots, &elem(&1, 0))
        np = length(ks)
        np >= 2 or raise ArgumentError, "an equaliser class needs two pilots at least"

        {left, weight} = interpolation(ks, n)
        weight = weight |> Nx.tensor(type: :f32) |> Nx.to_flat_list()
        left = List.to_tuple(left)
        weight = List.to_tuple(weight)
        inv = pilots |> Enum.map(&elem(&1, 1)) |> inverses()
        quant = fn v -> hd(Num.quantize_constants([v], coef)) end
        inv = Enum.map(inv, fn {re, im} -> {quant.(re), quant.(im)} end)
        inv = List.to_tuple(inv)
        pilot_row = fn j -> pilot_row(j, ks, bins, inv) end

        data_rows =
          Enum.group_by(
            c.data,
            &elem(left, &1),
            &%{kind: :data, bin: elem(bins, &1), a: quant.(elem(weight, &1)), b: 0, last: false}
          )

        rows =
          [pilot_row.(0), pilot_row.(1)] ++
            Map.get(data_rows, 0, []) ++
            Enum.flat_map(1..(np - 2)//1, fn j ->
              [pilot_row.(j + 1) | Map.get(data_rows, j, [])]
            end)

        mark_last(rows)
      end

    sizes = Enum.map(classes, &length/1)
    bases = Enum.scan(sizes, 0, &(&1 + &2)) |> then(&[0 | Enum.drop(&1, -1)])
    [data] = classes |> Enum.map(fn r -> Enum.count(r, &(&1.kind == :data)) end) |> Enum.uniq()
    %{classes: classes, bases: bases, total: Enum.sum(sizes), data: data}
  end

  defp pilot_row(j, ks, bins, inv) do
    {re, im} = elem(inv, j)
    %{kind: :pilot, bin: elem(bins, Enum.at(ks, j)), a: re, b: im, last: false}
  end

  defp mark_last(rows) do
    {last, init} = List.pop_at(rows, -1)

    last.kind == :data or
      raise ArgumentError, "the last carrier of a symbol must be a data carrier"

    init ++ [%{last | last: true}]
  end

  # left pilot index and weight of every carrier (extrapolating past the
  # outer pilots), as OFDM.build_tables/1
  defp interpolation(ks, n) do
    count = length(ks)

    for k <- 0..(n - 1) do
      j = (Enum.count(ks, &(&1 <= k)) - 1) |> max(0) |> min(count - 2)
      {k0, k1} = {Enum.at(ks, j), Enum.at(ks, j + 1)}
      {j, (k - k0) / (k1 - k0)}
    end
    |> Enum.unzip()
  end

  # conj(P) / |P|^2 of the pilot values, from their float32 representation
  defp inverses(values) do
    if Enum.all?(values, fn {_, im} -> im == 0.0 end) do
      values
      |> Enum.map(&elem(&1, 0))
      |> Nx.tensor(type: :f32)
      |> Nx.to_flat_list()
      |> Enum.map(&{1 / &1, 0.0})
    else
      values
      |> Enum.map(fn {a, b} -> Complex.new(a, b) end)
      |> Nx.tensor(type: :c64)
      |> Nx.to_flat_list()
      |> Enum.map(fn c ->
        {a, b} = {Complex.real(c), Complex.imag(c)}
        {a / (a * a + b * b), -b / (a * a + b * b)}
      end)
    end
  end
end
