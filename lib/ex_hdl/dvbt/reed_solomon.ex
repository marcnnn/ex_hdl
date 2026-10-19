defmodule ExHdl.DVBT.ReedSolomon do
  @moduledoc """
  DVB outer code RS(204, 188, t = 8) (ETSI EN 300 744, 4.3.2): the generic
  `ExHdl.Comm.ReedSolomon` configured as RS(255, 239) over GF(256) with
  field polynomial `x^8 + x^4 + x^3 + x^2 + 1`, first root `alpha^0`,
  shortened by 51.
  """
  alias ExHdl.Comm.ReedSolomon, as: RS

  @doc "The DVB code."
  def code, do: RS.new(m: 8, field_poly: 0x11D, n: 255, k: 239, fcr: 0, prim: 1, shortening: 51)

  def generator, do: code().generator

  @doc "188-byte packet -> 204-byte codeword."
  def encode(<<packet::binary-size(188)>>), do: RS.encode_bytes(code(), packet)

  @doc "204-byte codeword -> `{:ok, packet, corrected}` or `{:error, :uncorrectable, packet}`."
  def decode(<<codeword::binary-size(204)>>), do: RS.decode_bytes(code(), codeword)

  @doc "Whole binary of codewords -> `{packets, corrected, failed}` (native when available)."
  def decode_all(codewords), do: RS.decode_all_bytes(code(), codewords)
end
