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
  """

  import Bitwise

  alias ExHdl.RTL.{Expr, Module}
  alias ExHdl.RTL.Sim.Flat

  defstruct [:flat, :module, :vals, :time, :next, :periods, :edges, :trace, :ports]

  @type t :: %__MODULE__{}

  @doc "Builds a simulator. Raises for black boxes without a model and combinational loops."
  @spec new(Module.t(), keyword()) :: t()
  def new(%Module{} = mod, opts \\ []) do
    flat = Flat.build(mod)
    periods = periods(flat.clocks, Keyword.get(opts, :clocks, []), flat.domain_clock)

    vals =
      Map.new(flat.sigs, fn {id, _} -> {id, 0} end)
      |> then(fn v ->
        Enum.reduce(flat.mems, v, fn {_, m}, v -> Map.put(v, m.key, m.init) end)
      end)
      |> then(fn v -> Enum.reduce(flat.models, v, fn m, v -> Map.put(v, m.key, m.init) end) end)

    %__MODULE__{
      flat: flat,
      module: mod,
      vals: vals,
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

  # -- inputs and outputs ----------------------------------------------------------------

  @doc "Drives a top-level input (or several from a map/keyword list) and settles."
  def poke(%__MODULE__{} = sim, name, value), do: poke(sim, [{name, value}])

  def poke(%__MODULE__{} = sim, values) do
    vals =
      Enum.reduce(values, sim.vals, fn {name, v}, vals ->
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

        Map.put(vals, Atom.to_string(name), v)
      end)

    %{sim | vals: vals} |> settle() |> record()
  end

  @doc """
  Value of a signal: a top-level port or signal as an atom, anything in
  the hierarchy as a path string (`"u_cnt.count"`).
  """
  def peek(%__MODULE__{vals: vals}, name) do
    id = if is_atom(name), do: Atom.to_string(name), else: name

    case vals do
      %{^id => v} -> v
      _ -> raise ArgumentError, "no signal #{inspect(name)}"
    end
  end

  @doc "All top-level outputs as a map."
  def outputs(%__MODULE__{} = sim),
    do: for(p <- Module.outputs(sim.module), into: %{}, do: {p.name, peek(sim, p.name)})

  @doc "Word `addr` of memory `path` (e.g. `\"ram\"` or `\"u_fifo.mem\"`)."
  def peek_memory(%__MODULE__{} = sim, path, addr) do
    path = to_string(path)
    m = Map.get(sim.flat.mems, path) || raise(ArgumentError, "no memory #{path}")
    Flat.mem_get(sim.vals, m.key, addr)
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
    edges = Map.new(sim.edges, fn {c, e} -> {c, if(c in fire, do: e + 1, else: e)} end)
    step(%{sim | next: next, edges: edges}, n - 1)
  end

  # Without clocks an event is just a sample point.
  defp advance(next, _periods, now) when map_size(next) == 0, do: {now, MapSet.new(), next}

  defp advance(next, periods, _now) do
    t = next |> Map.values() |> Enum.min()
    fire = for {c, ^t} <- next, into: MapSet.new(), do: c

    {t, fire,
     Map.new(next, fn {c, tn} -> {c, if(c in fire, do: tn + elem(periods[c], 0), else: tn)} end)}
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
        {{t, fire |> Enum.sort() |> Enum.map(&String.to_atom/1)}, next}
      end)

    events
  end

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
    fire |> Enum.sort() |> Enum.map(&String.to_atom/1)
  end

  @doc """
  Holds every top-level reset asserted for `cycles` events, then releases
  them (inputs other than resets keep their values).
  """
  def reset(%__MODULE__{} = sim, cycles \\ 2) do
    resets =
      for d <- sim.module.domains, d.reset && d.reset_port, uniq: true do
        {hd(d.reset.args), if(d.reset_active == :low, do: 0, else: 1)}
      end

    sim = poke(sim, resets)
    sim = step(sim, cycles)
    poke(sim, Enum.map(resets, fn {r, v} -> {r, 1 - v} end))
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

  defp settle(%{flat: flat} = sim) do
    vals = Enum.reduce(flat.nodes, sim.vals, fn n, v -> n.run.(v) end)
    %{sim | vals: vals} |> async_resets(10)
  end

  defp async_resets(_sim, 0), do: raise(ArgumentError, "asynchronous resets do not settle")

  defp async_resets(%{flat: flat, vals: vals} = sim, budget) do
    forced =
      Enum.reduce(flat.async_resets, vals, fn r, v ->
        if Map.fetch!(v, r.reset) == r.level,
          do: Enum.reduce(r.regs, v, fn {id, rv}, v -> Map.put(v, id, rv) end),
          else: v
      end)

    if forced == vals do
      sim
    else
      vals = Enum.reduce(flat.nodes, forced, fn n, v -> n.run.(v) end)
      async_resets(%{sim | vals: vals}, budget - 1)
    end
  end

  defp edge(%{flat: flat, vals: vals} = sim, fire) do
    regs =
      for g <- flat.sync, g.clock in fire, reduce: %{} do
        acc ->
          next = g.run.(vals)

          next =
            case g.reset do
              {rst, level} ->
                if Map.fetch!(vals, rst) == level,
                  do: Enum.reduce(g.resets, next, fn {id, v}, n -> Map.put(n, id, v) end),
                  else: next

              nil ->
                next
            end

          Map.merge(acc, next)
      end

    writes = for w <- flat.mem_writes, w.clock in fire, x = w.run.(vals), x != nil, do: x
    reads = for r <- flat.mem_reads, r.clock in fire, x = r.run.(vals), x != nil, into: %{}, do: x

    models =
      for m <- flat.models, {c, d} <- m.clocks, c in fire, reduce: %{} do
        acc ->
          state = Map.get(acc, m.key, Map.fetch!(vals, m.key))
          ins = Map.new(m.inputs, fn {p, i} -> {p, Map.fetch!(vals, i)} end)
          Map.put(acc, m.key, m.model.clock(d, state, ins))
      end

    vals =
      Enum.reduce(writes, vals, fn {key, addr, data, mask, depth}, v ->
        if addr < depth do
          words = Map.fetch!(v, key)
          old = Map.get(words, addr, 0)
          Map.put(v, key, Map.put(words, addr, (old &&& ~~~mask) ||| (data &&& mask)))
        else
          v
        end
      end)

    vals = vals |> Map.merge(regs) |> Map.merge(reads) |> Map.merge(models)
    %{sim | vals: vals} |> settle() |> record(fire)
  end

  # -- tracing ---------------------------------------------------------------------------

  defp record(sim, fire \\ MapSet.new())
  defp record(%{trace: nil} = sim, _fire), do: sim

  defp record(sim, fire) do
    snapshot =
      for {id, %{kind: k}} <- sim.flat.sigs,
          k != :clock,
          into: %{},
          do: {id, Map.fetch!(sim.vals, id)}

    %{sim | trace: [{sim.time, MapSet.to_list(fire), snapshot} | sim.trace]}
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
