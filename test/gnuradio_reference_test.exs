defmodule ExHdl.GnuRadioReferenceTest do
  @moduledoc """
  ExHdl's fixed-point kernels, run on the CPU (checked Nx reference), against
  GNU Radio's float implementation of the same processing.

  The reference data lives in test/fixtures/gnuradio/ (see
  scripts/gnuradio_golden.sh), so GNU Radio is not needed to run this.
  GNU Radio computes in float, so results are compared by SNR, with
  thresholds derived from the fixed-point design rather than bit for bit.
  """
  use ExUnit.Case, async: true

  alias ExHdl.DSP
  alias ExHdl.Test.DSP, as: K
  alias ExHdl.Test.GnuRadioFixture, as: F

  @moduletag timeout: 120_000

  defp q15(v), do: v / 32768

  defp run_ddc(case, lut_bits) do
    p = case.manifest["params"]
    samples = Enum.map(case.input, fn {i, q} -> {Nx.s16(i), Nx.s16(q)} end)

    {outputs, _phase} =
      DSP.run_scan(
        &K.ddc_step/5,
        samples,
        Nx.u16(p["initial_phase"]),
        [Nx.u16(p["phase_inc"]), Nx.s16(p["gain_q15"])],
        kernel_opts: [lut_bits: lut_bits]
      )

    Enum.map(outputs, fn {i, q} -> {q15(Nx.to_number(i)), q15(Nx.to_number(q))} end)
  end

  defp run_one_pole(case, rounding) do
    alpha = Nx.s16(case.manifest["params"]["alpha_q15"])
    samples = Enum.map(case.input, &Nx.s16/1)
    kernel = if rounding == :round, do: &K.one_pole_rounded_step/3, else: &K.one_pole_step/3
    {outputs, _y} = DSP.run_scan(kernel, samples, Nx.s16(0), [alpha])
    Enum.map(outputs, &q15(Nx.to_number(&1)))
  end

  # Truncating the phase to B table bits leaves a phase error uniform in
  # [0, 2*pi/2^B); its power (2*pi/2^B)^2 / 3 bounds the SNR (about 6 dB
  # per table bit). Measured: 49.0 dB (B = 10), 61.1 dB (B = 12).
  defp phase_truncation_snr(bits),
    do: -10 * :math.log10(:math.pow(2 * :math.pi() / 2 ** bits, 2) / 3)

  describe "DDC (NCO + mixer + gain) vs rotator_cc + multiply_const_cc" do
    setup do
      %{case: F.load("ddc_rotator")}
    end

    for bits <- [10, 12] do
      test "#{bits}-bit sine table reaches the phase truncation limit", %{case: c} do
        snr = F.snr_db(c.reference, run_ddc(c, unquote(bits)))
        assert snr >= phase_truncation_snr(unquote(bits)) - 1.0
      end
    end

    test "two more table bits buy about 12 dB", %{case: c} do
      gain = F.snr_db(c.reference, run_ddc(c, 12)) - F.snr_db(c.reference, run_ddc(c, 10))
      assert_in_delta gain, 12.0, 1.0
    end
  end

  # y' = y + a*(x - y) >> 15 stops moving once a*(x - y) < 2^15, i.e. when
  # y is within 1/alpha LSB below x (truncation). Rounding halves and
  # centres that dead band.
  describe "one-pole IIR vs single_pole_iir_filter_ff" do
    # {case, kernel, max error bound in LSB, measured SNR - 1 dB as regression guard}
    @cases [
      {"single_pole_iir_a8192", :truncate, 32768 / 8192 + 1, 76.0},
      {"single_pole_iir_a328", :truncate, 32768 / 328 + 1, 43.0},
      {"single_pole_iir_a8192", :round, 32768 / 8192 / 2 + 1, 84.0},
      {"single_pole_iir_a328", :round, 32768 / 328 / 2 + 1, 70.0}
    ]

    for {name, rounding, bound, min_snr} <- @cases do
      test "#{name}, #{rounding}: error within the dead band" do
        c = F.load(unquote(name))
        ours = run_one_pole(c, unquote(rounding))
        assert F.max_error_lsb(c.reference, ours) <= unquote(bound)
        assert F.snr_db(c.reference, ours) >= unquote(min_snr)
      end
    end

    test "rounding beats truncation by more than 20 dB at alpha = 0.01" do
      c = F.load("single_pole_iir_a328")

      gain =
        F.snr_db(c.reference, run_one_pole(c, :round)) -
          F.snr_db(c.reference, run_one_pole(c, :truncate))

      assert gain > 20
    end
  end
end
