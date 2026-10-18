defmodule ExHdl.Test.DSP do
  @moduledoc false
  import Nx.Defn
  import ExHdl.DSP.Primitives

  # The ddc_step from the architecture plan, with explicit wrap and saturate.
  defn ddc_step(sample, phase_acc, phase_inc, gain_q15, opts \\ []) do
    opts = keyword!(opts, amplitude: 32767)
    {i_in, q_in} = sample

    next_phase = add_wrap(phase_acc, phase_inc, :u16)
    {nco_i, nco_q} = lut_sincos_q15(next_phase, amplitude: opts[:amplitude])
    {mix_i, mix_q} = complex_widening_mul_q15({i_in, q_in}, {nco_i, nco_q})

    gain = Nx.as_type(gain_q15, :s32)
    out_i = (Nx.right_shift(mix_i, 15) * gain) |> Nx.right_shift(15) |> saturate_s16()
    out_q = (Nx.right_shift(mix_q, 15) * gain) |> Nx.right_shift(15) |> saturate_s16()

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
