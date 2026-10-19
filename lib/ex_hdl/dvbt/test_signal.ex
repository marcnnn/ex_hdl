defmodule ExHdl.DVBT.TestSignal do
  @moduledoc """
  Deterministic MPEG transport stream used for DVB-T comparisons; the same
  formula is in test/gnuradio/dvbt_golden.py.
  """

  @doc "`n` packets of 188 bytes: sync, PID 0x100..0x102, continuity counter, formula payload."
  def ts_packets(n) do
    for i <- 0..(n - 1)//1, into: <<>> do
      pid = 0x100 + rem(i, 3)

      header =
        <<0x47, Bitwise.band(pid >>> 8, 0x1F), Bitwise.band(pid, 0xFF),
          Bitwise.bor(0x10, Bitwise.band(i, 0x0F))>>

      payload =
        for j <- 0..183, into: <<>>, do: <<Bitwise.band(i * 7 + j * 13 + rem(j * j, 251), 0xFF)>>

      header <> payload
    end
  end

  defp a >>> b, do: Bitwise.bsr(a, b)
end
