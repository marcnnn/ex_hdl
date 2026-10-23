defmodule ExHdl.Synth.PnR do
  @moduledoc """
  Place and route of a generated module for a Zynq-7020 (`xc7z020clg400-1`)
  with the open toolchain: Yosys `synth_xilinx` on the host, then
  nextpnr-xilinx, `fasm2frames` and `xc7frames2bit` from a container image
  built from `priv/pnr/Containerfile` (see "Place and route" in the README).

  The module is timed out of context in the sense that matters for a core:
  `wrapper/2` puts it between one input pin that feeds a shift register
  holding every input bit and one output pin behind a registered parity tree
  of every output bit. The only I/O paths are then pin to flip-flop, and the
  paths of the core are register to register.

  Nextpnr reports one number for the whole design: the clock period of the
  slowest register to register path (`fmax_mhz`), with the critical path.
  Sign-off tools time more than that (setup and hold at all corners, clock
  skew); treat the result as an estimate of Vivado's, usually pessimistic
  for routing and optimistic or missing for the hard blocks (see
  `docs/pnr.md`).
  """

  @image "exhdl-pnr"

  @type result :: %{
          target_mhz: number(),
          fmax_mhz: float() | nil,
          slack_ns: float() | nil,
          met: boolean(),
          critical_path: [map()],
          utilization: %{String.t() => {non_neg_integer(), non_neg_integer()}},
          bitstream: Path.t() | nil,
          log: String.t(),
          yosys: map(),
          seconds: %{yosys: float(), pnr: float()}
        }

  @doc "True when yosys and podman are in `PATH` and the container image exists."
  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    System.find_executable(Keyword.get(opts, :yosys, "yosys")) != nil and
      System.find_executable("podman") != nil and image_exists?(Keyword.get(opts, :image, @image))
  end

  defp image_exists?(image) do
    match?({_, 0}, System.cmd("podman", ["image", "exists", image], stderr_to_stdout: true))
  end

  @doc """
  Synthesises, places and routes `sources` (`%{filename => sv_source}`) with
  `top` as the module to time.

  Options: `:clock_mhz` (target, default 100), `:seed` (default 1), `:dsp`
  (map multipliers to DSP48E1, default true), `:bitstream` (also write
  `<top>.bit`, default false), `:workdir` (keep the files there; default a
  temporary directory removed afterwards, unless a bitstream is asked for),
  `:wrapper` (default true), `:image`, `:yosys`.

  Returns `{:ok, result}` (see `t:result/0`; `slack_ns` is the period minus
  the critical path delay, negative when the target is missed) or
  `{:error, message}`.
  """
  @spec run(%{String.t() => String.t()}, String.t(), keyword()) ::
          {:ok, result()} | {:error, String.t()}
  def run(sources, top, opts \\ []) do
    mhz = Keyword.get(opts, :clock_mhz, 100)
    image = Keyword.get(opts, :image, @image)
    yosys = Keyword.get(opts, :yosys) || System.find_executable("yosys")
    podman = System.find_executable("podman")
    bit? = Keyword.get(opts, :bitstream, false)

    cond do
      yosys == nil -> {:error, "yosys not found in PATH"}
      podman == nil -> {:error, "podman not found in PATH"}
      not image_exists?(image) -> {:error, "image #{image} missing; see priv/pnr/Containerfile"}
      true -> flow(sources, top, mhz, bit?, yosys, podman, image, opts)
    end
  end

  defp flow(sources, top, mhz, bit?, yosys, podman, image, opts) do
    {dir, keep?} =
      case Keyword.get(opts, :workdir) do
        nil -> {Path.join(System.tmp_dir!(), "ex_hdl_pnr_#{System.unique_integer([:positive])}"), bit?}
        d -> {Path.expand(d), true}
      end

    File.mkdir_p!(dir)

    try do
      with {:ok, files} <- write_sources(sources, dir),
           {:ok, wrapped, top_name} <- maybe_wrap(sources, top, Keyword.get(opts, :wrapper, true)),
           {:ok, files} <- write_wrapper(files, wrapped, dir),
           {:ok, ys, ys_s} <- synth(yosys, files, top_name, dir, Keyword.get(opts, :dsp, true)),
           :ok <- File.write(Path.join(dir, "top.xdc"), xdc()),
           {:ok, pnr_s} <- place_route(podman, image, dir, mhz, opts, bit?) do
        log = File.read!(Path.join(dir, "nextpnr.log"))
        report = parse_report(log, mhz)

        {:ok,
         Map.merge(report, %{
           target_mhz: mhz,
           bitstream: if(bit?, do: Path.join(dir, "top.bit")),
           log: log,
           yosys: ys,
           seconds: %{yosys: ys_s, pnr: pnr_s}
         })}
      end
    after
      unless keep?, do: File.rm_rf!(dir)
    end
  end

  defp write_sources(sources, dir) do
    files =
      for {name, src} <- Enum.sort(sources) do
        path = Path.join(dir, name)
        File.write!(path, src)
        path
      end

    {:ok, files}
  end

  defp maybe_wrap(_sources, top, false), do: {:ok, nil, top}

  defp maybe_wrap(sources, top, true) do
    case wrapper(sources, top) do
      {:ok, src} -> {:ok, src, "pnr_top"}
      {:error, _} = e -> e
    end
  end

  defp write_wrapper(files, nil, _dir), do: {:ok, files}

  defp write_wrapper(files, src, dir) do
    path = Path.join(dir, "pnr_top.sv")
    File.write!(path, src)
    {:ok, files ++ [path]}
  end

  @doc """
  The wrapper `pnr_top (clk, din, dout)` of module `top` found in `sources`:
  every input except `clk` is a slice of one shift register fed by `din`,
  `dout` is a registered 6-input parity tree over a register of all outputs.
  """
  @spec wrapper(%{String.t() => String.t()}, String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def wrapper(sources, top) do
    with {:ok, ports} <- ports(sources, top) do
      {ins, outs} = Enum.split_with(ports, &(&1.dir == :input))
      clk = Enum.find(ins, &(&1.name == "clk"))
      data_in = Enum.reject(ins, &(&1.name == "clk"))

      cond do
        clk == nil -> {:error, "#{top} has no input named clk"}
        outs == [] -> {:error, "#{top} has no outputs"}
        true -> {:ok, wrapper_source(top, data_in, outs)}
      end
    end
  end

  defp wrapper_source(top, ins, outs) do
    ni = ins |> Enum.map(& &1.width) |> Enum.sum() |> max(1)
    no = outs |> Enum.map(& &1.width) |> Enum.sum()

    {in_decls, in_conns, _} =
      Enum.reduce(ins, {[], [], 0}, fn p, {decls, conns, off} ->
        wire = "i_#{p.name}"

        {["  logic [#{p.width - 1}:0] #{wire};\n  assign #{wire} = sr[#{off + p.width - 1}:#{off}];\n" | decls],
         ["    .#{p.name}(#{wire})" | conns], off + p.width}
      end)

    {out_decls, out_conns, names} =
      Enum.reduce(outs, {[], [], []}, fn p, {decls, conns, names} ->
        wire = "o_#{p.name}"
        {["  logic [#{p.width - 1}:0] #{wire};\n" | decls], ["    .#{p.name}(#{wire})" | conns], [wire | names]}
      end)

    conns = Enum.reverse(in_conns) ++ ["    .clk(clk)"] ++ Enum.reverse(out_conns)

    """
    // Generated by ExHdl.Synth.PnR: one input pin, one output pin, so the
    // timing is that of #{top}. Not for use in a design.
    module pnr_top (
      input  logic clk,
      input  logic din,
      output logic dout
    );
      logic [#{ni - 1}:0] sr;
      always_ff @(posedge clk) sr <= {sr[#{max(ni - 2, 0)}:0], din};
    #{Enum.reverse(in_decls)}#{Enum.reverse(out_decls)}
      #{top} dut (
    #{Enum.join(conns, ",\n")}
      );

      logic [#{no - 1}:0] obs;
      always_ff @(posedge clk) obs <= {#{Enum.join(names, ", ")}};
    #{parity_tree(no)}
    endmodule
    """
  end

  # Registered parity levels of 6 bits each (one LUT6) down to one bit.
  defp parity_tree(width), do: parity_tree(width, "obs", 0, [])

  defp parity_tree(1, prev, _n, acc),
    do: Enum.join(Enum.reverse(acc), "") <> "  assign dout = #{prev}[0];\n"

  defp parity_tree(w, prev, n, acc) do
    next = div(w + 5, 6)
    name = "par#{n}"

    bits =
      for i <- 0..(next - 1) do
        hi = min(6 * i + 5, w - 1)
        "    #{name}[#{i}] <= ^#{prev}[#{hi}:#{6 * i}];\n"
      end

    block =
      "  logic [#{next - 1}:0] #{name};\n  always_ff @(posedge clk) begin\n#{Enum.join(bits)}  end\n"

    parity_tree(next, name, n + 1, [block | acc])
  end

  @doc false
  # ANSI port declarations of module `top`: [%{dir:, name:, width:}].
  def ports(sources, top) do
    src = sources |> Map.values() |> Enum.join("\n")

    case Regex.run(~r/module\s+#{Regex.escape(top)}\s*(?:#\s*\(.*?\)\s*)?\((.*?)\)\s*;/s, src) do
      nil ->
        {:error, "module #{top} not found"}

      [_, body] ->
        ports =
          body
          |> String.replace(~r{//[^\n]*}, "")
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&port/1)

        if Enum.any?(ports, &is_nil/1),
          do: {:error, "cannot parse the port list of #{top}"},
          else: {:ok, ports}
    end
  end

  defp port(decl) do
    re = ~r/^(input|output)\s+(?:logic|wire|reg)?\s*(?:signed\s+)?(?:\[(\d+):(\d+)\])?\s*(\w+)$/

    case Regex.run(re, decl) do
      [_, dir, "", "", name] -> %{dir: String.to_atom(dir), name: name, width: 1}
      [_, dir, hi, lo, name] -> %{dir: String.to_atom(dir), name: name, width: String.to_integer(hi) - String.to_integer(lo) + 1}
      _ -> nil
    end
  end

  # Pins of the Pynq-Z2 / Z-Turn style clg400 package: sysclk on H16 (a
  # clock-capable pin), data pins on the same bank. The pin choice does not
  # matter for the core timing.
  defp xdc do
    """
    set_property LOC H16 [get_ports clk]
    set_property IOSTANDARD LVCMOS33 [get_ports clk]
    set_property LOC M14 [get_ports din]
    set_property IOSTANDARD LVCMOS33 [get_ports din]
    set_property LOC M15 [get_ports dout]
    set_property IOSTANDARD LVCMOS33 [get_ports dout]
    """
  end

  defp synth(yosys, files, top, dir, dsp?) do
    json = Path.join(dir, "top.json")
    stat = Path.join(dir, "stat.json")

    script =
      "read_verilog -sv #{Enum.join(files, " ")}; " <>
        "synth_xilinx -flatten -abc9 -arch xc7#{if dsp?, do: "", else: " -nodsp"} -top #{top}; " <>
        "tee -q -o #{stat} stat -json; write_json #{json}"

    t0 = System.monotonic_time(:millisecond)

    case System.cmd(yosys, ["-q", "-p", script], stderr_to_stdout: true) do
      {_, 0} ->
        secs = (System.monotonic_time(:millisecond) - t0) / 1000
        {:ok, stat |> File.read!() |> JSON.decode!() |> yosys_cells(), secs}

      {log, status} ->
        {:error, "yosys exited with #{status}:\n#{String.slice(log, -2000, 2000)}"}
    end
  end

  defp yosys_cells(%{"design" => %{"num_cells_by_type" => cells}}), do: cells
  defp yosys_cells(%{"design" => d}), do: Map.get(d, "num_cells", %{})

  defp place_route(podman, image, dir, mhz, opts, bit?) do
    script = Path.join(:code.priv_dir(:ex_hdl), "pnr/pnr.sh")
    seed = Keyword.get(opts, :seed, 1)
    t0 = System.monotonic_time(:millisecond)

    args = [
      "run", "--rm", "-v", "#{dir}:/work:Z", "-v", "#{script}:/pnr.sh:ro,Z", image,
      "sh", "/pnr.sh", "/work", "#{mhz}", "#{seed}", if(bit?, do: "1", else: "0")
    ]

    case System.cmd(podman, args, stderr_to_stdout: true) do
      {_, 0} -> {:ok, (System.monotonic_time(:millisecond) - t0) / 1000}
      {log, status} -> {:error, "nextpnr flow exited with #{status}:\n#{String.slice(log, -3000, 3000)}"}
    end
  end

  @doc """
  Reads utilisation, Fmax and the critical path from a nextpnr log. The
  last "Max frequency" line of the log (after routing) counts.
  """
  @spec parse_report(String.t(), number()) :: map()
  def parse_report(log, target_mhz) do
    fmax =
      ~r/Max frequency for clock\s+'[^']*':\s*([\d.]+)\s*MHz/
      |> Regex.scan(log)
      |> List.last()
      |> case do
        [_, f] -> String.to_float(f)
        nil -> nil
      end

    util =
      for [_, res, used, avail] <- Regex.scan(~r/^Info:\s+(\w+):\s+(\d+)\/\s*(\d+)\s+\d+%/m, log),
          into: %{},
          do: {res, {String.to_integer(used), String.to_integer(avail)}}

    %{
      fmax_mhz: fmax,
      slack_ns: fmax && 1000 / target_mhz - 1000 / fmax,
      met: fmax != nil and fmax >= target_mhz,
      critical_path: critical_path(log),
      utilization: util
    }
  end

  # The lines of the last "Critical path report" block:
  # "Info:  1.2  3.4  Source a.Q" style entries are kept as raw lines.
  defp critical_path(log) do
    case log |> String.split("Critical path report for clock") |> List.last() do
      block when is_binary(block) and block != log ->
        block
        |> String.split("\n")
        |> Enum.drop(1)
        |> Enum.take_while(&(String.starts_with?(&1, "Info:") and not String.contains?(&1, "Info: Max delay")))
        |> Enum.map(&%{line: String.replace_prefix(&1, "Info: ", "") |> String.trim()})

      _ ->
        []
    end
  end
end
