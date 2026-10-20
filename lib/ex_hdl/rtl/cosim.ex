defmodule ExHdl.RTL.Cosim do
  @moduledoc """
  Port-level Verilator co-simulation of any `ExHdl.RTL` module, and the
  cycle-exact comparison with the BEAM simulator (`ExHdl.RTL.Sim`).

  A stimulus is a list with one element per event (for single-clock
  designs: per cycle), each a map or keyword list of input values; inputs
  not mentioned keep their previous value (0 at the start). For every
  event the harness applies the inputs, records all outputs, then raises
  the clocks of that event (`ExHdl.RTL.Sim.schedule/3`), exactly as
  `ExHdl.RTL.Sim.run/2` does.

      {:ok, cosim} = Cosim.build(Counter.build(8))
      {:ok, samples} = Cosim.run(cosim, [%{rst_n: 0}, %{rst_n: 1, en: 1}, %{}, %{}])
      Cosim.assert_equivalent(Counter.build(8), stimulus)

  `check_model/4` and `check_trace/4` compare a module against an Elixir
  step function or a recorded output trace, in either simulator, and
  report the first mismatch with the preceding inputs. Ports of any
  width work (values above 64 bits travel as `VlWide` words).

  The harness C++ is generated per module (port list compiled in) and
  built through `ExHdl.Sim.Verilator.build/3`, so builds are cached by
  content hash. The design must lint clean under `-Wall`, black boxes
  need `sources:`.

  ## Closed loop

  `open/2` starts an interactive Verilator simulation
  (`ExHdl.RTL.Cosim.Session`) with the API of `ExHdl.RTL.Sim`, for
  testbenches whose next inputs depend on the outputs (AXI4-Stream
  `tready`, network models, servo loops):

      {:ok, s} = Cosim.open(mod)
      s = Cosim.poke(s, %{rst_n: 1, s_tvalid: 1})
      ready = Cosim.peek(s, :s_tready)
      s = Cosim.step(s)
      Cosim.close(s)

  `ExHdl.RTL.Bench` runs agent-based testbenches on either simulator.

  ## Internal clocks

  The BEAM simulator drives every top-level domain clock ideally, also
  when the domain has `clock_port: false` and its clock wire is driven by
  an MMCM or BUFG black box. Co-simulation does the same: such clocks
  become top-level inputs of the harness (`substitute_clocks/1`), driven
  with the periods of `clocks:`, and the black box's clock output is left
  unread. Internal clocks of child modules are not supported; generate
  them in the top level. `vcd:` writes a Verilator VCD of a run (see
  `ExHdl.RTL.Cosim.Session`), `flags:` passes Verilator options such as
  `["-O3"]`.
  """

  import Bitwise

  alias ExHdl.Backends.SystemVerilog.RTL, as: SV
  alias ExHdl.RTL.{Expr, Module, Sim}

  defstruct [:module, :path, :inputs, :outputs, :clocks]

  @type t :: %__MODULE__{}

  @doc "Generates SV and harness, compiles (cached). Options go to `ExHdl.Sim.Verilator.build/3`."
  @spec build(Module.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def build(%Module{} = mod, opts \\ []) do
    with {:ok, mod, extra_flags} <- prepare(mod) do
      clocks = for p <- mod.ports, p.role == :clock, do: p.name
      opts = Keyword.update(opts, :flags, extra_flags, &(&1 ++ extra_flags))
      inputs = for p <- mod.ports, p.dir == :input, p.role != :clock, do: p
      outputs = Module.outputs(mod)
      harness = harness(mod.name, inputs, outputs, clocks)
      dir = Keyword.get_lazy(opts, :cache_dir, &cache_dir/0)
      opts = Keyword.drop(opts, [:vcd, :vcd_timescale])
      File.mkdir_p!(dir)
      hash = :crypto.hash(:sha256, harness) |> Base.encode16(case: :lower) |> binary_part(0, 16)
      path = Path.join(dir, "rtl_harness_#{mod.name}_#{hash}.cpp")
      unless File.exists?(path), do: File.write!(path, harness)

      opts = opts |> Keyword.put(:harness, path) |> Keyword.put_new(:cache_dir, dir)

      with {:ok, exe} <- ExHdl.Sim.Verilator.build(SV.generate(mod, sim: true), mod.name, opts) do
        {:ok,
         %__MODULE__{module: mod, path: exe, inputs: inputs, outputs: outputs, clocks: clocks}}
      end
    end
  end

  @doc """
  Runs `stimulus` (see the moduledoc) and returns one map of output values
  per event. Options: `clocks:` as in `ExHdl.RTL.Sim.new/2`.
  """
  @spec run(t(), [map() | keyword()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def run(c, stimulus, opts \\ [])

  def run(%__MODULE__{} = c, stimulus, opts) do
    if opts[:vcd], do: run_session(c, stimulus, opts), else: run_file(c, stimulus, opts)
  end

  # a replay with a VCD runs through a session built with --trace
  defp run_session(c, stimulus, opts) do
    with {:ok, s} <- ExHdl.RTL.Cosim.Session.open(c.module, opts) do
      try do
        {_, samples} = ExHdl.RTL.Cosim.Session.run(s, stimulus)
        {:ok, samples}
      after
        ExHdl.RTL.Cosim.Session.close(s)
      end
    end
  end

  defp run_file(c, stimulus, opts) do
    events = Sim.schedule(c.module, length(stimulus), opts)
    bit = c.clocks |> Enum.with_index() |> Map.new(fn {n, i} -> {n, 1 <<< i} end)

    {lines, _} =
      stimulus
      |> Enum.zip(events)
      |> Enum.map_reduce(Map.new(c.inputs, &{&1.name, 0}), fn {inputs, {_t, fire}}, cur ->
        cur =
          Enum.reduce(inputs, cur, fn {k, v}, cur ->
            p =
              Enum.find(c.inputs, &(&1.name == k)) ||
                raise ArgumentError, "no input #{inspect(k)}"

            v = if is_boolean(v), do: if(v, do: 1, else: 0), else: v

            unless is_integer(v) and v in Expr.range(p.type),
              do: raise(ArgumentError, "#{k}: #{inspect(v)} does not fit #{Expr.fmt(p.type)}")

            Map.put(cur, k, v)
          end)

        mask = fire |> Enum.map(&Map.get(bit, &1, 0)) |> Enum.reduce(0, &bor/2)
        vals = Enum.map(c.inputs, &hex(Expr.raw(cur[&1.name], &1.type)))
        {[Integer.to_string(mask, 16), " ", Enum.join(vals, " "), "\n"], cur}
      end)

    tmp = Path.join(System.tmp_dir!(), "ex_hdl_rtl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    in_file = Path.join(tmp, "in.vec")
    out_file = Path.join(tmp, "out.vec")

    try do
      File.write!(in_file, lines)

      case System.cmd(c.path, [in_file, out_file], stderr_to_stdout: true) do
        {_, 0} -> {:ok, parse(File.read!(out_file), c.outputs)}
        {log, status} -> {:error, {:exit, status, log}}
      end
    after
      File.rm_rf!(tmp)
    end
  end

  defp hex(v), do: Integer.to_string(v, 16)

  defp parse(text, outputs) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      line
      |> String.split(" ", trim: true)
      |> Enum.zip(outputs)
      |> Map.new(fn {h, p} -> {p.name, Expr.wrap(String.to_integer(h, 16), p.type)} end)
    end)
  end

  @doc """
  Runs `stimulus` in the BEAM simulator and in Verilator. Returns `:ok`,
  `{:mismatch, event, port, beam, verilator}` for the first difference,
  or `{:error, reason}` if the Verilator build or run fails.
  """
  @spec compare(Module.t(), [map() | keyword()], keyword()) ::
          :ok | {:mismatch, non_neg_integer(), atom(), integer(), integer()} | {:error, term()}
  def compare(%Module{} = mod, stimulus, opts \\ []) do
    {_sim, beam} = mod |> Sim.new(Keyword.take(opts, [:clocks])) |> Sim.run(stimulus)

    with {:ok, c} <- build(mod, Keyword.drop(opts, [:clocks, :vcd, :vcd_timescale])),
         {:ok, rtl} <- run(c, stimulus, opts) do
      first_mismatch(beam, rtl, Module.outputs(mod))
    end
  end

  defp first_mismatch(beam, rtl, outputs) do
    if length(beam) != length(rtl) do
      {:error, {:length, length(beam), length(rtl)}}
    else
      beam
      |> Enum.zip(rtl)
      |> Enum.with_index()
      |> Enum.find_value(:ok, fn {{b, r}, i} ->
        Enum.find_value(outputs, fn p ->
          if b[p.name] != r[p.name], do: {:mismatch, i, p.name, b[p.name], r[p.name]}
        end)
      end)
    end
  end

  @doc """
  ExUnit assertion: `compare/3` must return `:ok`. On a mismatch the
  message names the event, the port and both values.
  """
  def assert_equivalent(%Module{} = mod, stimulus, opts \\ []) do
    case compare(mod, stimulus, opts) do
      :ok ->
        :ok

      {:mismatch, i, port, b, r} ->
        raise ExUnit.AssertionError,
          message:
            "#{mod.name}: BEAM simulator and Verilator differ at event #{i}, output #{port}: " <>
              "beam #{b}, verilator #{r}\ninputs: #{inspect(Enum.at(stimulus, i))}"

      {:error, reason} ->
        raise ExUnit.AssertionError,
          message: "#{mod.name}: co-simulation failed: #{inspect(reason)}"
    end
  end

  # -- reference models ------------------------------------------------------------------

  @doc """
  Compares a module cycle by cycle against a reference model.

  `model` is `{state, step}` with `step.(state, inputs) -> {state,
  outputs}`. For every event of `stimulus` the step function gets the map
  of all input values at that event (data inputs and resets, held values
  included, booleans as 0/1) and returns the expected outputs of that
  event: a map of output port => value, `nil` or a missing key meaning
  "don't care". Outputs are sampled as in `ExHdl.RTL.Sim.run/2`: after the
  inputs are applied, before the clock edge, so a model with registered
  outputs returns the value from its state before the update (Mealy
  outputs see the current inputs).

  Options:

    * `backend:` `:beam` (default), `:verilator` or `:both`.
    * `latency:` the RTL output of event `i + latency` is compared with the
      model's output for event `i` (default 0); the last `latency` model
      outputs are not compared.
    * `history:` input cycles shown in a mismatch report (default 8).
    * `clocks:` as in `ExHdl.RTL.Sim.new/2`; other options go to `build/2`.

  Returns `:ok`, `{:mismatch, %ExHdl.RTL.Cosim.Mismatch{}}` for the first
  differing event, or `{:error, reason}` when Verilator fails.

      model = {0, fn count, %{en: en} -> {count + en &&& 255, %{count: count}} end}
      :ok = Cosim.check_model(Counter.build(8), stimulus, model, backend: :both)
  """
  @spec check_model(Module.t(), [map() | keyword()], {term(), function()}, keyword()) ::
          :ok | {:mismatch, ExHdl.RTL.Cosim.Mismatch.t()} | {:error, term()}
  def check_model(%Module{} = mod, stimulus, {state, step}, opts \\ [])
      when is_function(step, 2) do
    inputs = full_inputs(mod, stimulus)
    check_trace(mod, stimulus, model_outputs(inputs, state, step), opts)
  end

  @doc """
  Like `check_model/4` with a recorded trace: `expected` has one map of
  expected outputs (`nil` = don't care) per stimulus event.
  """
  @spec check_trace(Module.t(), [map() | keyword()], [map() | keyword()], keyword()) ::
          :ok | {:mismatch, ExHdl.RTL.Cosim.Mismatch.t()} | {:error, term()}
  def check_trace(%Module{} = mod, stimulus, expected, opts \\ []) do
    inputs = full_inputs(mod, stimulus)
    expected = Enum.map(expected, &normalize_expected(mod, Map.new(&1)))
    latency = Keyword.get(opts, :latency, 0)

    backends =
      case Keyword.get(opts, :backend, :beam) do
        :both -> [:beam, :verilator]
        b when b in [:beam, :verilator] -> [b]
      end

    Enum.reduce_while(backends, :ok, fn backend, :ok ->
      case actual_outputs(backend, mod, stimulus, opts) do
        {:ok, actual} ->
          case first_model_mismatch(expected, actual, latency) do
            nil ->
              {:cont, :ok}

            {j, diffs} ->
              {:halt,
               {:mismatch,
                ExHdl.RTL.Cosim.Mismatch.new(
                  mod.name,
                  backend,
                  j,
                  latency,
                  diffs,
                  history(inputs, expected, actual, j, latency, Keyword.get(opts, :history, 8))
                )}}
          end

        {:error, _} = e ->
          {:halt, e}
      end
    end)
  end

  @doc "ExUnit assertion for `check_model/4`; the failure message is the mismatch report."
  def assert_model(%Module{} = mod, stimulus, model, opts \\ []),
    do: assert_ok(mod, check_model(mod, stimulus, model, opts))

  @doc "ExUnit assertion for `check_trace/4`."
  def assert_trace(%Module{} = mod, stimulus, expected, opts \\ []),
    do: assert_ok(mod, check_trace(mod, stimulus, expected, opts))

  defp assert_ok(_mod, :ok), do: :ok

  defp assert_ok(_mod, {:mismatch, m}),
    do: raise(ExUnit.AssertionError, message: ExHdl.RTL.Cosim.Mismatch.message(m))

  defp assert_ok(mod, {:error, reason}),
    do:
      raise(ExUnit.AssertionError,
        message: "#{mod.name}: co-simulation failed: #{inspect(reason)}"
      )

  @doc """
  The input map of every event of `stimulus` with held values filled in
  (all non-clock inputs, 0 before their first assignment).
  """
  @spec full_inputs(Module.t(), [map() | keyword()]) :: [map()]
  def full_inputs(%Module{} = mod, stimulus) do
    start = for p <- mod.ports, p.dir == :input, p.role != :clock, into: %{}, do: {p.name, 0}

    {list, _} =
      Enum.map_reduce(stimulus, start, fn ins, cur ->
        cur =
          Enum.reduce(ins, cur, fn {k, v}, cur ->
            unless Map.has_key?(cur, k), do: raise(ArgumentError, "no input #{inspect(k)}")
            Map.put(cur, k, if(is_boolean(v), do: if(v, do: 1, else: 0), else: v))
          end)

        {cur, cur}
      end)

    list
  end

  @doc "Runs a step-function model over full input maps (`full_inputs/2`); returns its outputs."
  @spec model_outputs([map()], term(), function()) :: [map()]
  def model_outputs(inputs, state, step) do
    {outs, _} =
      Enum.map_reduce(inputs, state, fn ins, st ->
        case step.(st, ins) do
          {st, out} when is_map(out) or is_list(out) ->
            {Map.new(out), st}

          other ->
            raise ArgumentError, "model step must return {state, outputs}, got #{inspect(other)}"
        end
      end)

    outs
  end

  defp normalize_expected(mod, exp) do
    Map.new(exp, fn {port, v} ->
      p =
        Enum.find(Module.outputs(mod), &(&1.name == port)) ||
          raise ArgumentError, "#{mod.name} has no output #{inspect(port)}"

      v =
        case v do
          nil ->
            nil

          true ->
            1

          false ->
            0

          v when is_integer(v) ->
            if v in Expr.range(p.type), do: v, else: raw_or(v, p.type)

          other ->
            raise ArgumentError, "#{port}: expected value #{inspect(other)} is not an integer"
        end

      {port, v}
    end)
  end

  # Signed ports accept their raw bit pattern from models.
  defp raw_or(v, {:s, w} = t) when v >= 0 and v < 1 <<< w, do: Expr.wrap(v, t)
  defp raw_or(v, _t), do: v

  defp actual_outputs(:beam, mod, stimulus, opts) do
    {_sim, out} = mod |> Sim.new(Keyword.take(opts, [:clocks])) |> Sim.run(stimulus)
    {:ok, out}
  end

  defp actual_outputs(:verilator, mod, stimulus, opts) do
    build_opts = Keyword.drop(opts, [:clocks, :backend, :latency, :history, :vcd, :vcd_timescale])

    with {:ok, c} <- build(mod, build_opts),
         do:
           run(
             c,
             stimulus,
             Keyword.take(opts, [:clocks, :vcd, :vcd_timescale, :flags, :cache_dir])
           )
  end

  defp first_model_mismatch(expected, actual, latency) do
    expected
    |> Enum.with_index()
    |> Enum.find_value(fn {exp, i} ->
      j = i + latency
      act = Enum.at(actual, j)

      diffs =
        if act,
          do: for({p, v} <- exp, v != nil, act[p] != v, do: {p, v, act[p]}),
          else: []

      if diffs != [], do: {j, Enum.sort(diffs)}
    end)
  end

  defp history(inputs, expected, actual, j, latency, n) do
    for k <- max(j - n + 1, 0)..j//1 do
      exp = if k - latency >= 0, do: Enum.at(expected, k - latency), else: %{}
      act = Enum.at(actual, k)
      outs = for {p, v} <- exp, v != nil, do: {p, v, act[p]}
      {k, Enum.at(inputs, k), Enum.sort(outs)}
    end
  end

  # -- harness ---------------------------------------------------------------------------

  defp harness(name, inputs, outputs, clocks) do
    sets =
      Enum.map(inputs, fn p -> "    set_port(top->#{p.name}, #{Expr.width(p.type)}, tok());\n" end)

    gets =
      Enum.map(outputs, fn p ->
        "    print_port(out, top->#{p.name}, #{Expr.width(p.type)});\n"
      end)

    {rise, fall} =
      clocks
      |> Enum.with_index()
      |> Enum.map(fn {c, i} ->
        {"    if (mask & (1ull << #{i})) top->#{c} = 1;\n", "    top->#{c} = 0;\n"}
      end)
      |> Enum.unzip()

    init = Enum.map(clocks, &"  top->#{&1} = 0;\n")

    """
    // Generated by ExHdl.RTL.Cosim for module #{name}. Do not edit.
    //
    // usage: sim <in.vec> <out.vec>
    // Each input line: "<clock mask hex> <input hex>..." (inputs in port order).
    // For each line: apply inputs, eval, print outputs (hex, port order),
    // raise the clocks in the mask, eval, lower them, eval.
    #include <cstdint>
    #include <cstdio>
    #include <cstdlib>
    #include <cstring>
    #include <memory>
    #include <string>
    #include <type_traits>
    #include <vector>

    #include "Vtop.h"
    #include "verilated.h"

    static std::vector<std::string> toks;
    static size_t tok_i = 0;
    static const std::string& tok() { return toks.at(tok_i++); }

    // Hex string to little-endian 32-bit words.
    static std::vector<uint32_t> words(const std::string& hex, int width) {
        std::vector<uint32_t> w((width + 31) / 32, 0);
        size_t n = 0;
        for (size_t end = hex.size(); end > 0 && n < w.size(); n++) {
            size_t start = end >= 8 ? end - 8 : 0;
            w[n] = (uint32_t)std::strtoul(hex.substr(start, end - start).c_str(), nullptr, 16);
            end = start;
        }
        return w;
    }

    template <typename T>
    static void set_port(T& port, int width, const std::string& hex) {
        if constexpr (std::is_integral<T>::value) {
            port = (T)std::strtoull(hex.c_str(), nullptr, 16);
        } else {
            std::vector<uint32_t> w = words(hex, width);
            for (size_t i = 0; i < w.size(); i++) port[i] = w[i];
        }
    }

    template <typename T>
    static void print_port(std::FILE* out, const T& port, int width) {
        if constexpr (std::is_integral<T>::value) {
            unsigned long long v = (unsigned long long)port;
            if (width < 64) v &= (1ull << width) - 1;
            std::fprintf(out, "%llx ", v);
        } else {
            int n = (width + 31) / 32;
            for (int i = n - 1; i >= 0; i--) {
                uint32_t v = port[i];
                if (i == n - 1 && width % 32) v &= (1u << (width % 32)) - 1;
                std::fprintf(out, "%08x", v);
            }
            std::fprintf(out, " ");
        }
    }

    int main(int argc, char** argv) {
        if (argc != 3) { std::fprintf(stderr, "usage: %s in out\\n", argv[0]); return 1; }
        std::FILE* in = std::fopen(argv[1], "r");
        if (!in) { std::perror(argv[1]); return 1; }
        std::FILE* out = std::fopen(argv[2], "w");
        if (!out) { std::perror(argv[2]); return 1; }

        auto ctx = std::make_unique<VerilatedContext>();
        auto top = std::make_unique<Vtop>(ctx.get());
    #{init}  top->eval();

        static char line[1 << 20];
        while (std::fgets(line, sizeof line, in)) {
            toks.clear();
            tok_i = 0;
            for (char* t = std::strtok(line, " \\n"); t; t = std::strtok(nullptr, " \\n")) toks.emplace_back(t);
            if (toks.empty()) continue;
            unsigned long long mask = std::strtoull(tok().c_str(), nullptr, 16);
            (void)mask;
    #{sets}    top->eval();
    #{gets}    std::fprintf(out, "\\n");
    #{rise}    top->eval();
    #{fall}    top->eval();
        }

        std::fclose(in);
        std::fclose(out);
        top->final();
        return 0;
    }
    """
  end

  # -- sessions --------------------------------------------------------------------------

  alias ExHdl.RTL.Cosim.Session

  @doc "Starts an interactive Verilator simulation; see `ExHdl.RTL.Cosim.Session`."
  defdelegate open(mod, opts \\ []), to: Session

  @doc "`ExHdl.RTL.Cosim.Session.poke/3`."
  defdelegate poke(session, name, value), to: Session

  @doc "`ExHdl.RTL.Cosim.Session.poke/2`."
  defdelegate poke(session, values), to: Session

  @doc "`ExHdl.RTL.Cosim.Session.peek/2`."
  defdelegate peek(session, name), to: Session

  @doc "`ExHdl.RTL.Cosim.Session.outputs/1`."
  defdelegate outputs(session), to: Session

  @doc "`ExHdl.RTL.Cosim.Session.step/2`."
  defdelegate step(session, n \\ 1), to: Session

  @doc "`ExHdl.RTL.Cosim.Session.close/1`."
  defdelegate close(session), to: Session

  # -- internal clocks ---------------------------------------------------------------------

  @doc """
  The module with every top-level internal clock (`domain(..., clock_port:
  false)`) turned into a clock input port, its driver removed: what the
  co-simulation harness runs. Raises for internal clocks in child modules.
  """
  @spec substitute_clocks(Module.t()) :: Module.t()
  def substitute_clocks(%Module{} = m) do
    for child <- Module.hierarchy(m),
        child != m,
        child.kind == :module,
        d <- child.domains,
        not d.clock_port do
      raise ArgumentError,
            "co-simulation drives top-level clocks only; #{child.name} generates clock " <>
              "#{hd(d.clock.args)} (domain #{d.name}) internally, move it to the top level"
    end

    names = for d <- m.domains, not d.clock_port, uniq: true, do: hd(d.clock.args)

    if names == [] do
      m
    else
      %{
        m
        | signals:
            Enum.reduce(names, m.signals, fn n, s ->
              Map.update!(s, n, &%{&1 | kind: :clock, port: :input})
            end),
          ports:
            m.ports ++
              for(
                n <- names,
                do: %{name: n, type: {:u, 1}, domain: nil, dir: :input, role: :clock}
              ),
          comb: Enum.reject(m.comb, fn {t, _} -> t in names end),
          domains:
            Enum.map(m.domains, fn d ->
              if hd(d.clock.args) in names, do: %{d | clock_port: true}, else: d
            end)
      }
    end
  end

  @doc false
  # {:ok, module for the harness, extra Verilator flags} | {:error, reason}
  def prepare(%Module{} = m) do
    sub = substitute_clocks(m)
    # the black box clock output that drove a substituted clock is unread
    {:ok, sub, if(sub == m, do: [], else: ["-Wno-UNUSEDSIGNAL"])}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  @doc false
  def cache_dir do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get() do
      Path.join(Mix.Project.build_path(), "ex_hdl_sim")
    else
      Path.join(System.tmp_dir!(), "ex_hdl_sim")
    end
  end
end
