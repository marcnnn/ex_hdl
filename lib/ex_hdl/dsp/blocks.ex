defmodule ExHdl.DSP.Blocks do
  @moduledoc """
  DSP algorithms written once against `ExHdl.Num` and instantiated by the
  `:format` option: `ExHdl.Num.float()` gives the float reference,
  `ExHdl.Num.q(16, 15, ...)` the fixed-point version for CPU and FPGA.

  All blocks are stream kernels `step(sample, state, params..., opts) ->
  {output, next_state}` (see `ExHdl.DSP.run_scan/5` and
  `ExHdl.DSP.analyze_scan/3`).
  """
  import Nx.Defn
  import ExHdl.Num

  @doc """
  Digital down-converter: mixes the complex sample `x` with an NCO and
  applies `gain`. The state is the u16 phase word, advanced by `phase_inc`
  before use.
  """
  defn ddc(x, phase, phase_inc, gain, opts \\ []) do
    opts = keyword!(opts, [:format])
    format = opts[:format]
    {nco, next_phase} = oscillator(phase, phase_inc, format)
    y = x |> cmul(nco) |> rescale(format) |> cscale(gain) |> quantize(format)
    {y, next_phase}
  end

  @doc """
  FIR filter with constant real `:taps` on complex samples (I and Q with the
  same taps, like GNU Radio's `fir_filter_ccf`). The state is one delay line
  per component.
  """
  defn fir_complex(x, lines, opts \\ []) do
    opts = keyword!(opts, [:format, :taps])
    format = opts[:format]
    {re, im} = x
    {line_re, line_im} = lines
    {acc_re, next_re} = fir(re, line_re, opts[:taps], format)
    {acc_im, next_im} = fir(im, line_im, opts[:taps], format)
    {quantize({acc_re, acc_im}, format), {next_re, next_im}}
  end

  @doc "One-pole low-pass `y' = y + alpha * (x - y)`; the state is `y`."
  defn one_pole(x, y, alpha, opts \\ []) do
    opts = keyword!(opts, [:format])
    format = opts[:format]
    y_next = add(y, rescale(mul(alpha, sub(x, y)), format)) |> quantize(format)
    {y_next, y_next}
  end
end
