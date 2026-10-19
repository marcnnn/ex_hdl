defmodule ExHdl.DVBT.Receiver do
  @moduledoc """
  DVB-T receiver back end (bit level): from hard-decision carrier words to
  the MPEG transport stream. Non-hierarchical; reference implementation in
  exact integer arithmetic.

  The input starts at a superframe boundary (OFDM symbol 0 of frame 0), as
  delivered by a synchronised front end. The inner encoder runs
  continuously at the transmitter, so Viterbi decoding starts with an
  unknown state; the outer deinterleaver needs 2244 bytes (11 packets) to
  fill, and the descrambler aligns on the inverted sync byte 0xB8 that
  starts every group of 8 packets.
  """
  alias ExHdl.DVBT.{Convolutional, EnergyDispersal, Inner, OuterInterleaver, ReedSolomon}

  @symbols_per_frame 68

  @doc """
  Full receiver from baseband samples that start at a superframe boundary
  (known symbol timing; no acquisition yet): float OFDM front end with
  hard decisions, then `decode/2`.
  """
  def receive(samples, opts) do
    constellation = Keyword.fetch!(opts, :constellation)
    n = div(Nx.size(samples), 2112)
    prbs = ExHdl.DVBT.OFDM.prbs()

    words =
      0..(n - 1)//68
      |> Enum.flat_map(fn start ->
        count = min(68, n - start)
        chunk = Nx.slice(samples, [start * 2112], [count * 2112])

        chunk
        |> ExHdl.DVBT.OFDM.demodulate(0, prbs: prbs)
        |> Enum.flat_map(fn {data, _channel} ->
          Enum.map(data, &Inner.demap_symbol(&1, constellation))
        end)
      end)

    decode(words, opts)
  end

  @doc """
  Decodes `words` (a list of carrier words, `data_carriers` per OFDM
  symbol). Options: `:constellation`, `:code_rate`, `:mode`. Returns
  `%{ts: binary, rs_corrected: n, rs_failed: n, stages: %{...}}`.
  """
  def decode(words, opts) do
    constellation = Keyword.fetch!(opts, :constellation)
    rate = Keyword.fetch!(opts, :code_rate)
    mode = Keyword.get(opts, :mode, :"2k")
    h = Inner.symbol_permutation(mode)
    carriers = tuple_size(h)

    symbol_deint =
      words
      |> Enum.chunk_every(carriers, carriers, :discard)
      |> Enum.with_index()
      |> Enum.flat_map(fn {sym, k} ->
        Inner.symbol_deinterleave(sym, h, rem(k, @symbols_per_frame))
      end)

    bit_deint = Inner.bit_deinterleave(symbol_deint, constellation)
    v = Inner.bits_per_symbol(constellation)

    coded =
      Enum.flat_map(bit_deint, fn w ->
        for k <- (v - 1)..0//-1, do: Bitwise.band(Bitwise.bsr(w, k), 1)
      end)

    decoded = Convolutional.decode(coded, rate, start: :unknown)

    bytes =
      decoded
      |> Enum.chunk_every(8, 8, :discard)
      |> Enum.map(fn b -> Enum.reduce(b, 0, &(&2 * 2 + &1)) end)
      |> :binary.list_to_bin()

    bytes
    |> outer()
    |> Map.update!(
      :stages,
      &Map.merge(&1, %{
        symbol_deinterleaver: symbol_deint,
        bit_deinterleaver: bit_deint,
        viterbi: bytes
      })
    )
  end

  @doc """
  Fast receiver (`ExHdl.DVBT.Fast`): tensors on EXLA when available and the
  native Viterbi kernel. `samples` start at a superframe boundary unless
  `:start` (sample index) and `:freq_offset` (subcarrier spacings) are
  given, e.g. by `ExHdl.DVBT.Sync.acquire/2`. Same decisions and output as
  `receive/2`.
  """
  def receive_fast(samples, opts) do
    constellation = Keyword.fetch!(opts, :constellation)
    rate = Keyword.fetch!(opts, :code_rate)
    start = Keyword.get(opts, :start, 0)
    backend = if Code.ensure_loaded?(EXLA.Backend), do: EXLA.Backend, else: Nx.BinaryBackend

    bits =
      Nx.with_default_backend(backend, fn ->
        x =
          samples
          |> Nx.backend_transfer(backend)
          |> then(&Nx.slice(&1, [start], [Nx.size(&1) - start]))

        n = div(Nx.size(x), 2112)

        x
        |> ExHdl.DVBT.Fast.carriers(n, Keyword.get(opts, :freq_offset, 0.0))
        |> ExHdl.DVBT.Fast.equalise(0)
        |> ExHdl.DVBT.Fast.demap(constellation)
        |> ExHdl.DVBT.Fast.symbol_deinterleave(0)
        |> ExHdl.DVBT.Fast.bit_deinterleave(constellation)
        |> ExHdl.DVBT.Fast.unpack(constellation)
      end)

    bits
    |> Convolutional.decode_binary(rate, start: :unknown)
    |> ExHdl.DVBT.Fast.pack()
    |> outer()
  end

  @doc """
  Complete receiver: acquisition (`ExHdl.DVBT.Sync.acquire/2`: timing,
  frequency offset, superframe start) followed by `receive_fast/2`.
  Returns the `receive_fast/2` result with the acquisition under `:sync`,
  or `{:error, reason}`.
  """
  def receive_sync(samples, opts) do
    with {:ok, sync} <- ExHdl.DVBT.Sync.acquire(samples, opts) do
      samples
      |> receive_fast(Keyword.merge(opts, start: sync.start, freq_offset: sync.freq_offset))
      |> Map.put(:sync, sync)
    end
  end

  # Forney deinterleaver, RS decoding and descrambling of decoded bytes.
  defp outer(bytes) do
    deinterleaved = OuterInterleaver.deinterleave(bytes)
    # the first 11 packets are FIFO fill
    payload =
      binary_part(
        deinterleaved,
        OuterInterleaver.delay(),
        byte_size(deinterleaved) - OuterInterleaver.delay()
      )

    {packets, corrected, failed} =
      for <<cw::binary-size(204) <- payload>>, reduce: {[], 0, 0} do
        {acc, c, f} ->
          case ReedSolomon.decode(cw) do
            {:ok, p, n} -> {[p | acc], c + n, f}
            {:error, :uncorrectable, p} -> {[p | acc], c, f + 1}
          end
      end

    rs_out = packets |> Enum.reverse() |> IO.iodata_to_binary()

    # align on the first inverted sync byte, then whole groups of 8
    start =
      Enum.find(0..(div(byte_size(rs_out), 188) - 1)//1, &(:binary.at(rs_out, &1 * 188) == 0xB8))

    aligned =
      if start, do: binary_part(rs_out, start * 188, byte_size(rs_out) - start * 188), else: <<>>

    groups = div(byte_size(aligned), 1504) * 1504
    ts = EnergyDispersal.descramble(binary_part(aligned, 0, groups))

    %{
      ts: ts,
      rs_corrected: corrected,
      rs_failed: failed,
      stages: %{outer_deinterleaver: deinterleaved, reed_solomon: rs_out}
    }
  end
end
