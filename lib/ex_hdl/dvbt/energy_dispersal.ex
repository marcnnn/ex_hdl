defmodule ExHdl.DVBT.EnergyDispersal do
  @moduledoc """
  Transport multiplex adaptation and randomisation (ETSI EN 300 744, 4.3.1).

  The PRBS `1 + x^14 + x^15` (`ExHdl.Comm.LFSR`, taps `[14, 15]`) is
  loaded with `100101010000000` at the start of every group of 8 transport
  packets, whose first sync byte is inverted (`0x47` -> `0xB8`). The PRBS
  output is XORed with all bytes except the sync bytes; during the 7 other
  sync bytes the generator keeps running but its output is not applied.
  One group is one period of an `ExHdl.Comm.Scrambler`.
  """
  alias ExHdl.Comm.{LFSR, Scrambler}

  @doc "Scrambles whole groups of 8 packets (188 bytes each)."
  def scramble(ts), do: Scrambler.apply(scrambler(0xB8), ts)

  @doc "Descrambles groups of 8 packets and restores the 0x47 sync bytes."
  def descramble(ts), do: Scrambler.apply(scrambler(0x47), ts)

  defp scrambler(first_sync) do
    key = {__MODULE__, first_sync}

    case :persistent_term.get(key, nil) do
      nil ->
        s = build(first_sync)
        :persistent_term.put(key, s)
        s

      s ->
        s
    end
  end

  defp build(first_sync) do
    # 8 * 188 - 1 generator bytes: the first sync byte is not clocked
    {prbs, _} =
      LFSR.bytes(LFSR.new(length: 15, taps: [14, 15], seed: 0b100101010000000), 8 * 188 - 1)

    {keep, mask} =
      for p <- 0..7, reduce: {[], []} do
        {k, m} ->
          payload = binary_part(prbs, 188 * p, 187)
          sync = if p == 0, do: first_sync, else: 0x47
          {[k, 0x00, :binary.copy(<<0xFF>>, 187)], [m, sync, payload]}
      end

    Scrambler.new(IO.iodata_to_binary(keep), IO.iodata_to_binary(mask))
  end
end
