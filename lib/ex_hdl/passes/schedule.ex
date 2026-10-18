defmodule ExHdl.Passes.Schedule do
  @moduledoc """
  ASAP scheduling with operator chaining.

  Every node gets an arrival time `{cycle, ns}`: the cycle in which its
  value becomes valid and the combinational delay already spent in that
  cycle. Combinational ops are chained until the period budget is used up,
  then a register is inserted before the op. Registered ops (DSP, BRAM)
  deliver their result `cycles` later at the start of a cycle.
  """

  alias ExHdl.Target.Timing

  @type arrival :: {non_neg_integer(), float()}

  @doc """
  Schedules the nodes in `ids` (topological order). Inputs outside `ids`
  are taken from `seeds` or arrive at `{0, 0.0}`.

  Returns `%{id => %{at: arrival, cost: cost, from: critical_input | nil}}`.
  """
  def asap(graph, ids, %Timing{} = timing, seeds \\ %{}) do
    period = Timing.period_ns(timing)

    Enum.reduce(ids, %{}, fn id, sched ->
      node = graph.nodes[id]

      {start, from} =
        node.inputs
        |> Enum.map(fn input -> {arrival(sched, seeds, input), input} end)
        |> Enum.max_by(fn {at, _} -> at end, fn -> {Map.get(seeds, id, {0, 0.0}), nil} end)

      cost = Timing.cost(node, graph, timing)
      Map.put(sched, id, %{at: advance(start, cost, period), cost: cost, from: from})
    end)
  end

  defp arrival(sched, seeds, id) do
    case sched do
      %{^id => %{at: at}} -> at
      _ -> Map.get(seeds, id, {0, 0.0})
    end
  end

  defp advance(at, {:comb, d}, _period) when d == 0, do: at
  defp advance({c, t}, {:comb, d}, period) when t + d <= period, do: {c, t + d}
  defp advance({c, _t}, {:comb, d}, _period), do: {c + 1, d}
  defp advance({c, _t}, {:reg, k, _}, _period), do: {c + k, 0.0}

  @doc """
  Cycles until a value arriving at `at` can be stored in a register and
  read again: a value fresh out of a pipeline register (`ns == 0`) can be
  that register.
  """
  def cycles_to_register({c, t}) when t == 0 and c > 0, do: c
  def cycles_to_register({c, _t}), do: c + 1
end
