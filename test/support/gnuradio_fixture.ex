defmodule ExHdl.Test.GnuRadioFixture do
  @moduledoc false
  # Loads GNU Radio reference data from test/fixtures/gnuradio/<case>/ and
  # compares signals. Regenerate the data with scripts/gnuradio_golden.sh.

  @root Path.expand("../fixtures/gnuradio", __DIR__)

  def exists?(name), do: File.exists?(Path.join([@root, name, "case.json"]))

  @doc """
  Returns `%{manifest, input, reference}`. For complex cases `input` is a
  list of `{i, q}` int16 pairs and `reference` a list of `{re, im}` floats.
  """
  def load(name) do
    dir = Path.join(@root, name)
    manifest = dir |> Path.join("case.json") |> File.read!() |> JSON.decode!()

    input = for <<v::little-signed-16 <- File.read!(Path.join(dir, "input.s16le"))>>, do: v
    reference = for <<v::little-float-32 <- File.read!(Path.join(dir, "gnuradio.f32le"))>>, do: v

    if manifest["kind"] == "complex",
      do: %{manifest: manifest, input: pairs(input), reference: pairs(reference)},
      else: %{manifest: manifest, input: input, reference: reference}
  end

  defp pairs(list), do: list |> Enum.chunk_every(2) |> Enum.map(&List.to_tuple/1)

  @doc "SNR in dB of `signal` against `reference` (lists of numbers or {re, im})."
  def snr_db(reference, signal) do
    {power, error} =
      Enum.zip(reference, signal)
      |> Enum.reduce({0.0, 0.0}, fn {r, s}, {p, e} -> {p + mag2(r), e + mag2(sub(s, r))} end)

    10 * :math.log10(power / max(error, 1.0e-300))
  end

  @doc "Largest absolute error, in units of one Q15 LSB."
  def max_error_lsb(reference, signal) do
    Enum.zip(reference, signal)
    |> Enum.map(fn {r, s} -> :math.sqrt(mag2(sub(s, r))) * 32768 end)
    |> Enum.max()
  end

  defp sub({a, b}, {c, d}), do: {a - c, b - d}
  defp sub(a, b), do: a - b
  defp mag2({a, b}), do: a * a + b * b
  defp mag2(a), do: a * a
end
