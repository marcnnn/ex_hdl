defmodule ExHdl.GnuRadioReferenceTest do
  @moduledoc """
  Two layers per shared DSP case (test/dsp_cases/*.json), both on the CPU:

    1. The block's float instance against GNU Radio on the same input:
       is the algorithm right?
    2. Each fixed-point variant against the float instance: what does the
       number format cost?

  Each comparison checks a per-sample error bound and an SNR minimum; the
  reasoning is in the case file. GNU Radio's output is committed in
  test/fixtures/gnuradio/, so GNU Radio is not needed to run this.
  """
  use ExUnit.Case, async: true

  alias ExHdl.Test.GnuRadioFixture, as: F

  @moduletag timeout: 300_000

  setup_all do
    # Float instance per case, shared by its variant tests.
    runs =
      Map.new(F.case_paths(), fn path ->
        case = F.read_case(path)
        data = F.load(case, path)

        {case["name"],
         %{case: case, data: data, float: F.run_block(case, data.input, ExHdl.Num.float())}}
      end)

    %{runs: runs}
  end

  for path <- F.case_paths() do
    @external_resource path
    case = F.read_case(path)
    @name case["name"]

    test "#{case["name"]}: float instance vs GNU Radio (#{case["description"]})", %{runs: runs} do
      %{case: case, data: data, float: float} = runs[@name]

      assert_close(
        data.reference,
        float,
        case["float_vs_gnuradio"],
        "#{@name} float vs GNU Radio",
        data.input
      )
    end

    for variant <- case["fixed_vs_float"] do
      @variant variant
      test "#{case["name"]}: #{variant["variant"]} vs float instance", %{runs: runs} do
        %{case: case, data: data, float: float} = runs[@name]
        format = F.format(@variant["format"])
        fixed = F.run_block(case, data.input, format)

        # Where the SIMD kernels cover the format, they must give the same bits.
        case F.run_block(case, data.input, format, :cpu) do
          {simd, :simd} ->
            assert simd == fixed, "#{@name} #{@variant["variant"]}: SIMD differs from Nx"

          {_, :nx} ->
            :ok
        end

        assert_close(
          float,
          fixed,
          @variant,
          "#{@name} #{@variant["variant"]} vs float",
          data.input
        )
      end
    end
  end

  @doc false
  # `expect` has max_error_lsb, snr_db_min and rationale.
  def assert_close(reference, signal, expect, label, input) do
    assert length(signal) == length(reference)
    {worst, i} = F.worst_sample(reference, signal)

    assert worst <= expect["max_error_lsb"], """
    #{label}: sample #{i} is off by #{Float.round(worst, 3)} LSB (bound #{expect["max_error_lsb"]})
      input:     #{inspect(Enum.at(input, i))}
      reference: #{inspect(Enum.at(reference, i))}
      got:       #{inspect(Enum.at(signal, i))}
      bound:     #{expect["rationale"]}
    """

    snr = F.snr_db(reference, signal)

    assert snr >= expect["snr_db_min"],
           "#{label}: SNR #{Float.round(snr, 1)} dB < #{expect["snr_db_min"]} dB (#{expect["rationale"]})"

    %{snr: snr, worst_lsb: worst}
  end

  # What a format decision buys, measured against the float instance.
  describe "design comparisons" do
    defp snr(runs, name, variant) do
      %{case: case, data: data, float: float} = runs[name]
      v = Enum.find(case["fixed_vs_float"], &(&1["variant"] == variant))
      F.snr_db(float, F.run_block(case, data.input, F.format(v["format"])))
    end

    test "NCO: rounding the phase buys 6 dB, two more table bits 12 dB", %{runs: runs} do
      base = snr(runs, "ddc_rotator", "q15_lut10_truncate")
      assert_in_delta snr(runs, "ddc_rotator", "q15_lut10_nearest") - base, 6.0, 1.0
      assert_in_delta snr(runs, "ddc_rotator", "q15_lut12_truncate") - base, 12.0, 1.0
    end

    test "18-bit (Q17) data paths buy at least 12 dB over Q15", %{runs: runs} do
      assert snr(runs, "fir_ccf_31tap", "q17_nearest") - snr(runs, "fir_ccf_31tap", "q15_nearest") >=
               12

      assert snr(runs, "one_pole_a0p01", "q17_nearest") -
               snr(runs, "one_pole_a0p01", "q15_nearest") >= 12
    end

    test "rounding the IIR update beats truncation by more than 20 dB at alpha = 0.01", %{
      runs: runs
    } do
      assert snr(runs, "one_pole_a0p01", "q15_nearest") -
               snr(runs, "one_pole_a0p01", "q15_truncate") > 20
    end
  end
end
