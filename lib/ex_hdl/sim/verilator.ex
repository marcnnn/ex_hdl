defmodule ExHdl.Sim.Verilator do
  @moduledoc """
  Verilator co-simulation as an isolated OS process.

  Generated SystemVerilog is compiled together with the generic AXI4-Stream
  harness (`priv/sim/axis_harness.cpp`) into a standalone executable. Builds
  are cached by content hash, so only the first run of a design pays the C++
  compile. A simulation that crashes or deadlocks cannot take the BEAM down.
  """

  import Bitwise, only: [<<<: 2]
  alias ExHdl.Protocol.Spec

  defmodule Sim do
    @moduledoc "A compiled simulation executable for a design with an AXI4-Stream top."
    defstruct [:path, :bus_width]
  end

  @type run_opts :: [
          seed: non_neg_integer(),
          valid_pct: 1..100,
          ready_pct: 1..100,
          max_cycles: pos_integer()
        ]

  @doc "Generates, compiles and caches the `<name>_loopback` simulation for a packet spec."
  @spec build_loopback(Spec.t(), keyword()) :: {:ok, Sim.t()} | {:error, String.t()}
  def build_loopback(%Spec{} = spec, opts \\ []) do
    sources = ExHdl.Backends.SystemVerilog.Protocol.generate(spec)

    with {:ok, path} <- build(sources, "#{spec.name}_loopback", opts) do
      {:ok, %Sim{path: path, bus_width: spec.bus_width}}
    end
  end

  @doc """
  Compiles `sources` (`%{filename => sv_source}`) with the AXI4-Stream harness
  and returns the path to the executable.
  """
  @spec build(%{String.t() => String.t()}, String.t(), keyword()) ::
          {:ok, Path.t()} | {:error, String.t()}
  def build(sources, top, opts \\ []) do
    verilator = Keyword.get(opts, :verilator, System.find_executable("verilator"))
    harness = File.read!(harness_path())

    if verilator == nil do
      {:error, "verilator not found in PATH"}
    else
      hash =
        {top, harness, Enum.sort(sources)}
        |> :erlang.term_to_binary()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)

      dir = Path.join(Keyword.get_lazy(opts, :cache_dir, &default_cache_dir/0), "#{top}-#{hash}")
      exe = Path.join(dir, "sim")

      if File.exists?(exe), do: {:ok, exe}, else: compile(verilator, sources, top, dir, exe)
    end
  end

  # Builds in a scratch directory and renames it into place, so concurrent
  # builds of the same design never see a half-written cache entry.
  defp compile(verilator, sources, top, dir, exe) do
    tmp = "#{dir}.tmp-#{System.unique_integer([:positive])}"
    File.mkdir_p!(tmp)

    sv_files =
      for {name, src} <- Enum.sort(sources) do
        path = Path.join(tmp, name)
        File.write!(path, src)
        path
      end

    args =
      ~w(--cc --exe --build -j 0 -O2 -Wall --top-module #{top} --prefix Vtop) ++
        ["-Mdir", Path.join(tmp, "obj"), "-o", Path.join(tmp, "sim")] ++
        sv_files ++ [harness_path()]

    case System.cmd(verilator, args, stderr_to_stdout: true) do
      {_, 0} ->
        case File.rename(tmp, dir) do
          :ok -> :ok
          # Another build won the race; ours is identical.
          {:error, _} -> File.rm_rf!(tmp)
        end

        {:ok, exe}

      {log, status} ->
        File.rm_rf!(tmp)
        {:error, "verilator exited with #{status}:\n#{log}"}
    end
  end

  @doc """
  Streams `packets` (binaries) through the simulation with randomized input
  `tvalid` and output `tready`.

  Returns the output split into packets at `tlast`, the design's
  `dropped_packets` counter and the cycle count.
  """
  @spec run_axis(Sim.t(), [binary()], run_opts()) ::
          {:ok, %{packets: [binary()], dropped: non_neg_integer(), cycles: pos_integer()}}
          | {:error, term()}
  def run_axis(%Sim{} = sim, packets, opts \\ []) do
    bytes = div(sim.bus_width, 8)
    seed = Keyword.get(opts, :seed, :rand.uniform(1 <<< 32))
    valid_pct = Keyword.get(opts, :valid_pct, 100)
    ready_pct = Keyword.get(opts, :ready_pct, 100)
    total_beats = packets |> Enum.map(&div(byte_size(&1) + bytes - 1, bytes)) |> Enum.sum()
    max_cycles = Keyword.get(opts, :max_cycles, 1000 + total_beats * 200)

    tmp = Path.join(System.tmp_dir!(), "ex_hdl_axis_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    in_file = Path.join(tmp, "in.beats")
    out_file = Path.join(tmp, "out.beats")

    try do
      File.write!(in_file, Enum.map(packets, &packet_to_beats(&1, bytes)))

      args = [in_file, out_file, seed, valid_pct, ready_pct, max_cycles] |> Enum.map(&to_string/1)

      case System.cmd(sim.path, args, stderr_to_stdout: true) do
        {_, 0} -> {:ok, parse_output(File.read!(out_file), bytes)}
        {log, 2} -> {:error, {:cycle_limit, String.trim(log)}}
        {log, status} -> {:error, {:exit, status, log}}
      end
    after
      File.rm_rf!(tmp)
    end
  end

  @doc false
  # AXI4-Stream byte k of a packet goes to lane rem(k, bytes), i.e. the beat
  # word is the little-endian interpretation of its bytes.
  def packet_to_beats(<<>>, _bytes),
    do: raise(ArgumentError, "empty packet cannot be sent on AXI4-Stream")

  def packet_to_beats(packet, bytes) do
    chunks = for <<c::binary-size(bytes) <- pad(packet, bytes)>>, do: c
    last_len = rem(byte_size(packet) - 1, bytes) + 1
    n = length(chunks)

    chunks
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, i} ->
      keep = if i == n, do: (1 <<< last_len) - 1, else: (1 <<< bytes) - 1
      data = :binary.decode_unsigned(chunk, :little)

      [
        Integer.to_string(data, 16),
        ?\s,
        Integer.to_string(keep, 16),
        ?\s,
        if(i == n, do: ?1, else: ?0),
        ?\n
      ]
    end)
  end

  defp pad(packet, bytes) do
    case rem(byte_size(packet), bytes) do
      0 -> packet
      r -> packet <> :binary.copy(<<0>>, bytes - r)
    end
  end

  defp parse_output(text, bytes) do
    {packets, current, dropped, cycles} =
      text
      |> String.split("\n", trim: true)
      |> Enum.reduce({[], [], nil, nil}, fn line, {pkts, cur, dropped, cycles} ->
        case String.split(line, " ") do
          ["dropped", n] ->
            {pkts, cur, String.to_integer(n), cycles}

          ["cycles", n] ->
            {pkts, cur, dropped, String.to_integer(n)}

          [data, keep, last] ->
            beat = beat_bytes(String.to_integer(data, 16), String.to_integer(keep, 16), bytes)
            cur = [beat | cur]

            if last == "1",
              do: {[cur |> Enum.reverse() |> IO.iodata_to_binary() | pkts], [], dropped, cycles},
              else: {pkts, cur, dropped, cycles}
        end
      end)

    # A trailing beat sequence without tlast is reported as its own packet so
    # tests see it instead of silently losing it.
    packets =
      if current == [],
        do: packets,
        else: [{:no_tlast, current |> Enum.reverse() |> IO.iodata_to_binary()} | packets]

    %{packets: Enum.reverse(packets), dropped: dropped, cycles: cycles}
  end

  # Keeps only the lanes enabled by tkeep (null bytes are not modelled).
  defp beat_bytes(data, keep, bytes) do
    lanes = <<data::little-size(bytes * 8)>>

    for {b, lane} <- Enum.with_index(:binary.bin_to_list(lanes)),
        Bitwise.band(keep, 1 <<< lane) != 0,
        do: b
  end

  defp harness_path, do: Application.app_dir(:ex_hdl, "priv/sim/axis_harness.cpp")

  defp default_cache_dir do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get() do
      Path.join(Mix.Project.build_path(), "ex_hdl_sim")
    else
      Path.join(System.tmp_dir!(), "ex_hdl_sim")
    end
  end
end
