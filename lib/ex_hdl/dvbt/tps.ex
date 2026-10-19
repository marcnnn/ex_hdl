defmodule ExHdl.DVBT.TPS do
  @moduledoc """
  Transmission Parameter Signalling (ETSI EN 300 744, 4.6): 68 bits per
  frame, one per OFDM symbol, DBPSK-modulated on the TPS carriers.

  Bits: s0 initialisation, s1-s16 synchronisation word (inverted in
  frames 2 and 4), s17-s22 length indicator, s23-s24 frame number,
  s25-s26 constellation, s27-s29 hierarchy, s30-s32 HP code rate,
  s33-s35 LP code rate, s36-s37 guard interval, s38-s39 mode,
  s40-s47 cell id byte, s48-s53 reserved (0), s54-s67 BCH parity of
  the shortened BCH(127, 113) code.
  """
  import Bitwise

  @sync [0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 0]
  # g(x) = x^14 + x^9 + x^8 + x^6 + x^5 + x^4 + x^2 + x + 1
  @bch_poly [14, 9, 8, 6, 5, 4, 2, 1, 0] |> Enum.reduce(0, &(&2 ||| 1 <<< &1))

  @rates %{{1, 2} => 0, {2, 3} => 1, {3, 4} => 2, {5, 6} => 3, {7, 8} => 4}
  @constellations %{qpsk: 0, qam16: 1, qam64: 2}
  @guards %{{1, 32} => 0, {1, 16} => 1, {1, 8} => 2, {1, 4} => 3}

  @doc "The 68 TPS bits of frame `frame` (0..3 within the superframe)."
  def bits(frame, opts) do
    cell_id = Keyword.get(opts, :cell_id)
    sync = if rem(frame, 2) == 0, do: @sync, else: Enum.map(@sync, &(1 - &1))
    # length indicator: 23 parameter bits, 31 with cell id
    length = if cell_id, do: 31, else: 23

    cell_byte =
      if cell_id,
        do: if(rem(frame, 2) == 0, do: cell_id >>> 8 &&& 0xFF, else: cell_id &&& 0xFF),
        else: 0

    info =
      sync ++
        int_bits(length, 6) ++
        int_bits(frame, 2) ++
        int_bits(@constellations[Keyword.fetch!(opts, :constellation)], 2) ++
        int_bits(0, 3) ++
        int_bits(@rates[Keyword.fetch!(opts, :code_rate)], 3) ++
        int_bits(@rates[Keyword.get(opts, :lp_code_rate, Keyword.fetch!(opts, :code_rate))], 3) ++
        int_bits(@guards[Keyword.fetch!(opts, :guard_interval)], 2) ++
        int_bits(if(Keyword.get(opts, :mode, :"2k") == :"2k", do: 0, else: 1), 2) ++
        int_bits(cell_byte, 8) ++ List.duplicate(0, 6)

    # BCH over s1..s53 (53 bits), shortened from 113 information bits
    [0 | info] ++ bch_parity(info)
  end

  defp int_bits(v, n), do: for(k <- (n - 1)..0//-1, do: v >>> k &&& 1)

  # Systematic BCH: remainder of info(x) * x^14 / g(x), MSB first.
  defp bch_parity(info) do
    reg =
      Enum.reduce(info ++ List.duplicate(0, 14), 0, fn b, reg ->
        reg = reg <<< 1 ||| b
        if (reg >>> 14 &&& 1) == 1, do: bxor(reg, @bch_poly), else: reg
      end)

    int_bits(reg, 14)
  end
end
