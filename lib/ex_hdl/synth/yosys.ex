defmodule ExHdl.Synth.Yosys do
  @moduledoc """
  Resource estimates for 7-series (Zynq-7020) and UltraScale+ parts with Yosys
  `synth_xilinx`. Only synthesis: no placement, no timing. I/O buffers are
  not inserted (`-noiopad`), so the numbers are those of the module as a
  block inside a larger design.
  """

  @doc """
  Synthesises `sources` (`%{filename => sv_source}`) with `top` as top
  module. Returns `{:ok, %{lut:, ff:, dsp:, bram18:, carry:, srl:, lutram:, cells:}}`
  where `bram18` counts RAMB36E1 as two, and `cells` has every cell type.

  Options: `:yosys` (executable, default from `PATH`), `:family` (default
  `"xc7"`; `"xcup"` for UltraScale+ such as the XCKU3P).
  """
  @spec utilization(%{String.t() => String.t()}, String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def utilization(sources, top, opts \\ []) do
    yosys = Keyword.get(opts, :yosys, System.find_executable("yosys"))
    family = Keyword.get(opts, :family, "xc7")

    if yosys == nil do
      {:error, "yosys not found in PATH"}
    else
      tmp = Path.join(System.tmp_dir!(), "ex_hdl_yosys_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      try do
        files =
          for {name, src} <- Enum.sort(sources) do
            path = Path.join(tmp, name)
            File.write!(path, src)
            path
          end

        stat = Path.join(tmp, "stat.json")

        script =
          "read_verilog -sv #{Enum.join(files, " ")}; " <>
            "synth_xilinx -family #{family} -noiopad -top #{top}; " <>
            "tee -q -o #{stat} stat -json"

        case System.cmd(yosys, ["-q", "-p", script], stderr_to_stdout: true) do
          {_, 0} -> {:ok, summarize(stat |> File.read!() |> JSON.decode!())}
          {log, status} -> {:error, "yosys exited with #{status}:\n#{log}"}
        end
      after
        File.rm_rf!(tmp)
      end
    end
  end

  defp summarize(%{"design" => %{"num_cells_by_type" => cells}}) do
    count = fn pred ->
      cells |> Enum.filter(fn {t, _} -> pred.(t) end) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    end

    %{
      lut: count.(&String.match?(&1, ~r/^LUT\d$/)),
      ff: count.(&String.match?(&1, ~r/^FD[A-Z]*$/)),
      dsp: count.(&String.starts_with?(&1, "DSP48")),
      bram18:
        count.(&(&1 in ["RAMB18E1", "RAMB18E2"])) + 2 * count.(&(&1 in ["RAMB36E1", "RAMB36E2"])),
      uram: count.(&(&1 == "URAM288")),
      carry: count.(&(&1 in ["CARRY4", "CARRY8"])),
      srl: count.(&String.starts_with?(&1, "SRL")),
      lutram: count.(&String.match?(&1, ~r/^RAM\d+[MX]/)),
      cells: cells
    }
  end
end
