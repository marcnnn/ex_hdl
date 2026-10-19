defmodule ExHdl.Comm.OFDM do
  @moduledoc """
  OFDM symbol structure, modulation and pilot-aided demodulation.

  A configuration holds:

    * `fft`, `cp`: FFT size and cyclic prefix length (samples)
    * `bins`: the FFT bin of each logical carrier 0..N-1 (see
      `centered_bins/3`)
    * `classes`: the pilot pattern repeats every `length(classes)`
      symbols; symbol i belongs to class `rem(i, period)`. Each class lists
      its pilots as `{carrier, {re, im}}` (sorted by carrier) and its data
      carriers (ascending); every class has the same number of data
      carriers. Other carriers (signalling, guard) are neither.
    * `scale`: applied to the inverse FFT output (`Nx.ifft` divides by
      the FFT size)

  The receiver estimates the channel at the pilots, interpolates linearly
  across frequency (extrapolating past the outer pilots) and divides.
  `demodulate/3` is the list reference; `carriers/4`, `equalise/3` and
  `ExHdl.Comm.OFDM.FrontEnd` are the tensor versions.
  """
  defstruct [:fft, :cp, :bins, :classes, :scale, :data_count]

  def new(opts) do
    classes =
      opts
      |> Keyword.fetch!(:classes)
      |> Enum.map(fn c ->
        %{pilots: Enum.sort(c.pilots), data: c.data}
      end)

    [data_count] = classes |> Enum.map(&length(&1.data)) |> Enum.uniq()

    %__MODULE__{
      fft: Keyword.fetch!(opts, :fft),
      cp: Keyword.fetch!(opts, :cp),
      bins: Keyword.fetch!(opts, :bins),
      classes: classes,
      scale: Keyword.get(opts, :scale, 1.0),
      data_count: data_count
    }
  end

  @doc """
  Bins for `count` carriers whose first sits `first` subcarriers from DC
  (negative below), e.g. DVB-T 2k: `centered_bins(2048, -852, 1705)`.
  """
  def centered_bins(fft, first, count),
    do: for(k <- 0..(count - 1), do: Integer.mod(first + k, fft))

  def period(%__MODULE__{classes: c}), do: length(c)
  def symbol_length(%__MODULE__{fft: f, cp: c}), do: f + c
  def carrier_count(%__MODULE__{bins: b}), do: length(b)

  # -- transmitter ------------------------------------------------------------

  @doc """
  Modulates symbols: a list of `{class, data, extra}` with `data` the
  points `{re, im}` of the class's data carriers and `extra` further
  `{carrier, {re, im}}` (signalling). Returns a complex tensor of
  `length(symbols) * (fft + cp)` samples.
  """
  def modulate(%__MODULE__{} = o, symbols) do
    n = length(symbols)
    bins = List.to_tuple(o.bins)
    zero = Complex.new(0.0, 0.0)

    spectra =
      for {class, data, extra} <- symbols do
        c = Enum.at(o.classes, class)

        cells =
          Enum.zip(c.data, data) ++ c.pilots ++ extra

        by_bin = Map.new(cells, fn {k, {re, im}} -> {elem(bins, k), Complex.new(re, im)} end)
        for b <- 0..(o.fft - 1), do: Map.get(by_bin, b, zero)
      end

    spectra
    |> Nx.tensor(type: :c64)
    |> Nx.ifft()
    |> Nx.multiply(o.scale)
    |> then(fn t ->
      Nx.concatenate([Nx.slice_along_axis(t, o.fft - o.cp, o.cp, axis: 1), t], axis: 1)
    end)
    |> Nx.reshape({n * (o.fft + o.cp)})
  end

  # -- reference receiver -----------------------------------------------------

  @doc """
  Demodulates symbols starting at a symbol boundary; the first one has
  class `first_class`. Returns `{data, channel}` per symbol: the equalised
  data carriers `{re, im}` in carrier order and the channel estimate (a
  map carrier -> `{re, im}`).
  """
  def demodulate(%__MODULE__{} = o, samples, first_class) do
    n = div(Nx.size(samples), o.fft + o.cp)
    bins = List.to_tuple(o.bins)

    samples
    |> Nx.reshape({n, o.fft + o.cp})
    |> Nx.slice_along_axis(o.cp, o.fft, axis: 1)
    |> Nx.fft()
    |> Nx.to_list()
    |> Enum.with_index(first_class)
    |> Enum.map(fn {row, i} ->
      row = List.to_tuple(row)
      carrier = fn k -> row |> elem(elem(bins, k)) |> to_pair() end
      equalise_symbol(carrier, Enum.at(o.classes, rem(i, period(o))), carrier_count(o))
    end)
  end

  defp to_pair(%Complex{re: re, im: im}), do: {re, im}
  defp to_pair(x) when is_number(x), do: {x * 1.0, 0.0}

  defp equalise_symbol(carrier, class, n) do
    gains = for {k, p} <- class.pilots, do: {k, divide(carrier.(k), p)}
    channel = interpolate(gains, n)

    data =
      for k <- class.data do
        {hr, hi} = Map.fetch!(channel, k)
        {re, im} = carrier.(k)
        d = hr * hr + hi * hi
        {(re * hr + im * hi) / d, (im * hr - re * hi) / d}
      end

    {data, channel}
  end

  defp divide({a, b}, {c, d}) when d == 0, do: {a / c, b / c}

  defp divide({a, b}, {c, d}) do
    m = c * c + d * d
    {(a * c + b * d) / m, (b * c - a * d) / m}
  end

  # linear between neighbouring pilots, the outer segments extended
  defp interpolate(gains, n) do
    segments = Enum.chunk_every(gains, 2, 1, :discard)
    {first_k, _} = hd(gains)
    {last_k, last_g} = List.last(gains)

    inner =
      Enum.flat_map(segments, fn [{k0, g0}, {k1, g1}] ->
        for k <- k0..(k1 - 1), do: {k, lerp(g0, g1, (k - k0) / (k1 - k0))}
      end)

    [[{k0, g0}, {k1, g1}] | _] = segments
    [{k2, g2}, {k3, g3}] = List.last(segments)
    below = for k <- 0..(first_k - 1)//1, do: {k, lerp(g0, g1, (k - k0) / (k1 - k0))}
    above = for k <- (last_k + 1)..(n - 1)//1, do: {k, lerp(g2, g3, (k - k2) / (k3 - k2))}

    Map.new(below ++ inner ++ above) |> Map.put(last_k, last_g)
  end

  defp lerp({r0, i0}, {r1, i1}, t), do: {r0 + (r1 - r0) * t, i0 + (i1 - i0) * t}

  # -- tensor receiver --------------------------------------------------------

  @doc """
  FFT of `n` symbols starting at a symbol boundary: `c64[n][carriers]` in
  carrier order. `freq_offset` (subcarrier spacings) is removed first.
  """
  def carriers(%__MODULE__{} = o, samples, n, freq_offset \\ 0.0) do
    sym = o.fft + o.cp
    x = Nx.slice(samples, [0], [n * sym])

    x =
      if freq_offset == 0.0,
        do: x,
        else:
          Nx.multiply(
            x,
            Nx.exp(
              Nx.multiply(
                Nx.complex(0.0, -2 * :math.pi() * freq_offset / o.fft),
                Nx.iota({n * sym}, type: :f32)
              )
            )
          )

    x
    |> Nx.reshape({n, sym})
    |> Nx.slice_along_axis(o.cp, o.fft, axis: 1)
    |> Nx.fft()
    |> Nx.take(Nx.tensor(o.bins), axis: 1)
  end

  @doc """
  Pilot, interpolation and data tables per class as tensors
  (`[period][...]`, pilot lists padded by repeating the last pilot).
  """
  def tables(%__MODULE__{} = o) do
    key = {__MODULE__, :tables, :erlang.phash2(o)}

    case :persistent_term.get(key, nil) do
      nil ->
        t = build_tables(o)
        :persistent_term.put(key, t)
        t

      t ->
        t
    end
  end

  defp build_tables(o) do
    n = carrier_count(o)
    max_pilots = o.classes |> Enum.map(&length(&1.pilots)) |> Enum.max()

    real? =
      Enum.all?(o.classes, fn c -> Enum.all?(c.pilots, fn {_, {_, im}} -> im == 0.0 end) end)

    per_class =
      for c <- o.classes do
        ks = Enum.map(c.pilots, &elem(&1, 0))
        count = length(ks)

        {left, weight} =
          for k <- 0..(n - 1) do
            j = (Enum.count(ks, &(&1 <= k)) - 1) |> max(0) |> min(count - 2)
            {k0, k1} = {Enum.at(ks, j), Enum.at(ks, j + 1)}
            {j, (k - k0) / (k1 - k0)}
          end
          |> Enum.unzip()

        pad = max_pilots - count
        values = Enum.map(c.pilots, &elem(&1, 1))
        values = values ++ List.duplicate(List.last(values), pad)

        values =
          if real?,
            do: Nx.tensor(Enum.map(values, &elem(&1, 0)), type: :f32),
            else: Nx.tensor(Enum.map(values, fn {a, b} -> Complex.new(a, b) end), type: :c64)

        %{
          pilots: Nx.tensor(ks ++ List.duplicate(List.last(ks), pad)),
          values: values,
          left: Nx.tensor(left),
          weight: Nx.tensor(weight, type: :f32),
          data: Nx.tensor(c.data)
        }
      end

    for field <- [:pilots, :values, :left, :weight, :data], into: %{} do
      {field, per_class |> Enum.map(& &1[field]) |> Nx.stack()}
    end
  end

  @doc """
  Equalised data carriers `c64[n][data_count]` from `carriers/4` output
  whose row 0 has class `first_class`.
  """
  def equalise(%__MODULE__{} = o, carriers, first_class) do
    t = tables(o)
    n = Nx.axis_size(carriers, 0)
    class = Nx.remainder(Nx.add(Nx.iota({n}), first_class), period(o))
    row = fn field -> Nx.take(t[field], class) end

    gains = Nx.divide(Nx.take_along_axis(carriers, row.(:pilots), axis: 1), row.(:values))
    left = Nx.take_along_axis(gains, row.(:left), axis: 1)
    right = Nx.take_along_axis(gains, Nx.add(row.(:left), 1), axis: 1)
    h = Nx.add(left, Nx.multiply(Nx.subtract(right, left), row.(:weight)))
    data = row.(:data)
    Nx.divide(Nx.take_along_axis(carriers, data, axis: 1), Nx.take_along_axis(h, data, axis: 1))
  end

  @doc """
  The same for rows grouped by class: `carriers` is `{groups, period, N}`
  with class p in column p (inside `defn` via `deftransform`); returns
  `{groups * period, data_count}`.
  """
  def equalise_grouped(carriers, t, period) do
    {groups, ^period, _} = Nx.shape(carriers)

    parts =
      for p <- 0..(period - 1) do
        c = carriers[[.., p, ..]]
        gains = Nx.divide(Nx.take(c, t.pilots[p], axis: 1), t.values[p])
        left = Nx.take(gains, t.left[p], axis: 1)
        right = Nx.take(gains, Nx.add(t.left[p], 1), axis: 1)
        h = Nx.add(left, Nx.multiply(Nx.subtract(right, left), t.weight[p]))
        Nx.divide(Nx.take(c, t.data[p], axis: 1), Nx.take(h, t.data[p], axis: 1))
      end

    data_count = Nx.axis_size(hd(parts), 1)
    parts |> Nx.stack(axis: 1) |> Nx.reshape({groups * period, data_count})
  end
end
