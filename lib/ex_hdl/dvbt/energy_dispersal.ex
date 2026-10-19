defmodule ExHdl.DVBT.EnergyDispersal do
  @moduledoc """
  Transport multiplex adaptation and randomisation (ETSI EN 300 744, 4.3.1).

  The PRBS `1 + x^14 + x^15` is loaded with `100101010000000` at the start
  of every group of 8 transport packets, whose first sync byte is inverted
  (`0x47` -> `0xB8`). The PRBS output is XORed with all bytes except the
  sync bytes; during the 7 other sync bytes the generator keeps running but
  its output is not applied. Scrambling and descrambling are the same
  operation apart from the sync byte.
  """
  import Bitwise

  @init 0b100101010000000

  @doc "Scrambles whole groups of 8 packets (188 bytes each)."
  def scramble(ts), do: process(ts, :scramble)

  @doc "Descrambles groups of 8 packets and restores the 0x47 sync bytes."
  def descramble(ts), do: process(ts, :descramble)

  defp process(ts, mode) when rem(byte_size(ts), 188 * 8) == 0 do
    for <<group::binary-size(1504) <- ts>>, into: <<>>, do: group(group, mode)
  end

  defp group(group, mode) do
    packets = for <<p::binary-size(188) <- group>>, do: p

    {out, _reg} =
      packets
      |> Enum.with_index()
      |> Enum.map_reduce(@init, fn {<<_sync, payload::binary-size(187)>>, i}, reg ->
        sync =
          case {i, mode} do
            {0, :scramble} -> 0xB8
            {0, :descramble} -> 0x47
            _ -> 0x47
          end

        # the generator runs through the sync bytes of packets 2..8
        reg = if i == 0, do: reg, else: elem(prbs_byte(reg), 1)
        {payload, reg} = xor_prbs(payload, reg)
        {<<sync, payload::binary>>, reg}
      end)

    IO.iodata_to_binary(out)
  end

  defp xor_prbs(bytes, reg) do
    {out, reg} =
      for <<b <- bytes>>, reduce: {[], reg} do
        {acc, reg} ->
          {mask, reg} = prbs_byte(reg)
          {[bxor(b, mask) | acc], reg}
      end

    {acc_to_binary(out), reg}
  end

  defp acc_to_binary(rev), do: rev |> Enum.reverse() |> :binary.list_to_bin()

  # 8 PRBS bits, first bit as MSB. reg bit 14 is stage 1, bit 0 stage 15.
  defp prbs_byte(reg) do
    Enum.reduce(1..8, {0, reg}, fn _, {byte, reg} ->
      out = bxor(reg >>> 1 &&& 1, reg &&& 1)
      {byte <<< 1 ||| out, reg >>> 1 ||| out <<< 14}
    end)
  end
end
