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

  The frame structure is an `ExHdl.Comm.OFDM` configuration (`ofdm/0`,
  pilot classes = scattered pilot phases); `modulate/2` adds the TPS
  carriers and `demodulate/3` is the generic float reference front end.
  """

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
    # output is the last stage; feedback = stage 11 xor stage 9
    lfsr = ExHdl.Comm.LFSR.new(length: 11, taps: [9, 11], seed: 0x7FF, output: :last)
    {bits, _} = ExHdl.Comm.LFSR.bits(lfsr, @active)
    List.to_tuple(bits)
  end

  @doc "Transmitted pilot value (real) at carrier k: 4/3 * 2 * (1/2 - w_k)."
  def pilot_value(prbs, k), do: 4 / 3 * 2 * (0.5 - elem(prbs, k))

  @doc "The generic OFDM configuration of the 2k mode."
  def ofdm do
    key = {__MODULE__, :ofdm}

    case :persistent_term.get(key, nil) do
      nil ->
        prbs = prbs()

        classes =
          for p <- 0..3 do
            %{
              pilots: Enum.map(pilots(p), &{&1, {pilot_value(prbs, &1), 0.0}}),
              data: data_carriers(p)
            }
          end

        o =
          ExHdl.Comm.OFDM.new(
            fft: @fft,
            cp: @cp,
            bins: ExHdl.Comm.OFDM.centered_bins(@fft, @offset - div(@fft, 2), @active),
            classes: classes,
            # gr-dtv scales the unnormalised IFFT by 1 / sqrt(27 * 1512)
            scale: @fft / :math.sqrt(27 * 1512)
          )

        :persistent_term.put(key, o)
        o

      o ->
        o
    end
  end

  @doc """
  Modulates OFDM symbols (float reference transmitter, as gr-dtv's
  `reference_signals` + cyclic prefixer): `symbols` is a list of
  `{data, l, frame}` with `data` the 1512 mapped data points `{re, im}` of
  symbol `l` (0..67) in frame `frame` (0..3). Continual and scattered
  pilots get amplitude 4/3, TPS carriers are DBPSK (amplitude 1) starting
  from the PRBS reference in symbol 0. Returns a complex tensor of
  `length(symbols) * 2112` samples.
  """
  def modulate(symbols, tps_opts) do
    prbs = prbs()
    tps_bits = Map.new(0..3, &{&1, ExHdl.DVBT.TPS.bits(&1, tps_opts) |> List.to_tuple()})

    # DBPSK state per TPS carrier, carried across frames
    {generic, _} =
      Enum.map_reduce(symbols, nil, fn {data, l, frame}, tps_state ->
        tps_state =
          if l == 0 or tps_state == nil,
            do: Map.new(@tps, &{&1, 2 * (0.5 - elem(prbs, &1))}),
            else:
              Map.new(tps_state, fn {k, v} ->
                {k, if(elem(tps_bits[frame], l) == 1, do: -v, else: v)}
              end)

        extra = for {k, v} <- tps_state, do: {k, {v, 0.0}}
        {{rem(l, 4), data, extra}, tps_state}
      end)

    ExHdl.Comm.OFDM.modulate(ofdm(), generic)
  end

  @doc """
  Demodulates OFDM symbols. `samples` is an `{n * 2112}` complex tensor of
  time-domain samples (cyclic prefix included) starting at a symbol
  boundary; `first_symbol` is the frame index of the first one. Returns a
  list of `{data, channel}` per symbol: `data` the 1512 equalised data
  carriers as `{re, im}` floats, ascending carrier order.
  """
  def demodulate(samples, first_symbol, _opts \\ []),
    do: ExHdl.Comm.OFDM.demodulate(ofdm(), samples, rem(first_symbol, 4))
end
