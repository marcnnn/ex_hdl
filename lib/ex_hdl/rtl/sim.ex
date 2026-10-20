defmodule ExHdl.RTL.Sim do
  @moduledoc """
  Cycle-accurate, deterministic BEAM simulator for `ExHdl.RTL` modules.

  The simulator is a value: every call returns a new `%Sim{}`. Time
  advances in edge events. Each top-level clock (one per distinct clock
  signal of the top's domains) has a `period` and a `phase` (time of its
  first rising edge) in abstract time units; an event is the set of
  clocks rising at the same time. At an event all registers, memories and
  models of those clocks compute their next state from the values before
  the event, then commit together; combinational logic settles after
  every event and every `poke/3`.

      sim = Sim.new(Counter.build(8))
      sim = sim |> Sim.poke(:rst_n, 0) |> Sim.step() |> Sim.poke(%{rst_n: 1, en: 1})
      sim = Sim.step(sim, 3)
      Sim.peek(sim, :q)        #=> 3

  Values are integers in the range of the signal's type (signed signals
  are negative when negative). State starts at 0 (registers, memories
  without init), like Verilator; resets are ordinary inputs the test
  drives. Asynchronous resets act as soon as they are asserted.

  Options of `new/2`:

    * `clocks:` - `[domain_or_clock: [period: p, phase: ph]]`, default
      period 10, phase 0 for every clock.
    * `trace: true` - record every settled state (`trace/1`, `vcd/2`).
    * `engine:` - `:compiled` (default) generates and loads a BEAM module
      for the design (cached by content, so a second `new/2` of the same
      design does not compile again); `:interpret` evaluates the
      expression trees directly (no compile step, much slower per cycle).

  Combinational logic settles lazily: `step/2` computes the register
  updates from the settled values, and the next `poke/3`, `peek/2` or
  `step/2` settles again, so a poke, sample, step loop settles once per
  cycle.
  """

  alias ExHdl.RTL.{Expr, Module}
  alias ExHdl.RTL.Sim.{Compiler, Flat, Interp}

  defstruct [
    :flat,
    :module,
    :engine,
    :prog,
    :st,
    :settled,
    :time,
    :next,
    :periods,
    :edges,
    :trace,
    :ports
  ]

  @type t :: %__MODULE__{}

  @doc "Builds a simulator. Raises for black boxes without a model and combinational loops."
  @spec new(Module.t(), keyword()) :: t()
  def new(%Module{} = mod, opts \\ []) do
    engine =
      case Keyword.get(opts, :engine, :compiled) do
        :compiled ->
          Compiler

        :interpret ->
          Interp

        other ->
          raise ArgumentError, "engine: must be :compiled or :interpret, got #{inspect(other)}"
      end

    {flat, prog} = build(mod, engine)
    periods = periods(flat.clocks, Keyword.get(opts, :clocks, []), flat.domain_clock)

    %__MODULE__{
      flat: flat,
      module: mod,
      engine: engine,
      prog: prog,
      st: engine.init(prog),
      settled: false,
      time: 0,
      next: Map.new(periods, fn {c, {_, ph}} -> {c, ph} end),
      periods: periods,
      edges: Map.new(periods, fn {c, _} -> {c, 0} end),
      trace: if(Keyword.get(opts, :trace, false), do: [], else: nil),
      ports: Map.new(mod.ports, &{&1.name, &1})
    }
    |> settle()
    |> record()
  end

  # Per-process cache of the last built designs. Comparing a module with
  # the cached one is cheap when they share their terms (a module built
  # once and simulated many times) and never wrong.
  @cache_size 8

  defp build(mod, engine) do
    key = {__MODULE__, :cache}
    cache = Process.get(key, [])

    case Enum.find(cache, fn {m, e, _} -> e == engine and m == mod end) do
      {_, _, built} ->
        built

      nil ->
        flat = Flat.build(mod)
        built = {flat, engine.build(flat)}
        Process.put(key, Enum.take([{mod, engine, built} | cache], @cache_size))
        built
    end
  end

  # -- inputs and outputs ----------------------------------------------------------------

  @doc "Drives a top-level input (or several from a map/keyword list) and settles."
  def poke(%__MODULE__{} = sim, name, value), do: poke(sim, [{name, value}])

  def poke(%__MODULE__{} = sim, values) do
    st =
      Enum.reduce(values, sim.st, fn {name, v}, st ->
        p = Map.get(sim.ports, name) || raise(ArgumentError, "no port #{inspect(name)}")

        if p.dir != :input or p.role == :clock,
          do:
            raise(
              ArgumentError,
              "#{name} is not a drivable input (clocks are driven by the simulator)"
            )

        v = if is_boolean(v), do: if(v, do: 1, else: 0), else: v

        unless is_integer(v) and v in Expr.range(p.type),
          do: raise(ArgumentError, "#{name}: #{inspect(v)} does not fit #{Expr.fmt(p.type)}")

        sim.engine.put(sim.prog, st, Atom.to_string(name), v)
      end)

    %{sim | st: st, settled: false} |> settle() |> record()
  end

  @doc """
  Value of a signal: a top-level port or signal as an atom, anything in
  the hierarchy as a path string (`"u_cnt.count"`).
  """
  def peek(%__MODULE__{} = sim, name) do
    id = if is_atom(name), do: Atom.to_string(name), else: name
    %{engine: eng, prog: prog} = sim = settle(sim)

    if eng.has?(prog, sim.st, id),
      do: eng.get(prog, sim.st, id),
      else: raise(ArgumentError, "no signal #{inspect(name)}")
  end

  @doc "All top-level outputs as a map."
  def outputs(%__MODULE__{} = sim) do
    %{engine: eng, prog: prog, st: st} = settle(sim)

    for p <- Module.outputs(sim.module),
        into: %{},
        do: {p.name, eng.get(prog, st, Atom.to_string(p.name))}
  end

  @doc "Word `addr` of memory `path` (e.g. `\"ram\"` or `\"u_fifo.mem\"`)."
  def peek_memory(%__MODULE__{} = sim, path, addr) do
    path = to_string(path)
    m = Map.get(sim.flat.mems, path) || raise(ArgumentError, "no memory #{path}")
    sim.engine.mem_get(sim.prog, sim.st, m.key, addr)
  end

  @doc "Current simulation time."
  def time(%__MODULE__{time: t}), do: t

  @doc "Rising edges so far of the clock of `domain` (a top-level domain name)."
  def cycles(%__MODULE__{} = sim, domain \\ nil), do: Map.fetch!(sim.edges, clock_id(sim, domain))

  defp clock_id(sim, nil), do: clock_id(sim, sim.module.default_domain)

  defp clock_id(sim, domain) do
    Map.get(sim.flat.domain_clock, domain) || raise(ArgumentError, "no domain #{inspect(domain)}")
  end

  # -- time ------------------------------------------------------------------------------

  @doc "Advances `n` edge events (default 1)."
  def step(sim, n \\ 1)
  def step(%__MODULE__{} = sim, 0), do: sim

  def step(%__MODULE__{} = sim, n) when n > 0 do
    {t, fire, next} = advance(sim.next, sim.periods, sim.time)
    sim = edge(%{sim | time: t}, fire)
    edges = Enum.reduce(fire, sim.edges, fn c, e -> Map.update!(e, c, &(&1 + 1)) end)
    step(%{sim | next: next, edges: edges}, n - 1)
  end

  # Without clocks an event is just a sample point. `fire` is a sorted list.
  defp advance(next, _periods, now) when map_size(next) == 0, do: {now, [], next}

  defp advance(next, periods, _now) when map_size(next) == 1 do
    [{c, t}] = Map.to_list(next)
    {t, [c], %{c => t + elem(Map.fetch!(periods, c), 0)}}
  end

  defp advance(next, periods, _now) do
    t = next |> Map.values() |> Enum.min()
    fire = for {c, ^t} <- next, do: c

    {t, Enum.sort(fire),
     Map.new(next, fn {c, tn} -> {c, if(tn == t, do: tn + elem(periods[c], 0), else: tn)} end)}
  end

  @doc """
  The first `n` events for a module's clocks (`clocks:` as in `new/2`):
  `[{time, [clock_name]}]`. `ExHdl.RTL.Cosim` drives Verilator with it.
  """
  def schedule(%Module{} = mod, n, opts \\ []) do
    periods =
      periods(Flat.clock_ids(mod), Keyword.get(opts, :clocks, []), Flat.domain_clocks(mod))

    next = Map.new(periods, fn {c, {_, ph}} -> {c, ph} end)

    {events, _} =
      Enum.map_reduce(1..n//1, next, fn _, next ->
        {t, fire, next} = advance(next, periods, 0)
        {{t, Enum.map(fire, &String.to_atom/1)}, next}
      end)

    events
  end

  @doc false
  # %{clock name => {period, phase}} for the top-level clocks of `mod`
  def clock_periods(%Module{} = mod, opts \\ []),
    do: periods(Flat.clock_ids(mod), Keyword.get(opts, :clocks, []), Flat.domain_clocks(mod))

  defp periods(clock_ids, clock_opts, domain_clock) do
    Map.new(clock_ids, fn cid ->
      by_domain =
        Enum.find_value(domain_clock, nil, fn {d, c} ->
          if c == cid, do: Keyword.get(clock_opts, d)
        end)

      o = Keyword.get(clock_opts, String.to_atom(cid)) || by_domain || []
      period = Keyword.get(o, :period, 10)
      phase = Keyword.get(o, :phase, 0)

      unless is_integer(period) and period > 0 and is_integer(phase) and phase >= 0,
        do:
          raise(
            ArgumentError,
            "clock #{cid}: period must be a positive and phase a non-negative integer"
          )

      {cid, {period, phase}}
    end)
  end

  @doc "Advances until the clock of `domain` has risen `n` more times."
  def cycle(%__MODULE__{} = sim, domain \\ nil, n \\ 1) do
    c = clock_id(sim, domain)
    target = sim.edges[c] + n
    Stream.iterate(sim, &step/1) |> Enum.find(&(&1.edges[c] >= target))
  end

  @doc "The clocks rising at the next event (top-level clock names)."
  def next_edges(%__MODULE__{next: next, periods: periods, time: now}) do
    {_, fire, _} = advance(next, periods, now)
    Enum.map(fire, &String.to_atom/1)
  end

  @doc """
  Holds every top-level reset asserted for `cycles` events, then releases
  them (inputs other than resets keep their values).
  """
  def reset(%__MODULE__{} = sim, cycles \\ 2) do
    sim = poke(sim, reset_inputs(sim.module, :asserted))
    sim = step(sim, cycles)
    poke(sim, reset_inputs(sim.module, :released))
  end

  @doc """
  The top-level reset ports of `mod` with their asserted (or released)
  levels, e.g. `%{rst_n: 0}`; empty for a module without registers or
  resets. Testbenches merge it into their input maps instead of poking
  `rst_n` by name.
  """
  @spec reset_inputs(Module.t(), :asserted | :released) :: %{atom() => 0 | 1}
  def reset_inputs(%Module{} = mod, state \\ :asserted) when state in [:asserted, :released] do
    for d <- mod.domains, d.reset && d.reset_port, into: %{} do
      on = if d.reset_active == :low, do: 0, else: 1
      {hd(d.reset.args), if(state == :asserted, do: on, else: 1 - on)}
    end
  end

  @doc """
  Runs a stimulus: for each element (a map or keyword list of inputs),
  pokes it, samples all outputs, then advances one event. Returns
  `{sim, samples}` with one output map per element.
  """
  def run(%__MODULE__{} = sim, stimulus) do
    {samples, sim} =
      Enum.map_reduce(stimulus, sim, fn inputs, sim ->
        sim = poke(sim, inputs)
        {outputs(sim), step(sim)}
      end)

    {sim, samples}
  end

  # -- evaluation ------------------------------------------------------------------------

  defp settle(%{settled: true} = sim), do: sim

  defp settle(%{engine: eng, prog: prog, st: st} = sim),
    do: %{sim | st: eng.settle(prog, st), settled: true}

  defp edge(sim, fire) do
    %{engine: eng, prog: prog, st: st} = sim = settle(sim)
    sim = %{sim | st: eng.edge(prog, st, fire), settled: false}
    if sim.trace, do: sim |> settle() |> record(fire), else: sim
  end

  # -- tracing ---------------------------------------------------------------------------

  defp record(sim, fire \\ [])
  defp record(%{trace: nil} = sim, _fire), do: sim

  defp record(sim, fire) do
    %{engine: eng, prog: prog, st: st} = sim = settle(sim)

    snapshot =
      for {id, %{kind: k}} <- sim.flat.sigs,
          k != :clock,
          into: %{},
          do: {id, eng.get(prog, st, id)}

    %{sim | trace: [{sim.time, fire, snapshot} | sim.trace]}
  end

  @doc "Recorded `{time, rising_clocks, %{signal => value}}` entries, oldest first (needs `trace: true`)."
  def trace(%__MODULE__{trace: nil}),
    do: raise(ArgumentError, "start the simulator with trace: true")

  def trace(%__MODULE__{trace: t}), do: Enum.reverse(t)

  @doc "The trace as a VCD document (iodata). Options: `timescale:` (default `\"1ns\"`)."
  def vcd(%__MODULE__{} = sim, opts \\ []), do: ExHdl.RTL.Sim.VCD.render(sim, opts)

  @doc "Writes the trace as a VCD file."
  def write_vcd(%__MODULE__{} = sim, path, opts \\ []), do: File.write!(path, vcd(sim, opts))
end
