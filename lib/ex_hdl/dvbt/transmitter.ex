defmodule ExHdl.DVBT.Transmitter do
  @moduledoc """
  Complete DVB-T transmitter (2k, non-hierarchical): transport stream to
  complex baseband samples. Bit-exact with gr-dtv up to the constellation
  points; the OFDM modulation (`ExHdl.DVBT.OFDM.modulate/2`) matches its
  samples to float32 precision.
  """
  alias ExHdl.DVBT.{Convolutional, EnergyDispersal, Inner, OFDM, OuterInterleaver, ReedSolomon}

  @symbols_per_frame 68

  @doc """
  Mapped data carriers for every OFDM symbol: a list of `{points, l, frame}`.
  The stream starts at superframe 0, frame 0, symbol 0. `ts` must hold a
  whole number of groups of 8 packets.
  """
  def symbols(ts, opts) do
    constellation = Keyword.fetch!(opts, :constellation)
    rate = Keyword.fetch!(opts, :code_rate)
    h = Inner.symbol_permutation(:"2k")

    ts
    |> EnergyDispersal.scramble()
    |> then(&for(<<p::binary-size(188) <- &1>>, into: <<>>, do: ReedSolomon.encode(p)))
    |> OuterInterleaver.interleave()
    |> then(&for(<<b::1 <- &1>>, do: b))
    |> Convolutional.encode(rate)
    |> Inner.group_bits(constellation)
    |> Inner.bit_interleave(constellation)
    |> Enum.chunk_every(tuple_size(h), tuple_size(h), :discard)
    |> Enum.with_index()
    |> Enum.map(fn {words, j} ->
      l = rem(j, @symbols_per_frame)

      points =
        words |> Inner.symbol_interleave(h, l) |> Enum.map(&Inner.map_symbol(&1, constellation))

      {points, l, rem(div(j, @symbols_per_frame), 4)}
    end)
  end

  @doc "Baseband samples (complex tensor) for `ts`; modulated frame by frame."
  def transmit(ts, opts) do
    tps = Keyword.take(opts, [:constellation, :code_rate, :guard_interval, :cell_id])

    ts
    |> symbols(opts)
    |> Enum.chunk_every(@symbols_per_frame)
    |> Enum.map(&OFDM.modulate(&1, tps))
    |> Nx.concatenate()
  end
end

defmodule ExHdl.DVBT.Channel do
  @moduledoc "Channel models for DVB-T tests."

  @doc """
  Adds complex white Gaussian noise for a per-sample SNR in dB (signal
  power measured over the whole input). The carrier-to-noise ratio in the
  occupied 1705 of 2048 bins is `snr_db + 10*log10(2048/1705)`.
  """
  def awgn(samples, snr_db, seed) do
    power = samples |> Nx.abs() |> Nx.pow(2) |> Nx.mean() |> Nx.to_number()
    sigma = :math.sqrt(power / :math.pow(10, snr_db / 10) / 2)
    key = Nx.Random.key(seed)
    {re, key} = Nx.Random.normal(key, 0.0, sigma, shape: Nx.shape(samples), type: :f32)
    {im, _} = Nx.Random.normal(key, 0.0, sigma, shape: Nx.shape(samples), type: :f32)
    Nx.add(samples, Nx.complex(re, im))
  end

  @doc "Carrier frequency offset of `subcarriers` subcarrier spacings (2k: 4464 Hz each)."
  def frequency_offset(samples, subcarriers) do
    n = Nx.size(samples)

    Nx.multiply(
      samples,
      Nx.exp(
        Nx.multiply(
          Nx.complex(0.0, 2 * :math.pi() * subcarriers / 2048),
          Nx.iota({n}, type: :f32)
        )
      )
    )
  end

  @doc "Prepends `n` samples of low-level noise: the receiver does not know where the signal starts."
  def delay(samples, 0, _seed), do: samples

  def delay(samples, n, seed) do
    {noise, _} = Nx.Random.normal(Nx.Random.key(seed), 0.0, 0.05, shape: {n, 2}, type: :f32)
    Nx.concatenate([Nx.complex(noise[[.., 0]], noise[[.., 1]]), samples])
  end
end
