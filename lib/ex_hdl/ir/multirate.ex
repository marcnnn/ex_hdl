defmodule ExHdl.IR.Multirate do
  @moduledoc """
  A linear periodically time-varying filter recognised from a frame kernel
  (`ExHdl.Frame.analyze/2`): every `d` input items give `l` output items,
  and output `m` of period `q` is

      y_m[q] = clip(floor((sum_terms sum_j g[m][j] * x_c[q * d + anchor_m - j] + const) / 2^shift), lo, hi)

  for each output component. Decimating FIRs (`l = 1`), interpolators
  (`d = 1`), rational resamplers and polyphase filter banks with complex
  taps all have this form.

    * `d`, `l` - input and output items per period.
    * `anchors` - per output `m`, the newest input it reads (relative to
      the period start, `0..d-1`), non-decreasing.
    * `k` - window length: taps per output (`g[m]` has `k` entries).
    * `inputs` - input components `%{type:, lo:, hi:}` (`{re, im}` is two).
    * `outputs` - output components `%{type:, terms: [%{input:, taps: [[g]]}],
      const:, shift:, lo:, hi:}`; `taps` has one list of `k` integers per
      output phase `m`.
    * `init` - per input component, the window before the first input:
      `x[-1], x[-2], ...` (`k` values).
  """
  defstruct [:d, :l, :anchors, :k, :inputs, :outputs, :init]
end
