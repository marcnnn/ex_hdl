defmodule ExHdl.GnuRadioLiveTest do
  @moduledoc """
  Runs GNU Radio during the test (native, or rootless podman) instead of
  using the committed data:

    * every case is compared against fresh GNU Radio output, and
    * the committed data in test/fixtures/gnuradio/ must still match it.

  Run with `mix test --only gnuradio_live`.
  """
  use ExUnit.Case, async: false

  alias ExHdl.GnuRadioReferenceTest
  alias ExHdl.Test.GnuRadioFixture, as: F

  @moduletag :gnuradio_live
  @moduletag timeout: 900_000

  setup_all do
    out = Path.join(System.tmp_dir!(), "exhdl_gnuradio_#{System.unique_integer([:positive])}")
    script = Path.expand("../scripts/gnuradio_golden.sh", __DIR__)
    {log, status} = System.cmd(script, [out], stderr_to_stdout: true)
    if status != 0, do: flunk("GNU Radio run failed (#{status}):\n#{log}")
    on_exit(fn -> File.rm_rf!(out) end)
    %{live: out}
  end

  for path <- F.case_paths() do
    case_data = F.read_case(path)
    @case_data case_data
    @case_path path

    test "#{case_data["name"]}: float instance against live GNU Radio", %{live: live} do
      data = F.load(@case_data, @case_path, live)
      float = F.run_block(@case_data, data.input, ExHdl.Num.float())

      GnuRadioReferenceTest.assert_close(
        data.reference,
        float,
        @case_data["float_vs_gnuradio"],
        @case_data["name"],
        data.input
      )
    end

    test "#{case_data["name"]}: committed data matches live GNU Radio", %{live: live} do
      committed = F.load(@case_data, @case_path)
      fresh = F.load(@case_data, @case_path, live)

      assert committed.input == fresh.input

      # Exact on the same machine; SIMD (VOLK) paths may differ slightly elsewhere.
      Enum.zip(committed.reference, fresh.reference)
      |> Enum.with_index()
      |> Enum.each(fn {{a, b}, i} ->
        assert close?(a, b), "sample #{i}: committed #{inspect(a)}, live #{inspect(b)}"
      end)
    end
  end

  defp close?({a, b}, {c, d}), do: close?(a, c) and close?(b, d)
  defp close?(a, b), do: abs(a - b) <= 1.0e-6
end
