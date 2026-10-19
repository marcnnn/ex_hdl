defmodule ExHdl.Comm.Bits do
  @moduledoc "Bit packing helpers (binaries of 0/1 bytes <-> bytes)."
  import Bitwise

  @doc "Packs 0/1 bytes into bytes, MSB first (a trailing partial byte is dropped)."
  def pack(bits) do
    for <<b0, b1, b2, b3, b4, b5, b6, b7 <- binary_part(bits, 0, div(byte_size(bits), 8) * 8)>>,
      into: <<>>,
      do:
        <<b0 <<< 7 ||| b1 <<< 6 ||| b2 <<< 5 ||| b3 <<< 4 ||| b4 <<< 3 ||| b5 <<< 2 ||| b6 <<< 1 |||
            b7>>
  end

  @doc "Unpacks bytes into 0/1 bytes, MSB first."
  def unpack(bytes), do: for(<<b::1 <- bytes>>, into: <<>>, do: <<b>>)
end
