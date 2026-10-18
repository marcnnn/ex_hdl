defmodule Mix.Tasks.ExHdl.Gen.Sv do
  @shortdoc "Writes SystemVerilog for all defpackets of a module"
  @moduledoc """
      mix ex_hdl.gen.sv MySDR.Protocol [--out hdl/generated]

  Writes `<packet>_parser.sv`, `<packet>_emitter.sv` and `<packet>_loopback.sv`
  for every `defpacket` in the module.
  """
  use Mix.Task

  @requirements ["compile"]

  @impl true
  def run(args) do
    {opts, mods} = OptionParser.parse!(args, strict: [out: :string])
    out = Keyword.get(opts, :out, "hdl/generated")

    if mods == [], do: Mix.raise("usage: mix ex_hdl.gen.sv Module [--out dir]")
    File.mkdir_p!(out)

    for name <- mods do
      mod = Module.concat([name])

      unless Code.ensure_loaded?(mod) and function_exported?(mod, :__ex_hdl_packets__, 0),
        do: Mix.raise("#{name} does not `use ExHdl.Protocol`")

      for spec <- mod.__ex_hdl_packets__(),
          {file, src} <- ExHdl.Backends.SystemVerilog.Protocol.generate(spec) do
        path = Path.join(out, file)
        File.write!(path, src)
        Mix.shell().info("* #{path}")
      end
    end
  end
end
