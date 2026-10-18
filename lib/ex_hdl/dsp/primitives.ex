defmodule ExHdl.DSP.Primitives do
  @moduledoc """
  Bit-exact fixed-point building blocks for `defn`.

  Each primitive is plain Nx, so it runs on any Nx backend as the reference
  implementation. Every place where values are allowed to wrap or clamp is an
  explicit primitive here; `ExHdl.Passes.WidthCheck` rejects any other
  overflow.
  """
  import Nx.Defn
  import Bitwise

  @doc """
  Reduces `x` modulo 2^bits into `type` (two's complement for signed types).
  `x` must be wider than `type`.
  """
  deftransform wrap(x, type) do
    {kind, bits} = type = Nx.Type.normalize!(type)
    mask = (1 <<< bits) - 1

    case kind do
      :u ->
        x |> Nx.bitwise_and(mask) |> Nx.as_type(type)

      :s ->
        half = 1 <<< (bits - 1)
        x |> Nx.add(half) |> Nx.bitwise_and(mask) |> Nx.subtract(half) |> Nx.as_type(type)
    end
  end

  @doc "`a + b` modulo 2^bits of `type`, e.g. a phase accumulator."
  deftransform add_wrap(a, b, type) do
    {_, bits} = Nx.Type.normalize!(type)
    wide = if bits <= 30, do: {:s, 32}, else: {:s, 64}
    Nx.add(Nx.as_type(a, wide), Nx.as_type(b, wide)) |> wrap(type)
  end

  @doc "Clamps `x` to the range of `type` and converts it."
  deftransform saturate(x, type) do
    type = Nx.Type.normalize!(type)
    {lo, hi} = ExHdl.Passes.WidthCheck.type_range(type)
    x |> Nx.clip(lo, hi) |> Nx.as_type(type)
  end

  @doc "Saturates to s16."
  deftransform saturate_s16(x), do: saturate(x, :s16)

  @doc """
  Complex Q15 x Q15 multiplication with s32 results (Q30), like a DSP48E1
  multiply without the final shift:
  `{a_i*b_i - a_q*b_q, a_i*b_q + a_q*b_i}`.

  Fits s32 only if one operand never reaches -32768 on both components
  (e.g. an NCO with amplitude 32767); `WidthCheck` verifies this.
  """
  deftransform complex_widening_mul_q15({a_i, a_q}, {b_i, b_q}) do
    [a_i, a_q, b_i, b_q] = Enum.map([a_i, a_q, b_i, b_q], &Nx.as_type(&1, :s32))

    {Nx.subtract(Nx.multiply(a_i, b_i), Nx.multiply(a_q, b_q)),
     Nx.add(Nx.multiply(a_i, b_q), Nx.multiply(a_q, b_i))}
  end

  @doc """
  Table-based NCO. `phase` is a u16 phase word (full circle = 65536); the top
  `:bits` bits (default 10) address a sine table of `:amplitude` (default
  32767, so +1.0 is representable). Returns `{cos, sin}`.

  The table is the same constant in every backend: Highway loads it, the
  FPGA backend maps it to block RAM.
  """
  deftransform lut_sincos_q15(phase, opts \\ []) do
    opts = Keyword.validate!(opts, bits: 10, amplitude: 32767)
    bits = opts[:bits]
    n = 1 <<< bits

    unless Nx.type(phase) == {:u, 16} and bits in 2..16,
      do: raise(ArgumentError, "lut_sincos_q15 expects a u16 phase and bits in 2..16")

    table = sine_table(n, opts[:amplitude])
    idx = Nx.right_shift(phase, 16 - bits)
    cos_idx = idx |> Nx.add(div(n, 4)) |> Nx.bitwise_and(n - 1)
    {Nx.take(table, cos_idx), Nx.take(table, idx)}
  end

  @doc "The NCO sine table as plain integers: `round(amplitude * sin(2*pi*k/n))`."
  def sine_values(n, amplitude) do
    for k <- 0..(n - 1), do: round(amplitude * :math.sin(2 * :math.pi() * k / n))
  end

  defp sine_table(n, amplitude) do
    values = sine_values(n, amplitude)
    type = if Enum.all?(values, &(&1 in -32768..32767)), do: :s16, else: :s32
    Nx.tensor(values, type: type, backend: Nx.BinaryBackend)
  end
end
