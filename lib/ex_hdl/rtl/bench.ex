defmodule ExHdl.RTL.Bench.Agent do
  @moduledoc """
  A participant of an `ExHdl.RTL.Bench` run: drives some inputs of the
  design and watches its outputs, one event at a time.

  Every cycle the bench calls `drive/2` on every agent, pokes the merged
  inputs, reads the settled outputs, calls `sample/3` with them, then
  steps. What an agent drives in a cycle must not depend on the outputs
  of the same cycle (an AXI4-Stream source raises `tvalid` without
  waiting for `tready`); transfers are decided in `sample/3`.
  """

  @callback drive(state :: term(), cycle :: non_neg_integer()) ::
              {%{atom() => integer()} | keyword(), term()}
  @callback sample(state :: term(), outputs :: %{atom() => integer()}, cycle :: non_neg_integer()) ::
              term()
end

defmodule ExHdl.RTL.Bench do
  @moduledoc """
  Closed-loop testbench: a simulator (`ExHdl.RTL.Sim` or a Verilator
  `ExHdl.RTL.Cosim.Session`) plus agents (`ExHdl.RTL.Bench.Agent`), with
  the stimulus of every cycle recorded for replay.

      bench = Bench.new(Sim.new(mod), src: Source.new(beats), sink: Sink.new())
      bench = Bench.run_until(bench, &(Sink.count(Bench.agent(&1, :sink)) == 10), 5_000)
      :ok = Bench.compare(bench)            # replay in Verilator against the BEAM

      # the same bench at Verilator speed
      {:ok, s} = Cosim.open(mod)
      bench = Bench.new(s, src: Source.new(beats), sink: Sink.new())

  Agents are `name: state` entries; the state is a struct whose module
  implements `ExHdl.RTL.Bench.Agent`, or `{module, state}`.

  The first `reset:` cycles (default 2) hold every top-level reset
  asserted (`ExHdl.RTL.Sim.reset_inputs/2`, nothing for modules without
  resets) and the `idle:` inputs; agents are not called. Afterwards every
  cycle merges `idle:`, the released resets and what the agents drive,
  drops inputs the design does not have, pokes them, samples the outputs,
  lets the agents see them and advances one event. Inputs nobody drives
  keep their value.

  `drive/4` is the function form for a single loop without agents.
  """

  alias ExHdl.RTL.{Cosim, Module, Sim}
  alias ExHdl.RTL.Cosim.Session

  defstruct [
    :impl,
    :sim,
    :module,
    :inputs,
    :idle,
    :reset_cycles,
    agents: [],
    cycle: 0,
    trace: [],
    outputs: %{},
    record: true
  ]

  @type t :: %__MODULE__{}

  @doc """
  A bench over `sim` (a `Sim` or a `Cosim.Session`). Options: `idle:`
  inputs (map), `reset:` cycles (default 2), `record:` (default `true`;
  `false` keeps no stimulus for long runs).
  """
  @spec new(Sim.t() | Session.t(), keyword(), keyword()) :: t()
  def new(sim, agents \\ [], opts \\ []) do
    impl = impl(sim)
    mod = sim.module

    %__MODULE__{
      impl: impl,
      sim: sim,
      module: mod,
      inputs:
        for(p <- mod.ports, p.dir == :input, p.role != :clock, into: MapSet.new(), do: p.name),
      idle: Map.new(Keyword.get(opts, :idle, %{})),
      reset_cycles: Keyword.get(opts, :reset, 2),
      agents: agents,
      outputs: impl.outputs(sim),
      record: Keyword.get(opts, :record, true)
    }
  end

  defp impl(%Sim{}), do: Sim
  defp impl(%Session{}), do: Session

  defp impl(other),
    do:
      raise(ArgumentError, "expected an ExHdl.RTL.Sim or a Cosim session, got #{inspect(other)}")

  @doc "State of agent `name`."
  def agent(%__MODULE__{agents: a}, name) do
    case Keyword.fetch!(a, name) do
      {mod, st} when is_atom(mod) -> st
      st -> st
    end
  end

  @doc "Replaces the state of agent `name` with `f.(state)`."
  def update(%__MODULE__{} = b, name, f) do
    agents =
      Keyword.update!(b.agents, name, fn
        {mod, st} when is_atom(mod) -> {mod, f.(st)}
        st -> f.(st)
      end)

    %{b | agents: agents}
  end

  @doc "Value an output had in the last cycle (sampled before its clock edge)."
  def output(%__MODULE__{outputs: o}, name), do: Map.fetch!(o, name)

  @doc "All outputs of the last cycle."
  def outputs(%__MODULE__{outputs: o}), do: o

  @doc "Current value of a signal (after the last edge)."
  def peek(%__MODULE__{impl: impl, sim: s}, name), do: impl.peek(s, name)

  @doc "The simulator."
  def sim(%__MODULE__{sim: s}), do: s

  @doc "Runs `n` cycles."
  def run(%__MODULE__{} = b, 0), do: b
  def run(%__MODULE__{} = b, n) when n > 0, do: b |> cycle() |> run(n - 1)

  @doc "Runs until `pred.(bench)` holds (checked before each cycle); raises after `max` cycles."
  def run_until(%__MODULE__{} = b, pred, max) do
    cond do
      pred.(b) -> b
      b.cycle >= max -> raise "bench: condition not met within #{max} cycles"
      true -> b |> cycle() |> run_until(pred, max)
    end
  end

  @doc "One cycle."
  def cycle(%__MODULE__{cycle: n, reset_cycles: r} = b) when n < r do
    ins = Map.merge(b.idle, Sim.reset_inputs(b.module, :asserted))
    step(b, ins, b.agents, false)
  end

  def cycle(%__MODULE__{} = b) do
    {ins, agents} =
      Enum.reduce(b.agents, {%{}, []}, fn {name, st}, {ins, acc} ->
        {i, st} = call(st, :drive, [b.cycle])
        {Map.merge(ins, Map.new(i)), [{name, st} | acc]}
      end)

    ins = b.idle |> Map.merge(Sim.reset_inputs(b.module, :released)) |> Map.merge(ins)
    step(b, ins, Enum.reverse(agents), true)
  end

  defp call({mod, st}, :drive, [c]) when is_atom(mod) do
    {i, st} = mod.drive(st, c)
    {i, {mod, st}}
  end

  defp call({mod, st}, :sample, [o, c]) when is_atom(mod), do: {mod, mod.sample(st, o, c)}
  defp call(%m{} = st, :drive, [c]), do: m.drive(st, c)
  defp call(%m{} = st, :sample, [o, c]), do: m.sample(st, o, c)

  defp step(b, ins, agents, sample?) do
    ins = Map.take(ins, MapSet.to_list(b.inputs))
    sim = b.impl.poke(b.sim, ins)
    outs = b.impl.outputs(sim)

    agents =
      if sample?,
        do: Enum.map(agents, fn {n, st} -> {n, call(st, :sample, [outs, b.cycle])} end),
        else: agents

    %{
      b
      | sim: b.impl.step(sim, 1),
        agents: agents,
        cycle: b.cycle + 1,
        trace: if(b.record, do: [ins | b.trace], else: b.trace),
        outputs: outs
    }
  end

  @doc "The recorded stimulus (one input map per cycle, oldest first)."
  def stimulus(%__MODULE__{trace: t}), do: Enum.reverse(t)

  @doc """
  Replays the recorded stimulus in the BEAM simulator and in Verilator
  and compares every output of every cycle (`ExHdl.RTL.Cosim.compare/3`;
  `vcd: path` dumps the Verilator run).
  """
  def compare(%__MODULE__{} = b, opts \\ []), do: Cosim.compare(b.module, stimulus(b), opts)

  @doc """
  Function form of a closed loop over `n` cycles of `sim` (a `Sim` or a
  session): `fun.(acc, i)` returns `{inputs, update}` and `update.(outputs)`
  the next `acc`, where `outputs` are sampled after the inputs, before the
  edge. Data inputs not in `inputs` are 0 that cycle (nothing is sticky),
  resets are released. Returns `{sim, events, outputs, acc}`; `events` (full
  input maps) replay with `ExHdl.RTL.Cosim.compare/3` after a reset prefix.
  """
  def drive(sim, acc, n, fun) do
    impl = impl(sim)
    mod = sim.module

    base =
      mod
      |> Module.data_inputs()
      |> Map.new(&{&1.name, 0})
      |> Map.merge(Sim.reset_inputs(mod, :released))

    {rows, acc, sim} =
      Enum.reduce(0..(n - 1)//1, {[], acc, sim}, fn i, {rows, acc, sim} ->
        {inputs, update} = fun.(acc, i)
        inputs = Map.merge(base, Map.new(inputs))
        sim = impl.poke(sim, inputs)
        outs = impl.outputs(sim)
        {[{inputs, outs} | rows], update.(outs), impl.step(sim, 1)}
      end)

    rows = Enum.reverse(rows)
    {sim, Enum.map(rows, &elem(&1, 0)), Enum.map(rows, &elem(&1, 1)), acc}
  end
end
