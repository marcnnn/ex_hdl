defmodule Mix.Tasks.ExHdl.Gen.Sv do
  @shortdoc "Writes SystemVerilog for the packets and stream kernels of modules"
  @moduledoc """
      mix ex_hdl.gen.sv MySDR.Protocol MySDR.Kernels [--out hdl/generated] [--synth]
      mix ex_hdl.gen.sv MySDR.Kernels --pnr --clock-mhz 200 [--bitstream] [--seed 1]

  For a module that `use`s `ExHdl.Protocol`, writes `<packet>_parser.sv`,
  `<packet>_emitter.sv` and `<packet>_loopback.sv` for every `defpacket`.

  For a module exporting `ex_hdl_kernels/0`, writes `<name>.sv` for every
  stream kernel it lists. Each entry is a keyword list with `:name`, `:fun`
  (the `step` function), `:args` (argument templates as for
  `ExHdl.DSP.analyze_scan/3`), `:state` (index of the state argument) and
  optionally `:ii` / `:channels`, timing overrides, `:init` and
  `:param_names` (see `ExHdl.DSP.scan_to_sv/3`):

      def ex_hdl_kernels do
        s = %NxFixed.Fixed{t: Nx.template({}, :s16), frac: 15}
        [[name: "one_pole", fun: &MyDSP.one_pole/4, args: [s, s, s, [format: q15]],
          state: 1, ii: :auto, param_names: ["alpha"]]]
      end

  For a module exporting `ex_hdl_rtl/0`, writes every `ExHdl.RTL` module
  it returns, with all modules below them and the `sources` of their
  black boxes (`ExHdl.Backends.SystemVerilog.RTL.generate/1`):

      def ex_hdl_rtl, do: [MyLib.Mac.build(), ExHdl.RTL.CDC.sync_ff()]

  `--synth` runs Yosys `synth_xilinx` on each kernel and RTL top and
  prints LUT, FF, DSP48E1 and RAMB18 counts (needs `yosys` in `PATH`);
  `--family` picks the Yosys family (default `xc7`, `xcup` for
  UltraScale+).

  `--pnr` places and routes each kernel and RTL top for the Zynq-7020
  (`xc7z020clg400-1`) with Yosys and nextpnr-xilinx (`ExHdl.Synth.PnR`, needs
  podman and the image of `priv/pnr/Containerfile`) and prints Fmax, slack
  and utilisation against `--clock-mhz` (default 100). The clock is also
  the scheduling target of the generated kernels. `--bitstream` writes
  `<out>/<name>.bit` too; `--seed` is the placer seed.
  """
  use Mix.Task

  @requirements ["compile"]

  @impl true
  def run(args) do
    {opts, mods} =
      OptionParser.parse!(args, strict: [
          out: :string,
          synth: :boolean,
          family: :string,
          pnr: :boolean,
          clock_mhz: :integer,
          bitstream: :boolean,
          seed: :integer
        ]
      )

    out = Keyword.get(opts, :out, "hdl/generated")

    if mods == [], do: Mix.raise("usage: mix ex_hdl.gen.sv Module... [--out dir] [--synth]")
    File.mkdir_p!(out)

    for name <- mods do
      mod = Module.concat([name])
      Code.ensure_loaded?(mod) || Mix.raise("module #{name} not found")

      packets? = function_exported?(mod, :__ex_hdl_packets__, 0)
      kernels? = function_exported?(mod, :ex_hdl_kernels, 0)
      rtl? = function_exported?(mod, :ex_hdl_rtl, 0)

      unless packets? or kernels? or rtl?,
        do:
          Mix.raise(
            "#{name} neither `use`s ExHdl.Protocol nor exports ex_hdl_kernels/0 or ex_hdl_rtl/0"
          )

      if packets? do
        for spec <- mod.__ex_hdl_packets__(),
            {file, src} <- ExHdl.Backends.SystemVerilog.Protocol.generate(spec),
            do: write(out, file, src)
      end

      if kernels?, do: Enum.each(mod.ex_hdl_kernels(), &kernel(&1, out, opts))
      if rtl?, do: Enum.each(mod.ex_hdl_rtl(), &rtl(&1, out, opts))
    end
  end

  defp rtl(%ExHdl.RTL.Module{} = top, out, opts) do
    files = ExHdl.Backends.SystemVerilog.RTL.generate(top)
    Enum.each(Enum.sort(files), fn {file, src} -> write(out, file, src) end)

    if opts[:synth] do
      case ExHdl.Synth.Yosys.utilization(files, top.name,
             family: Keyword.get(opts, :family, "xc7")
           ) do
        {:ok, u} -> Mix.shell().info("  #{top.name}: " <> summary(u))
        {:error, msg} -> Mix.shell().error("  yosys: #{msg}")
      end
    end

    if opts[:pnr], do: pnr(files, top.name, top.name, out, opts)
  end

  defp rtl(other, _out, _opts),
    do: Mix.raise("ex_hdl_rtl/0 must return ExHdl.RTL.Module structs, got #{inspect(other)}")

  defp summary(u) do
    "yosys synth_xilinx: #{u.lut} LUT, #{u.ff} FF, #{u.dsp} DSP, " <>
      "#{u.bram18} RAMB18, #{u.uram} URAM, #{u.carry} CARRY, #{u.srl} SRL, #{u.lutram} LUTRAM"
  end

  defp kernel(spec, out, opts) do
    name = Keyword.fetch!(spec, :name)
    fun = Keyword.fetch!(spec, :fun)
    args = Keyword.fetch!(spec, :args)

    case ExHdl.DSP.scan_to_sv(fun, args, Keyword.drop(spec, [:fun, :args]) ++ timing(opts)) do
      {:ok, d} ->
        write(out, "#{name}.sv", d.source)

        Mix.shell().info(
          "  latency #{d.latency}, ii #{d.ii}, channels #{d.channels}, " <>
            "tdata #{d.in_width} -> #{d.out_width} bits"
        )

        if opts[:synth], do: synth(d)
        if opts[:pnr], do: pnr(%{"#{d.name}.sv" => d.source}, d.name, name, out, opts)

      {:error, error} ->
        Mix.raise("#{name}: " <> Exception.message(error))
    end
  end

  defp synth(d) do
    case ExHdl.Synth.Yosys.utilization(%{"#{d.name}.sv" => d.source}, d.name) do
      {:ok, u} ->
        Mix.shell().info("  " <> summary(u))

      {:error, msg} ->
        Mix.shell().error("  yosys: #{msg}")
    end
  end

  defp timing(opts), do: if(opts[:clock_mhz], do: [clock_mhz: opts[:clock_mhz]], else: [])

  defp pnr(sources, top, name, out, opts) do
    mhz = Keyword.get(opts, :clock_mhz, 100)

    pnr_opts =
      [clock_mhz: mhz, bitstream: opts[:bitstream] || false] ++
        if(opts[:seed], do: [seed: opts[:seed]], else: [])

    pnr_opts =
      if opts[:bitstream], do: [workdir: Path.join(out, "#{name}_pnr")] ++ pnr_opts, else: pnr_opts

    case ExHdl.Synth.PnR.run(sources, top, pnr_opts) do
      {:ok, r} ->
        fmax = if r.fmax_mhz, do: "#{Float.round(r.fmax_mhz, 1)} MHz", else: "n/a"

        Mix.shell().info(
          "  nextpnr xc7z020: Fmax #{fmax} at target #{mhz} MHz, " <>
            "#{if r.met, do: "met", else: "NOT met"}, " <>
            Enum.map_join(r.utilization, ", ", fn {k, {u, _}} -> "#{k} #{u}" end)
        )

        if r.bitstream, do: Mix.shell().info("  bitstream #{r.bitstream}")

      {:error, msg} ->
        Mix.shell().error("  pnr: #{msg}")
    end
  end

  defp write(out, file, src) do
    path = Path.join(out, file)
    File.write!(path, src)
    Mix.shell().info("* #{path}")
  end
end
