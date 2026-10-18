defmodule ExHdl.Num do
  @moduledoc """
  Number-format-generic arithmetic, so a DSP algorithm is written once and
  instantiated as float (the reference) or as fixed point (CPU/FPGA).

  ## Formats

    * `float/0` - real values are `f32` tensors.
    * `q/3`, e.g. `q(16, 15, rounding: :nearest, lut_bits: 10)` - real values
      are `ExHdl.Num.Fixed` structs: an integer tensor plus its binary point.

  Complex values are `{re, im}` tuples of real values in either format.

  ## How fixed point is handled

  Arithmetic is exact: `mul/2` adds the binary points, `add/2` aligns them,
  and the integer container grows to whatever the operand *types* need
  (`s32`, else `s64`), so no intermediate overflows on the CPU. Precision is
  only lost where the algorithm says so: `rescale/2` moves the binary point
  (rounding per format) and `quantize/2` additionally saturates to the
  format's width. The FPGA does not use the containers; it sizes every
  signal from `ExHdl.Passes.WidthCheck`.

  Phase words (NCO phase accumulators) are plain unsigned integers in both
  instances: the recurrence is identical, only sin/cos differ.
  """
  import Nx.Defn
  import Bitwise

  alias ExHdl.DSP.Primitives, as: P
  alias ExHdl.Num.Fixed

  defmodule Format do
    @moduledoc "A number format, see `ExHdl.Num`."
    defstruct kind: :float, bits: nil, frac: nil, rounding: :nearest, lut_bits: 10

    @type t :: %__MODULE__{
            kind: :float | :fixed,
            bits: pos_integer() | nil,
            frac: non_neg_integer() | nil,
            rounding: :nearest | :truncate,
            lut_bits: pos_integer()
          }
  end

  # -- formats --------------------------------------------------------------------

  @doc "Float instance (`f32`)."
  def float(opts \\ []), do: struct!(Format, [kind: :float] ++ opts)

  @doc """
  Fixed-point instance with `bits` total (signed) and `frac` fractional bits.
  Options: `rounding: :nearest | :truncate` (default `:nearest`),
  `lut_bits:` sine table address bits (default 10).
  """
  def q(bits, frac, opts \\ []) when bits in 2..32 and frac >= 0 and frac < bits,
    do: struct!(Format, [kind: :fixed, bits: bits, frac: frac] ++ opts)

  # -- host side: building inputs and reading results --------------------------------

  @doc "A real constant or parameter in `format` (rounded, saturated for fixed point)."
  def constant(value, %Format{kind: :float}), do: Nx.tensor(value, type: :f32)

  def constant(value, %Format{kind: :fixed} = f) do
    {lo, hi} = range(f.bits)
    raw = (value * (1 <<< f.frac)) |> round() |> max(lo) |> min(hi)
    %Fixed{t: Nx.tensor(raw, type: container(f.bits)), frac: f.frac}
  end

  @doc """
  Imports integer samples with binary point `frac` (e.g. Q15 ADC data) into
  `format`. Exact for float (powers of two), shifted for fixed point.
  """
  def from_int(tensor, frac, %Format{kind: :float}),
    do: Nx.divide(Nx.as_type(tensor, :f32), 1 <<< frac)

  def from_int(tensor, frac, %Format{kind: :fixed} = f) do
    t = Nx.as_type(tensor, container(f.bits))

    cond do
      frac == f.frac -> %Fixed{t: t, frac: frac}
      frac < f.frac -> %Fixed{t: Nx.left_shift(t, f.frac - frac), frac: f.frac}
      true -> %Fixed{t: Nx.right_shift(t, frac - f.frac), frac: f.frac}
    end
  end

  @doc "Zeros of `shape` in `format` (e.g. an empty delay line)."
  def zeros(shape, %Format{kind: :float}), do: Nx.broadcast(Nx.tensor(0.0, type: :f32), shape)

  def zeros(shape, %Format{kind: :fixed} = f),
    do: %Fixed{t: Nx.broadcast(Nx.tensor(0, type: container(f.bits)), shape), frac: f.frac}

  @doc "Real value(s) as Elixir floats (a number or a list for vectors); complex as tuples."
  def to_float({re, im}), do: {to_float(re), to_float(im)}
  def to_float(%Fixed{t: t, frac: frac}), do: scale_out(numbers(t), 1 <<< frac)
  def to_float(%Nx.Tensor{} = t), do: scale_out(numbers(t), 1)

  defp numbers(%Nx.Tensor{shape: {}} = t), do: Nx.to_number(t)
  defp numbers(t), do: Nx.to_list(t)

  defp scale_out(list, d) when is_list(list), do: Enum.map(list, &(&1 / d))
  defp scale_out(n, d), do: n / d

  # -- arithmetic (inside defn) -----------------------------------------------------------

  @doc "Exact product. Fixed point: binary points add."
  deftransform mul(%Fixed{} = a, %Fixed{} = b) do
    c = container(bits_of(a) + bits_of(b) - 1)
    %Fixed{t: Nx.multiply(Nx.as_type(a.t, c), Nx.as_type(b.t, c)), frac: a.frac + b.frac}
  end

  deftransform mul(a, b), do: Nx.multiply(a, b)

  @doc "Exact sum. Fixed point: the operand with fewer fractional bits is shifted up."
  deftransform add(a, b), do: combine(a, b, &Nx.add/2)

  @doc "Exact difference."
  deftransform sub(a, b), do: combine(a, b, &Nx.subtract/2)

  defp combine(%Fixed{} = a, %Fixed{} = b, op) do
    frac = max(a.frac, b.frac)
    bits = max(bits_of(a) + frac - a.frac, bits_of(b) + frac - b.frac) + 1
    c = container(bits)
    op.(align(a, frac, c), align(b, frac, c)) |> then(&%Fixed{t: &1, frac: frac})
  end

  defp combine(a, b, op), do: op.(a, b)

  defp align(%Fixed{t: t, frac: f}, frac, c), do: t |> Nx.as_type(c) |> Nx.left_shift(frac - f)

  @doc "Complex product `{ar*br - ai*bi, ar*bi + ai*br}`."
  deftransform cmul({ar, ai}, {br, bi}),
    do: {sub(mul(ar, br), mul(ai, bi)), add(mul(ar, bi), mul(ai, br))}

  @doc "Complex times real."
  deftransform cscale({re, im}, g), do: {mul(re, g), mul(im, g)}

  @doc """
  Moves the binary point to the format's `frac` (rounding per format),
  keeping the container. Identity for float.
  """
  deftransform rescale({re, im}, format), do: {rescale(re, format), rescale(im, format)}

  deftransform rescale(%Fixed{} = x, %Format{kind: :fixed} = f),
    do: to_frac(x, f.frac, f.rounding)

  deftransform rescale(x, %Format{kind: :float}), do: x

  @doc "`rescale/2`, then saturate to the format's width. Identity for float."
  deftransform quantize({re, im}, format), do: {quantize(re, format), quantize(im, format)}

  deftransform quantize(%Fixed{} = x, %Format{kind: :fixed} = f) do
    %Fixed{t: t} = to_frac(x, f.frac, f.rounding)
    {lo, hi} = range(f.bits)
    %Fixed{t: t |> Nx.clip(lo, hi) |> Nx.as_type(container(f.bits)), frac: f.frac}
  end

  deftransform quantize(x, %Format{kind: :float}), do: Nx.as_type(x, :f32)

  defp to_frac(%Fixed{frac: frac} = x, frac, _rounding), do: x

  defp to_frac(%Fixed{t: t, frac: from}, frac, rounding) when from > frac do
    shifted =
      if rounding == :nearest,
        do: P.shift_round(t, from - frac),
        else: Nx.right_shift(t, from - frac)

    %Fixed{t: shifted, frac: frac}
  end

  defp to_frac(%Fixed{t: t, frac: from} = x, frac, _rounding),
    do: %Fixed{
      t: t |> Nx.as_type(container(bits_of(x) + frac - from)) |> Nx.left_shift(frac - from),
      frac: frac
    }

  # -- DSP building blocks ------------------------------------------------------------------

  @doc """
  Numerically controlled oscillator. `phase` and `phase_inc` are u16 phase
  words (full circle = 65536) in both instances. Returns `{{cos, sin}, next_phase}`
  for the advanced phase.

  Float: exact cos/sin of the phase. Fixed: sine table with `lut_bits`
  address bits, amplitude `2^frac - 1`, phase rounded or truncated per format.
  """
  deftransform oscillator(phase, phase_inc, %Format{} = f) do
    next = P.add_wrap(phase, phase_inc, :u16)

    nco =
      case f.kind do
        :float ->
          angle = next |> Nx.as_type(:f64) |> Nx.multiply(2 * :math.pi() / 65536)
          {angle |> Nx.cos() |> Nx.as_type(:f32), angle |> Nx.sin() |> Nx.as_type(:f32)}

        :fixed ->
          {c, s} =
            P.lut_sincos_q15(next,
              bits: f.lut_bits,
              amplitude: (1 <<< f.frac) - 1,
              round: f.rounding == :nearest
            )

          {%Fixed{t: c, frac: f.frac}, %Fixed{t: s, frac: f.frac}}
      end

    {nco, next}
  end

  @doc """
  One FIR step with constant real `taps` (floats): `{acc, next_line}` where
  `acc = sum(taps[k] * x[n-k])` at full precision and `line` holds the
  previous `length(taps) - 1` samples, newest first. Fixed point: taps are
  rounded to the format at compile time, and `acc` has the binary point
  `x.frac + format.frac`; the container is `s32` when the constant taps
  prove it suffices.
  """
  deftransform fir(x, line, taps, %Format{} = f) when is_list(taps) and length(taps) >= 2 do
    n = length(taps)
    window = Nx.concatenate([Nx.reshape(value_tensor(x), {1}), value_tensor(line)])
    next = Nx.slice(window, [0], [n - 1])

    case f.kind do
      :float ->
        {Nx.dot(window, Nx.tensor(taps, type: :f32, backend: Nx.BinaryBackend)), next}

      :fixed ->
        {lo, hi} = range(f.bits)
        q_taps = Enum.map(taps, &(round(&1 * (1 <<< f.frac)) |> max(lo) |> min(hi)))
        bound = (1 <<< (bits_of(x) - 1)) * Enum.sum(Enum.map(q_taps, &abs/1))
        c = if bound < 1 <<< 31, do: :s32, else: :s64
        acc = Nx.dot(Nx.as_type(window, c), Nx.tensor(q_taps, type: c, backend: Nx.BinaryBackend))
        {%Fixed{t: acc, frac: x.frac + f.frac}, %Fixed{t: next, frac: x.frac}}
    end
  end

  defp value_tensor(%Fixed{t: t}), do: t
  defp value_tensor(t), do: t

  # -- helpers -------------------------------------------------------------------------------

  defp bits_of(%Fixed{t: t}), do: t |> Nx.type() |> elem(1)

  defp container(bits) when bits <= 8, do: :s8
  defp container(bits) when bits <= 16, do: :s16
  defp container(bits) when bits <= 32, do: :s32
  defp container(_bits), do: :s64

  defp range(bits), do: {-(1 <<< (bits - 1)), (1 <<< (bits - 1)) - 1}
end
