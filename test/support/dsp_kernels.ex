defmodule ExHdl.Test.DSP do
  @moduledoc false
  import Nx.Defn
  import NxFixed.Primitives

  # The ddc_step from the architecture plan, with explicit wrap and saturate.
  defn ddc_step(sample, phase_acc, phase_inc, gain_q15, opts \\ []) do
    opts = keyword!(opts, amplitude: 32767, lut_bits: 10, round: false)
    {i_in, q_in} = sample

    next_phase = add_wrap(phase_acc, phase_inc, :u16)

    {nco_i, nco_q} =
      lut_sincos_q15(next_phase,
        amplitude: opts[:amplitude],
        bits: opts[:lut_bits],
        round: opts[:round]
      )

    {mix_i, mix_q} = complex_widening_mul_q15({i_in, q_in}, {nco_i, nco_q})

    gain = Nx.as_type(gain_q15, :s32)
    out_i = (q15_shift(mix_i, opts[:round]) * gain) |> q15_shift(opts[:round]) |> saturate_s16()
    out_q = (q15_shift(mix_q, opts[:round]) * gain) |> q15_shift(opts[:round]) |> saturate_s16()

    {{out_i, out_q}, next_phase}
  end

  # Applies the gain to the Q30 mixer output without shifting it back to
  # Q15 first: overflows for any NCO amplitude.
  defn ddc_step_no_preshift(sample, phase_acc, phase_inc, gain_q15) do
    {i_in, q_in} = sample
    next_phase = add_wrap(phase_acc, phase_inc, :u16)
    {nco_i, nco_q} = lut_sincos_q15(next_phase)
    {mix_i, _mix_q} = complex_widening_mul_q15({i_in, q_in}, {nco_i, nco_q})
    (mix_i * Nx.as_type(gain_q15, :s32)) |> Nx.right_shift(30) |> saturate_s16()
  end

  # One-pole low-pass, y' = y + a * (x - y), in Q15. The multiply is part
  # of the state update, so the feedback loop goes through a DSP48E1.
  defn one_pole_step(x, y, a) do
    y32 = Nx.as_type(y, :s32)
    diff = Nx.as_type(x, :s32) - y32
    y_next = (y32 + Nx.right_shift(Nx.as_type(a, :s32) * diff, 15)) |> saturate_s16()
    {y_next, y_next}
  end

  # Same filter with round-to-nearest instead of truncation in the update,
  # which halves and centres the dead band.
  defn one_pole_rounded_step(x, y, a) do
    y32 = Nx.as_type(y, :s32)
    diff = Nx.as_type(x, :s32) - y32
    y_next = (y32 + shift_round(Nx.as_type(a, :s32) * diff, 15)) |> saturate_s16()
    {y_next, y_next}
  end

  # GNU Radio's fir_filter_ccf: complex samples, real taps, I and Q filtered
  # with the same taps. The state is one delay line per component.
  defn fir_ccf_step(sample, lines, opts \\ []) do
    opts = keyword!(opts, taps: [], round: true)
    {i, q} = sample
    {line_i, line_q} = lines
    {y_i, next_i} = fir_q15(i, line_i, opts[:taps], round: opts[:round])
    {y_q, next_q} = fir_q15(q, line_q, opts[:taps], round: opts[:round])
    {{y_i, y_q}, {next_i, next_q}}
  end

  deftransformp q15_shift(x, round),
    do: if(round, do: shift_round(x, 15), else: Nx.right_shift(x, 15))

  # The state comes back with a different type.
  defn widening_state_step(x, acc) do
    next = Nx.as_type(acc, :s32) + Nx.as_type(x, :s32)
    {next, next}
  end

  # Accumulator without saturation: s16 + s16 overflows.
  defn overflowing_scan_step(x, acc) do
    next = acc + x
    {next, next}
  end

  # Phase update exactly as written in the plan: relies on as_type to wrap.
  defn plan_phase_update(phase_acc, phase_inc) do
    Nx.add(phase_acc, phase_inc) |> Nx.as_type(:u16)
  end
end
