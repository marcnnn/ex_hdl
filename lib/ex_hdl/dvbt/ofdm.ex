defmodule ExHdl.DVBT.OFDM do
  @moduledoc """
  DVB-T OFDM frame structure and demodulation (ETSI EN 300 744, 4.4-4.5),
  2k mode.

  Carriers k = 0..1704 occupy FFT bins `172 + k` of a 2048-point FFT with
  DC in the middle (bin 1024 = carrier 852). Each OFDM symbol carries
  continual pilots (fixed positions), scattered pilots (`k = 3 * (l mod 4)
  + 12 p` for symbol l of the frame) and TPS carriers; the remaining 1512
  carriers carry data. Pilots are BPSK with amplitude 4/3 and sign from
  the PRBS `x^11 + x^2 + 1` (all ones at carrier 0).

  `demodulate/3` is the float reference front end: FFT, channel estimate
  at the pilots, linear interpolation across frequency, equalisation.
  """
  import Bitwise

  @fft 2048
  @cp 64
  @active 1705
  @offset 172

  @continual [
    0,
    48,
    54,
    87,
    141,
    156,
    192,
    201,
    255,
    279,
    282,
    333,
    432,
    450,
    483,
    525,
    531,
    618,
    636,
    714,
    759,
    765,
    780,
    804,
    873,
    888,
    918,
    939,
    942,
    969,
    984,
    1050,
    1101,
    1107,
    1110,
    1137,
    1140,
    1146,
    1206,
    1269,
    1323,
    1377,
    1491,
    1683,
    1704
  ]

  @tps [34, 50, 209, 346, 413, 569, 595, 688, 790, 901, 1073, 1219, 1262, 1286, 1469, 1594, 1687]

  def fft_size, do: @fft
  def cyclic_prefix, do: @cp
  def active_carriers, do: @active
  def continual_pilots, do: @continual
  def tps_carriers, do: @tps

  @doc "Scattered pilot carriers of symbol `l` (within the frame)."
  def scattered_pilots(l), do: Enum.to_list((3 * rem(l, 4))..(@active - 1)//12)

  @doc "All pilot carriers (continual + scattered) of symbol `l`, sorted."
  def pilots(l), do: Enum.uniq(Enum.sort(@continual ++ scattered_pilots(l)))

  @doc "The 1512 data carriers of symbol `l`, ascending."
  def data_carriers(l) do
    taken = MapSet.new(@continual ++ scattered_pilots(l) ++ @tps)
    for k <- 0..(@active - 1), not MapSet.member?(taken, k), do: k
  end

  @doc "PRBS w_k for k = 0..1704 (x^11 + x^2 + 1, register all ones), as a tuple."
  def prbs do
    {bits, _} =
      Enum.map_reduce(0..(@active - 1), 0x7FF, fn _, reg ->
        # output is the last stage; feedback = stage 11 xor stage 9
        out = reg &&& 1
        feedback = bxor(reg &&& 1, reg >>> 2 &&& 1)
        {out, reg >>> 1 ||| feedback <<< 10}
      end)

    List.to_tuple(bits)
  end

  @doc "Transmitted pilot value (real) at carrier k: 4/3 * 2 * (1/2 - w_k)."
  def pilot_value(prbs, k), do: 4 / 3 * 2 * (0.5 - elem(prbs, k))

  @doc """
  Modulates OFDM symbols (float reference transmitter, as gr-dtv's
  `reference_signals` + cyclic prefixer): `symbols` is a list of
  `{data, l, frame}` with `data` the 1512 mapped data points `{re, im}` of
  symbol `l` (0..67) in frame `frame` (0..3). Continual and scattered
  pilots get amplitude 4/3, TPS carriers are DBPSK (amplitude 1) starting
  from the PRBS reference in symbol 0. The unnormalised IFFT output is
  scaled by `1 / sqrt(27 * 1512)` as in gr-dtv. Returns a complex tensor
  of `length(symbols) * 2112` samples.
  """
  def modulate(symbols, tps_opts) do
    prbs = prbs()

    tps_bits = Map.new(0..3, &{&1, ExHdl.DVBT.TPS.bits(&1, tps_opts) |> List.to_tuple()})

    # DBPSK state per TPS carrier, carried across frames
    {spectra, _} =
      Enum.map_reduce(symbols, nil, fn {data, l, frame}, tps_state ->
        tps_state =
          if l == 0 or tps_state == nil,
            do: Map.new(@tps, &{&1, 2 * (0.5 - elem(prbs, &1))}),
            else:
              Map.new(tps_state, fn {k, v} ->
                {k, if(elem(tps_bits[frame], l) == 1, do: -v, else: v)}
              end)

        carriers =
          Map.new(Enum.zip(data_carriers(l), data))
          |> Map.merge(Map.new(pilots(l), &{&1, {pilot_value(prbs, &1), 0.0}}))
          |> Map.merge(Map.new(tps_state, fn {k, v} -> {k, {v, 0.0}} end))

        bins =
          for b <- 0..(@fft - 1) do
            k = Integer.mod(b - @offset + div(@fft, 2), @fft)
            {re, im} = Map.get(carriers, k, {0.0, 0.0})
            if k < @active, do: Complex.new(re, im), else: Complex.new(0.0, 0.0)
          end

        {bins, tps_state}
      end)

    n = length(symbols)
    scale = @fft / :math.sqrt(27 * 1512)

    spectra
    |> Nx.tensor(type: :c64)
    |> Nx.ifft()
    |> Nx.multiply(scale)
    |> then(fn t ->
      Nx.concatenate([Nx.slice_along_axis(t, @fft - @cp, @cp, axis: 1), t], axis: 1)
    end)
    |> Nx.reshape({n * (@fft + @cp)})
  end

  @doc """
  Demodulates OFDM symbols. `samples` is an `{n * 2112}` complex tensor of
  time-domain samples (cyclic prefix included) starting at a symbol
  boundary; `first_symbol` is the frame index of the first one. Returns a
  list of `{data, channel}` per symbol: `data` the 1512 equalised data
  carriers as `{re, im}` floats, ascending carrier order.
  """
  def demodulate(samples, first_symbol, opts \\ []) do
    prbs = Keyword.get_lazy(opts, :prbs, &prbs/0)
    n = div(Nx.size(samples), @fft + @cp)

    symbols =
      samples
      |> Nx.reshape({n, @fft + @cp})
      |> Nx.slice_along_axis(@cp, @fft, axis: 1)
      |> Nx.fft()
      # FFT bin b holds carrier k with b = (k - 852) mod 2048
      |> Nx.to_list()

    symbols
    |> Enum.with_index(first_symbol)
    |> Enum.map(fn {bins, l} ->
      bins = List.to_tuple(bins)

      carrier = fn k ->
        bins |> elem(Integer.mod(k + @offset - div(@fft, 2), @fft)) |> to_pair()
      end

      equalise(carrier, rem(l, 68), prbs)
    end)
  end

  defp to_pair(%Complex{re: re, im: im}), do: {re, im}
  defp to_pair(x) when is_number(x), do: {x * 1.0, 0.0}

  # Channel estimate at the pilots, linear interpolation in between,
  # data carriers divided by the estimate.
  defp equalise(carrier, l, prbs) do
    pilot_gains =
      for k <- pilots(l) do
        {re, im} = carrier.(k)
        p = pilot_value(prbs, k)
        {k, {re / p, im / p}}
      end

    channel = interpolate(pilot_gains)

    data =
      for k <- data_carriers(l) do
        {hr, hi} = Map.fetch!(channel, k)
        {re, im} = carrier.(k)
        d = hr * hr + hi * hi
        {(re * hr + im * hi) / d, (im * hr - re * hi) / d}
      end

    {data, channel}
  end

  defp interpolate(pilot_gains) do
    pilot_gains
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{k0, {r0, i0}}, {k1, {r1, i1}}] ->
      for k <- k0..(k1 - 1) do
        t = (k - k0) / (k1 - k0)
        {k, {r0 + (r1 - r0) * t, i0 + (i1 - i0) * t}}
      end
    end)
    |> Map.new()
    |> Map.put(elem(List.last(pilot_gains), 0), elem(List.last(pilot_gains), 1))
  end
end
