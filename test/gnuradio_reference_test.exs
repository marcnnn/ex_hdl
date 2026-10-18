defmodule ExHdl.GnuRadioReferenceTest do
  @moduledoc """
  Runs every shared DSP case (test/dsp_cases/*.json) through ExHdl's
  fixed-point kernels on the CPU and compares the output sample by sample
  with GNU Radio's output for the same input (test/fixtures/gnuradio/).

  GNU Radio computes in float, so each case states an SNR minimum and a
  per-sample error bound, with the reasoning in `expect.rationale`.
  """
  use ExUnit.Case, async: true

  alias ExHdl.Test.GnuRadioFixture, as: F

  @moduletag timeout: 120_000

  for path <- F.case_paths() do
    @external_resource path
    case_data = F.read_case(path)

    @case_data case_data
    @case_path path
    test "#{case_data["name"]}: #{case_data["description"]}" do
      check_case(@case_data, @case_path, F.fixtures_dir())
    end
  end

  @doc false
  def check_case(case, path, root) do
    data = F.load(case, path, root)
    ours = F.run_exhdl(case, data.input)
    expect = case["expect"]

    assert length(ours) == length(data.reference)

    {worst, i} = F.worst_sample(data.reference, ours)

    assert worst <= expect["max_error_lsb"], """
    #{case["name"]}: sample #{i} is off by #{Float.round(worst, 1)} LSB (bound #{expect["max_error_lsb"]})
      input:     #{inspect(Enum.at(data.input, i))}
      GNU Radio: #{inspect(Enum.at(data.reference, i))}
      ExHdl:     #{inspect(Enum.at(ours, i))}
      bound:     #{expect["rationale"]}
    """

    snr = F.snr_db(data.reference, ours)

    assert snr >= expect["snr_db_min"],
           "#{case["name"]}: SNR #{Float.round(snr, 1)} dB < #{expect["snr_db_min"]} dB (#{expect["rationale"]})"

    %{snr: snr, worst_lsb: worst}
  end

  # Relations between cases: what a design change buys.
  describe "design comparisons" do
    defp snr(name) do
      path = Path.join(F.cases_dir(), name <> ".json")
      case = F.read_case(path)
      data = F.load(case, path)
      F.snr_db(data.reference, F.run_exhdl(case, data.input))
    end

    test "two more sine table bits buy about 12 dB" do
      assert_in_delta snr("ddc_rotator_lut12") - snr("ddc_rotator_lut10"), 12.0, 1.0
    end

    test "rounding the IIR update beats truncation by more than 20 dB at alpha = 0.01" do
      assert snr("one_pole_a328_round") - snr("one_pole_a328_truncate") > 20
    end
  end
end
