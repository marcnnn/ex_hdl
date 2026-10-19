defmodule ExHdl.IR.Scan do
  @moduledoc """
  A stateful stream kernel: `step(sample, state, params...) -> {output, next_state}`
  applied once per sample, with `next_state` fed back as `state`.

    * `recurrence` - nodes on a path from the state to the next state. They
      must complete within one initiation interval; all other nodes can be
      pipelined freely.
    * `loop_latency` - cycles the recurrence needs (state register included).
    * `ii` - cycles between samples of the same channel.
    * `channels` - independent streams interleaved through the loop.
    * `throughput` - samples per cycle over all channels.
    * `pipeline_latency` - cycles from a sample to its output.
    * `timing` - the `ExHdl.Target.Timing` model the schedule was made for.
    * `args` - the kernel's arguments in order, each
      `%{arg: i, role: :sample | :state | :param | :opts, leaves: [%{index:, type:, shape:}]}`
      where `index` is the Nx parameter index of the tensor leaf.
  """
  defstruct [
    :graph,
    :state_params,
    :next_state,
    :outputs,
    :recurrence,
    :critical_path,
    :loop_latency,
    :ii,
    :channels,
    :throughput,
    :pipeline_latency,
    :timing,
    args: []
  ]
end

defmodule ExHdl.Passes.Recurrence do
  @moduledoc """
  Finds the feedback part of a scan kernel and decides how it can run.

  The loop latency `L` is the number of cycles from reading the state to
  having the next state in a register, computed by `ExHdl.Passes.Schedule`
  over the recurrence only (inputs that do not depend on the state are
  computed ahead and arrive at cycle 0).

    * `L == 1`: one sample per cycle.
    * `ii: n` (n >= L): one sample every n cycles; `ii: :auto` takes n = L.
    * `channels: n` (n >= L): n independent streams take turns; the loop
      holds one state per channel, and the whole kernel accepts one sample
      per cycle.
    * otherwise: error, reporting the critical path.
  """

  alias ExHdl.IR.Scan
  alias NxFixed.Dataflow
  alias ExHdl.Passes.Schedule
  alias ExHdl.Target.Timing

  @doc "`graph` must be range-annotated; `outputs`/`next_state` are id trees."
  def run(%Dataflow{} = graph, state_params, outputs, next_state, opts) do
    timing = Timing.new(opts)
    next_ids = flatten(next_state)

    recurrence = recurrence(graph, state_params, next_ids)
    rec_order = Enum.filter(graph.order, &MapSet.member?(recurrence, &1))
    sched = Schedule.asap(graph, rec_order, timing)

    {loop_latency, worst} =
      next_ids
      |> Enum.map(fn id -> {loop_cycles(sched, id), id} end)
      |> Enum.max(fn -> {1, nil} end)

    full = Schedule.asap(graph, graph.order, timing)

    pipeline_latency =
      outputs
      |> flatten()
      |> Enum.map(&Schedule.cycles_to_register(full[&1].at))
      |> Enum.max(fn -> 0 end)

    scan = %Scan{
      graph: graph,
      state_params: state_params,
      next_state: next_state,
      outputs: outputs,
      recurrence: recurrence,
      critical_path:
        if(worst && Map.has_key?(sched, worst), do: path(graph, sched, worst), else: []),
      loop_latency: loop_latency,
      pipeline_latency: pipeline_latency,
      timing: timing
    }

    decide(scan, sched, opts)
  end

  defp loop_cycles(sched, id) do
    case sched do
      %{^id => %{at: at}} -> Schedule.cycles_to_register(at)
      # next state does not depend on the state (or is the state itself)
      _ -> 1
    end
  end

  defp decide(%Scan{loop_latency: l} = scan, sched, opts) do
    case {Keyword.get(opts, :ii), Keyword.get(opts, :channels)} do
      {:auto, nil} ->
        {:ok, %{scan | ii: l, channels: 1, throughput: 1 / l}}

      {nil, nil} when l == 1 ->
        {:ok, %{scan | ii: 1, channels: 1, throughput: 1.0}}

      {nil, nil} ->
        {:error,
         message(scan, sched, "needs #{l} cycles, so it cannot accept a sample every cycle")}

      {ii, nil} when is_integer(ii) and ii >= l ->
        {:ok, %{scan | ii: ii, channels: 1, throughput: 1 / ii}}

      {nil, n} when is_integer(n) and n >= l ->
        {:ok, %{scan | ii: n, channels: n, throughput: 1.0}}

      {ii, nil} when is_integer(ii) ->
        {:error, message(scan, sched, "needs #{l} cycles, more than ii: #{ii}")}

      {nil, n} when is_integer(n) ->
        {:error, message(scan, sched, "needs #{l} cycles, more than channels: #{n}")}

      _ ->
        {:error, "stream_scan: give either ii: or channels:, not both"}
    end
  end

  defp message(scan, sched, problem) do
    l = scan.loop_latency

    steps =
      Enum.map(scan.critical_path, fn id ->
        node = scan.graph.nodes[id]
        {c, t} = sched[id].at

        "    #{String.pad_trailing(to_string(node.op), 14)} #{String.pad_trailing(Timing.describe(sched[id].cost), 18)} ready at cycle #{c} + #{Float.round(t, 2)} ns\n"
      end)

    """
    stream_scan: the feedback loop (state -> next state) #{problem}.

      critical loop path:
    #{steps}
      options:
        * ii: #{l}        accept one sample every #{l} cycles (throughput 1/#{l})
        * channels: #{l}  interleave #{l} independent streams at one sample per cycle
        * shorten the loop: keep multiplies and table lookups out of the
          state update, or restructure it (e.g. look-ahead for IIR filters)
    """
  end

  # Nodes reachable from a state parameter that also reach a next state.
  defp recurrence(graph, state_params, next_ids) do
    users =
      for id <- graph.order, input <- Enum.uniq(graph.nodes[id].inputs), reduce: %{} do
        acc -> Map.update(acc, input, [id], &[id | &1])
      end

    forward = reach(state_params, &Map.get(users, &1, []))
    backward = reach(next_ids, &graph.nodes[&1].inputs)
    MapSet.intersection(forward, backward)
  end

  defp reach(start, next), do: reach(start, next, MapSet.new())
  defp reach([], _next, seen), do: seen

  defp reach([id | rest], next, seen) do
    if MapSet.member?(seen, id),
      do: reach(rest, next, seen),
      else: reach(next.(id) ++ rest, next, MapSet.put(seen, id))
  end

  # Follows the latest-arriving input inside the loop back to the state.
  defp path(graph, sched, id) do
    loop_inputs = Enum.filter(graph.nodes[id].inputs, &Map.has_key?(sched, &1))

    case loop_inputs do
      [] -> [id]
      inputs -> path(graph, sched, Enum.max_by(inputs, &sched[&1].at)) ++ [id]
    end
  end

  defp flatten(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&flatten/1)
  defp flatten(id) when is_integer(id), do: [id]
end
