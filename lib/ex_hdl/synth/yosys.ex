defmodule ExHdl.Synth.Yosys do
  @moduledoc """
  Resource estimates for 7-series (Zynq-7020) and UltraScale+ parts with Yosys
  `synth_xilinx`. Only synthesis: no placement, no timing. I/O buffers are
  not inserted (`-noiopad`), so the numbers are those of the module as a
  block inside a larger design.
  """

  @doc """
  Synthesises `sources` (`%{filename => sv_source}`) with `top` as top
  module. Returns `{:ok, %{lut:, ff:, dsp:, bram18:, bram36:, uram:, carry:, srl:,
  lutram:, cells:}}` where `bram18` counts a RAMB36 as two, `bram36` is the
  block RAM tile count of data sheets and Vivado (a RAMB18 is half a tile),
  and `cells` has every cell type.

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

        logfile = Path.join(tmp, "yosys.log")

        case System.cmd(yosys, ["-q", "-l", logfile, "-p", script], stderr_to_stdout: true) do
          {_, 0} -> {:ok, summarize(stat |> File.read!() |> JSON.decode!())}
          {out, status} -> {:error, failure(status, out, logfile)}
        end
      after
        File.rm_rf!(tmp)
      end
    end
  end

  # `-q` hides everything but errors, so a crash can leave stdout empty; the
  # `-l` log file still has the last pass that ran.
  defp failure(status, out, logfile) do
    log = if File.exists?(logfile), do: logfile |> File.read!() |> tail(40), else: ""
    signal = if status > 128, do: " (signal #{status - 128}; killed, out of memory?)", else: ""
    out = if String.trim(out) == "", do: "(no output)", else: out
    "yosys exited with #{status}#{signal}:\n#{out}\nlast log lines:\n#{log}"
  end

  defp tail(text, n), do: text |> String.split("\n") |> Enum.take(-n) |> Enum.join("\n")

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
      bram36:
        count.(&(&1 in ["RAMB36E1", "RAMB36E2"])) + count.(&(&1 in ["RAMB18E1", "RAMB18E2"])) / 2,
      uram: count.(&(&1 == "URAM288")),
      carry: count.(&(&1 in ["CARRY4", "CARRY8"])),
      srl: count.(&String.starts_with?(&1, "SRL")),
      lutram: count.(&String.match?(&1, ~r/^RAM\d+[MX]/)),
      cells: cells
    }
  end
end
