defmodule ExHdl.OFDM.Correct do
  @moduledoc """
  Frequency correction of `ExSdr.Comm.OFDM.FixedFrontEnd` as a stream
  kernel: the sample is rotated by `exp(i * 2 pi * phase / 2^32)`, the
  phase word of sample `n` being `(n * inc + phase0) mod 2^32`. The input
  is `sc16` (a Q15 `{re, im}` pair), the NCO a `coef` table (the format's
  `lut_bits`, rounded phase index), the product is rescaled and saturated
  to the data format, as there.

  The kernel's state is `n * inc mod 2^32`, so it runs on across chunks
  exactly as `FixedFrontEnd.run/4` joins them: a stream that starts `s`
  samples into the signal passes `phase0 = inc * s mod 2^32`
  (`phase0/2`), later chunks need nothing.

  Parameters (ports `p_inc`, `p_phase0`, applied with `p_load`):
  `inc = FixedFrontEnd.phase_increment(freq_offset, fft)` and `phase0`.
  """
  import Nx.Defn
  alias NxFixed.{Fixed, Num}
  alias NxFixed.Primitives, as: P

  @mask 0xFFFFFFFF

  @doc "Default formats of `FixedFrontEnd`: data q(16, 12), coefficients q(16, 15) with 4096 table entries."
  def default_opts,
    do: [format: Num.q(16, 12), coef: Num.q(16, 15, lut_bits: 12)]

  defn step(sample, phase, inc, phase0, opts \\ []) do
    opts = keyword!(opts, [:format, :coef])
    rotate(sample, phase, inc, phase0, opts)
  end

  deftransformp rotate({re, im}, phase, inc, phase0, opts) do
    f = opts[:format]
    mask = Nx.tensor(@mask, type: :s64, backend: Nx.BinaryBackend)

    word =
      phase
      |> Nx.add(Nx.bitwise_and(phase0, mask))
      |> Nx.bitwise_and(mask)

    mixed = {re, im} |> Num.cmul(nco(word, opts[:coef])) |> Num.rescale(f) |> Num.quantize(f)
    next = phase |> Nx.add(Nx.bitwise_and(inc, mask)) |> Nx.bitwise_and(mask)
    {mixed, next}
  end

  # exp(i * 2 pi * phase / 2^32), as FixedFrontEnd's nco/2
  defp nco(phase, %Num.Format{kind: :fixed} = c) do
    {cos, sin} =
      phase
      |> Nx.right_shift(16)
      |> Nx.as_type(:u16)
      |> P.lut_sincos_q15(bits: c.lut_bits, amplitude: Bitwise.bsl(1, c.frac) - 1, round: true)

    {%Fixed{t: cos, frac: c.frac}, %Fixed{t: sin, frac: c.frac}}
  end

  @doc "The phase word at the first sample of a chunk that starts `start` samples into the stream."
  def phase0(inc, start), do: Bitwise.band(inc * start, @mask)

  @doc "Argument templates for `ExHdl.DSP.analyze_scan/3`: sc16 sample, phase, `inc`, `phase0`, options."
  def args(opts \\ []) do
    opts = Keyword.merge(default_opts(), opts)
    s16 = Nx.template({}, :s16)
    word = Nx.template({}, :s64)
    [{%Fixed{t: s16, frac: 15}, %Fixed{t: s16, frac: 15}}, word, word, word, opts]
  end

  @doc """
  The module of the correction (`ExHdl.DSP.scan_to_sv/3`; `opts` for the
  formats and the generator, `ii:` defaults to 1).
  """
  def scan_to_sv(opts \\ []) do
    {fmt, gen} = Keyword.split(opts, [:format, :coef])

    gen =
      Keyword.merge(
        [
          name: "ofdm_correct",
          state: 1,
          init: Nx.tensor(0, type: :s64),
          param_names: ["inc", "phase0"],
          param_ranges: %{2 => 0..@mask, 3 => 0..@mask},
          ii: 1
        ],
        gen
      )

    ExHdl.DSP.scan_to_sv(&step/5, args(fmt), gen)
  end
end
