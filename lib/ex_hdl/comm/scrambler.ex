defmodule ExHdl.Comm.Scrambler do
  @moduledoc """
  Additive byte scramblers that restart every `period` bytes (DVB energy
  dispersal, ATSC data randomiser, ...): a protocol describes one period as
  two byte masks and the whole stream is `out = (in AND keep) XOR mask`,
  repeated. `keep = 0xFF, mask = keystream` scrambles a byte; `keep = 0x00,
  mask = value` writes a constant (sync bytes); `keep = 0xFF, mask = 0`
  passes through.
  """
  import Bitwise

  defstruct [:keep, :mask]

  @doc "From the two masks of one period (equal size binaries)."
  def new(keep, mask) when byte_size(keep) == byte_size(mask),
    do: %__MODULE__{keep: keep, mask: mask}

  def period(%__MODULE__{mask: m}), do: byte_size(m)

  @doc """
  Applies the map to whole periods. Option `:native` (default: when the
  NIF is loaded) selects the native kernel or the Elixir reference.
  """
  def apply(%__MODULE__{keep: keep, mask: mask}, data, opts \\ [])
      when rem(byte_size(data), byte_size(mask)) == 0 do
    if Keyword.get_lazy(opts, :native, &ExHdl.SIMD.available?/0) do
      ExHdl.SIMD.NIF.byte_affine(data, keep, mask)
    else
      p = byte_size(mask)
      for <<chunk::binary-size(p) <- data>>, into: <<>>, do: affine(chunk, keep, mask)
    end
  end

  defp affine(chunk, keep, mask) do
    for {{x, k}, m} <-
          Enum.zip(
            Enum.zip(:binary.bin_to_list(chunk), :binary.bin_to_list(keep)),
            :binary.bin_to_list(mask)
          ),
        into: <<>>,
        do: <<bxor(x &&& k, m)>>
  end
end
