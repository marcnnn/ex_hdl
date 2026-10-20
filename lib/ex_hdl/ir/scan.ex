defmodule ExHdl.IR.Scan do
  @moduledoc """
  A stateful stream kernel: `step(sample, state, params...) -> {output, next_state}`
  applied once per sample, with `next_state` fed back as `state`.

    * `recurrence` - nodes on a path from a state leaf to the next value of
      a leaf in the same group (see `groups`). They must complete within one
      initiation interval; all other nodes can be pipelined freely.
    * `groups` - the state leaves split into feedback loops: the strongly
      connected components of "the next value of leaf i depends on leaf j",
      in dependency order. Each group is
      `%{leaves: [k], params: [id], next: [id], recurrence: MapSet, loop_latency: l}`
      (`params` are the graph parameters of the leaves that are read). A
      cascade of filters has one group per filter, each with its own loop.
    * `loop_latency` - cycles the longest group's loop needs (state register
      included).
    * `ii` - cycles between samples of the same channel.
    * `channels` - independent streams interleaved through the loop.
    * `throughput` - samples per cycle over all channels.
    * `pipeline_latency` - cycles from a sample to its output.
    * `timing` - the `ExHdl.Target.Timing` model the schedule was made for.
    * `state_mem` - where the per-channel state lives (`:registers`,
      `:distributed`, `:block`, `:ultra`) and `ram_latency` its read latency
      in cycles (0 for registers).
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
    :groups,
    :critical_path,
    :loop_latency,
    :ii,
    :channels,
    :throughput,
    :pipeline_latency,
    :timing,
    state_mem: :registers,
    ram_latency: 0,
    args: []
  ]
end

defmodule ExHdl.Passes.Recurrence do
  @moduledoc """
  Finds the feedback loops of a scan kernel and decides how it can run.

  The state leaves are grouped into loops: leaf `i` depends on leaf `j` when
  `j` is an input of `i`'s next value, and a group is a strongly connected
  component of that relation. Groups are independent loops: a group that
  only feeds another (one biquad section into the next) is not part of the
  other's loop, so the hardware reads and writes each group at its own
  pipeline stages.

  The loop latency `L` of a group is the number of cycles from reading its
  state to having its next state in a register, computed by
  `ExHdl.Passes.Schedule` over the group's recurrence only (inputs that do
  not depend on the group's state are computed ahead and arrive at cycle 0).
  The kernel's `L` is the largest of them.

    * `L == 1`: one sample per cycle.
    * `ii: n` (n >= L): one sample every n cycles; `ii: :auto` takes n = L.
    * `channels: n` (n >= L): n independent streams take turns; the loop
      holds one state per channel, and the whole kernel accepts one sample
      per cycle. With the state in a memory (`state_mem:` other than
      `:registers`) the read is issued `ram_latency` cycles before the state
      is needed, so n >= L + ram_latency.
    * otherwise: error, reporting the critical path.
  """

  alias ExHdl.IR.Scan
  alias NxFixed.Dataflow
  alias ExHdl.Passes.Schedule
  alias ExHdl.Target.Timing

  @styles [:registers, :distributed, :block, :ultra]

  @doc """
  `graph` must be range-annotated; `leaf_params` has the graph parameter of
  every state leaf in order (`nil` for a leaf the kernel does not read);
  `outputs`/`next_state` are id trees.
  """
  def run(%Dataflow{} = graph, leaf_params, outputs, next_state, opts) do
    timing = Timing.new(opts)
    next_ids = flatten(next_state)
    state_params = Enum.reject(leaf_params, &is_nil/1)

    with {:ok, style, ram_latency} <- state_mem(opts) do
      groups =
        graph
        |> groups(leaf_params, next_ids)
        |> Enum.map(&group_loop(graph, &1, timing))

      worst = Enum.max_by(groups, & &1.loop_latency, fn -> nil end)
      loop_latency = if worst, do: worst.loop_latency, else: 1

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
        recurrence:
          groups |> Enum.map(& &1.recurrence) |> Enum.reduce(MapSet.new(), &MapSet.union/2),
        groups: Enum.map(groups, &Map.drop(&1, [:sched, :worst])),
        critical_path:
          if(worst && worst.worst && Map.has_key?(worst.sched, worst.worst),
            do: path(graph, worst.sched, worst.worst),
            else: []
          ),
        loop_latency: loop_latency,
        pipeline_latency: pipeline_latency,
        timing: timing,
        state_mem: style,
        ram_latency: ram_latency
      }

      decide(scan, (worst && worst.sched) || %{}, opts)
    end
  end

  @doc """
  The state memory style of `opts` and its read latency:
  `{:ok, style, cycles}`. `:ram_latency` overrides the default (1 for
  `:distributed` and `:block`, 2 for `:ultra`).
  """
  def state_mem(opts) do
    style = Keyword.get(opts, :state_mem, :registers)

    cond do
      style not in @styles ->
        {:error, "stream_scan: state_mem: must be one of #{inspect(@styles)}"}

      style == :registers ->
        {:ok, :registers, 0}

      true ->
        default = if style == :ultra, do: 2, else: 1

        case Keyword.get(opts, :ram_latency, default) do
          k when is_integer(k) and k >= 1 -> {:ok, style, k}
          k -> {:error, "stream_scan: ram_latency: must be a positive integer, got #{inspect(k)}"}
        end
    end
  end

  defp loop_cycles(sched, id) do
    case sched do
      %{^id => %{at: at}} -> Schedule.cycles_to_register(at)
      # next state does not depend on the group's state (or is the state itself)
      _ -> 1
    end
  end

  defp decide(%Scan{loop_latency: l, ram_latency: r} = scan, sched, opts) do
    ii = Keyword.get(opts, :ii)
    channels = Keyword.get(opts, :channels)

    cond do
      ii != nil and channels != nil ->
        {:error, "stream_scan: give either ii: or channels:, not both"}

      scan.state_mem != :registers and not (is_integer(channels) and channels > 1) ->
        {:error,
         "stream_scan: state_mem: #{inspect(scan.state_mem)} holds one state per channel and needs channels: n (n > 1)"}

      ii == :auto ->
        {:ok, %{scan | ii: l, channels: 1, throughput: 1 / l}}

      ii == nil and channels == nil and l == 1 ->
        {:ok, %{scan | ii: 1, channels: 1, throughput: 1.0}}

      ii == nil and channels == nil ->
        {:error,
         message(scan, sched, "needs #{l} cycles, so it cannot accept a sample every cycle")}

      is_integer(ii) and ii >= l ->
        {:ok, %{scan | ii: ii, channels: 1, throughput: 1 / ii}}

      is_integer(channels) and channels >= l + r ->
        {:ok, %{scan | ii: channels, channels: channels, throughput: 1.0}}

      is_integer(ii) ->
        {:error, message(scan, sched, "needs #{l} cycles, more than ii: #{ii}")}

      is_integer(channels) and r > 0 ->
        {:error,
         message(
           scan,
           sched,
           "needs #{l} cycles and the state memory read #{r} more, so more than channels: #{channels}"
         )}

      is_integer(channels) ->
        {:error, message(scan, sched, "needs #{l} cycles, more than channels: #{channels}")}
    end
  end

  defp message(scan, sched, problem) do
    l = scan.loop_latency
    n = l + scan.ram_latency

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
        * channels: #{n}  interleave #{n} independent streams at one sample per cycle
        * shorten the loop: keep multiplies and table lookups out of the
          state update, or restructure it (e.g. look-ahead for IIR filters)
    """
  end

  # -- groups ---------------------------------------------------------------------------------

  # Strongly connected components of the leaf dependency relation, sorted so
  # that every group comes after the groups it depends on.
  defp groups(_graph, [], _next_ids), do: []

  defp groups(graph, leaf_params, next_ids) do
    leaves = Enum.to_list(0..(length(next_ids) - 1))

    # deps[i]: leaves whose state reaches the next value of leaf i
    deps =
      Map.new(Enum.zip(leaves, next_ids), fn {i, n} ->
        back = reach([n], &graph.nodes[&1].inputs)

        ds = for {p, j} <- Enum.with_index(leaf_params), p != nil, MapSet.member?(back, p), do: j
        {i, ds}
      end)

    succ =
      for {i, ds} <- deps, j <- ds, reduce: %{} do
        acc -> Map.update(acc, j, [i], &[i | &1])
      end

    # leaves reachable from j (its state influences their next values)
    reach_from =
      Map.new(leaves, fn j -> {j, reach(Map.get(succ, j, []), &Map.get(succ, &1, []))} end)

    components =
      leaves
      |> Enum.map(fn i ->
        Enum.filter(leaves, fn j ->
          i == j or (MapSet.member?(reach_from[i], j) and MapSet.member?(reach_from[j], i))
        end)
      end)
      |> Enum.uniq()

    components
    |> Enum.sort_by(fn members ->
      # number of leaves outside the group that feed it
      Enum.count(leaves -- members, fn j ->
        Enum.any?(members, &MapSet.member?(reach_from[j], &1))
      end)
    end)
    |> Enum.map(fn members ->
      params = members |> Enum.map(&Enum.at(leaf_params, &1)) |> Enum.reject(&is_nil/1)
      next = Enum.map(members, &Enum.at(next_ids, &1))
      %{leaves: members, params: params, next: next, recurrence: recurrence(graph, params, next)}
    end)
  end

  defp group_loop(graph, group, timing) do
    rec_order = Enum.filter(graph.order, &MapSet.member?(group.recurrence, &1))
    sched = Schedule.asap(graph, rec_order, timing)

    {loop_latency, worst} =
      group.next
      |> Enum.map(fn id -> {loop_cycles(sched, id), id} end)
      |> Enum.max(fn -> {1, nil} end)

    Map.merge(group, %{loop_latency: loop_latency, sched: sched, worst: worst})
  end

  # Nodes reachable from the group's state that also reach its next state.
  defp recurrence(graph, params, next_ids) do
    users =
      for id <- graph.order, input <- Enum.uniq(graph.nodes[id].inputs), reduce: %{} do
        acc -> Map.update(acc, input, [id], &[id | &1])
      end

    forward = reach(params, &Map.get(users, &1, []))
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
