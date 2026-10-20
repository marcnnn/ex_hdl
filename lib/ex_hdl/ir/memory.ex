defmodule ExHdl.IR.Memory do
  @moduledoc """
  Parameters of a stream kernel that are memories: a table the kernel reads
  with `Nx.take(table, index)` at an index computed from the sample or the
  state (a gather), and that the host or another stream writes at run time.

  On the BEAM the memory is an ordinary parameter tensor (`{depth}` or
  `{depth, row...}`, read along axis 0). Option `memories:` of
  `ExHdl.DSP.analyze_scan/3` names such parameters (`param_names`), each as
  `name` or `{name, opts}`:

    * `banks:` - 2 (default): two banks, the host writes the inactive one
      and swaps; 1: a single bank, written while it is read
    * `style:` - `:distributed`, `:block` or `:ultra` (default from
      `ExHdl.Target.Timing.memory_style/3` on one bank)
    * `latency:` - read latency in cycles (default 1 for `:distributed`,
      `bram_latency` for `:block`, `uram_latency` for `:ultra`), scheduled
      like any registered operation
    * `clock:` - `:shared` (default) or `:separate`: the write port has its
      own clock `<name>_wclk`

  Every element of a take's index is one read port. A memory gets one copy
  per read port (simple dual port RAMs written together), so a gather of 16
  values from a frame is 16 RAMs.

  A spec is `%{name:, index:, id:, depth:, row:, fmt:, bits:, banks:, style:,
  latency:, clock:, takes: [take_id]}`: `index` the Nx parameter index,
  `id` the graph node, `row` the values per word and `bits` their width
  (`fmt` from the proven range).
  """

  alias ExHdl.Target.Timing
  alias NxFixed.IntSet

  @styles [:distributed, :block, :ultra]

  @doc """
  Memory specs of `graph` for `opts[:memories]`; `layout` is the argument
  layout (`ExHdl.IR.Scan.args`), `params_by_index` maps Nx parameter
  indices to graph nodes. `{:ok, [spec]}` or `{:error, message}`.
  """
  def specs(graph, layout, params_by_index, opts) do
    case Keyword.get(opts, :memories, []) do
      [] ->
        {:ok, []}

      list when is_list(list) ->
        timing = Timing.new(opts)
        leaves = ExHdl.DSP.param_leaf_names(layout, Keyword.get(opts, :param_names, []))

        Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
          {name, mopts} =
            case entry do
              {name, mopts} when is_list(mopts) -> {to_string(name), mopts}
              name -> {to_string(name), []}
            end

          case spec(graph, leaves, params_by_index, timing, name, mopts) do
            {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, specs} -> {:ok, Enum.reverse(specs)}
          error -> error
        end

      other ->
        {:error, "stream_scan: memories: must be a list, got #{inspect(other)}"}
    end
  end

  defp spec(graph, leaves, params_by_index, timing, name, mopts) do
    with {:ok, leaf} <- find_leaf(leaves, name),
         {:ok, id} <- used(params_by_index, leaf, name),
         {:ok, takes} <- takes(graph, id, name) do
      node = graph.nodes[id]
      [depth | rest] = Tuple.to_list(node.shape)
      row = Enum.product(rest)
      fmt = IntSet.bit_width(node.range)
      {_, bits} = fmt
      banks = Keyword.get(mopts, :banks, 2)
      style = Keyword.get(mopts, :style, Timing.memory_style(timing, bits * row, depth))
      clock = Keyword.get(mopts, :clock, :shared)

      latency =
        Keyword.get_lazy(mopts, :latency, fn ->
          case style do
            :distributed -> 1
            :block -> timing.bram_latency
            :ultra -> timing.uram_latency || 2
          end
        end)

      cond do
        banks not in [1, 2] ->
          {:error, "stream_scan: memory #{name}: banks: must be 1 or 2"}

        style not in @styles ->
          {:error, "stream_scan: memory #{name}: style: must be one of #{inspect(@styles)}"}

        not (is_integer(latency) and latency >= 1) ->
          {:error, "stream_scan: memory #{name}: latency: must be a positive integer"}

        clock not in [:shared, :separate] ->
          {:error, "stream_scan: memory #{name}: clock: must be :shared or :separate"}

        true ->
          {:ok,
           %{
             name: name,
             index: leaf.index,
             id: id,
             depth: depth,
             row: row,
             fmt: fmt,
             bits: bits,
             banks: banks,
             style: style,
             latency: latency,
             clock: clock,
             takes: takes
           }}
      end
    end
  end

  defp find_leaf(leaves, name) do
    case Enum.find(leaves, fn {_base, n, _leaf} -> n == name end) do
      {_, _, %{shape: shape} = leaf} when tuple_size(shape) >= 1 ->
        {:ok, leaf}

      {_, _, _} ->
        {:error, "stream_scan: memory #{name} must be a tensor with at least one axis"}

      nil ->
        known = Enum.map_join(leaves, ", ", &elem(&1, 1))

        {:error,
         "stream_scan: memories: no parameter named #{inspect(name)} (parameters: #{known})"}
    end
  end

  defp used(params_by_index, leaf, name) do
    case Map.fetch(params_by_index, leaf.index) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, "stream_scan: memory #{name} is not read by the kernel"}
    end
  end

  # Every use of the memory must be the table of a take.
  defp takes(graph, id, name) do
    users = for u <- graph.order, id in graph.nodes[u].inputs, do: graph.nodes[u]

    if Enum.all?(users, &match?(%{op: :take, inputs: [^id, idx]} when idx != id, &1)) do
      {:ok, Enum.map(users, & &1.id)}
    else
      ops = users |> Enum.reject(&(&1.op == :take)) |> Enum.map_join(", ", &inspect(&1.op))

      {:error,
       "stream_scan: memory #{name} can only be read with Nx.take(#{name}, index); it is also used by #{ops}"}
    end
  end

  @doc "Schedule costs of the memory reads: `%{take_id => {:reg, latency, :ram}}`."
  def costs(_graph, specs) do
    for spec <- specs, id <- spec.takes, into: %{}, do: {id, {:reg, spec.latency, :ram}}
  end
end
