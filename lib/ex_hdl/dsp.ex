defmodule ExHdl.DSP do
  @moduledoc """
  Hardware analysis of stream kernels: `analyze_scan/3` runs NxFixed's
  width check on a `step(..., state, ...) -> {output, next_state}` kernel,
  then the recurrence analysis and schedule for a target
  (`ExHdl.Passes.Recurrence`, `ExHdl.Target.Timing`).
  """

  defmodule ScheduleError do
    defexception [:message]
  end

  @doc """
  Analyses a stream kernel `step(..., state, ...) -> {output, next_state}`.

  `opts[:state]` is the index of the state argument in `args`. Runs the
  width check, then `ExHdl.Passes.Recurrence`. Further options: `:ii`,
  `:channels`, timing overrides (`:clock_mhz`, `:dsp_latency`, ...), and
  everything `analyze/3` accepts.

  Returns `{:ok, %ExHdl.IR.Scan{}}` or `{:error, %NxFixed.RangeError{} | %ScheduleError{}}`.
  """
  def analyze_scan(fun, args, opts) when is_function(fun) and is_list(args) do
    state_arg = Keyword.fetch!(opts, :state)

    output = fun |> Nx.Defn.debug_expr() |> apply(args)

    with :ok <- check_scan_shape(output),
         {:ok, graph} <- NxFixed.analyze_expr(output, opts) do
      {out_ids, next_ids} = graph.outputs
      state_indices = param_indices(args, state_arg)

      state_params =
        for id <- graph.order,
            graph.nodes[id].op == :parameter,
            graph.nodes[id].attrs in state_indices,
            do: id

      with :ok <- check_state_types(args, state_arg, graph, next_ids),
           {:ok, scan} <-
             ExHdl.Passes.Recurrence.run(graph, state_params, out_ids, next_ids, opts) do
        {:ok, %{scan | args: arg_layout(args, state_arg)}}
      else
        {:error, message} when is_binary(message) -> {:error, %ScheduleError{message: message}}
        {:error, %ScheduleError{}} = error -> error
      end
    end
  end

  @doc """
  Analyses a stream kernel (`analyze_scan/3`) and generates its
  SystemVerilog module (`ExHdl.Backends.SystemVerilog.Scan.generate/2`).
  `opts` go to both (`:state`, `:ii`/`:channels`, timing, `:name`,
  `:init`, `:param_names`).

  Returns `{:ok, %ExHdl.Backends.SystemVerilog.Scan.Design{}}` or the
  analysis error; raises `ExHdl.Backends.SystemVerilog.Scan.UnsupportedError`.
  """
  def scan_to_sv(fun, args, opts) do
    with {:ok, scan} <- analyze_scan(fun, args, opts) do
      {:ok, ExHdl.Backends.SystemVerilog.Scan.generate(scan, opts)}
    end
  end

  # Role and tensor leaves of every argument: argument 0 is the sample,
  # `state_arg` the state, keyword lists are kernel options, the rest params.
  defp arg_layout(args, state_arg) do
    {layout, _} =
      args
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn {arg, i}, next ->
        role =
          cond do
            is_list(arg) -> :opts
            i == 0 -> :sample
            i == state_arg -> :state
            true -> :param
          end

        templates = if role == :opts, do: [], else: arg |> leaves() |> Enum.map(&template/1)

        leaves =
          templates
          |> Enum.with_index(next)
          |> Enum.map(fn {t, index} -> %{index: index, type: t.type, shape: t.shape} end)

        {%{arg: i, role: role, leaves: leaves}, next + length(leaves)}
      end)

    layout
  end

  defp template(n) when is_number(n), do: n |> Nx.tensor() |> Nx.to_template()
  defp template(t), do: Nx.to_template(t)

  defp check_scan_shape({_output, _next_state}), do: :ok

  defp check_scan_shape(_),
    do:
      {:error,
       %ScheduleError{message: "stream_scan: the step function must return {output, next_state}"}}

  # Nx numbers the tensor leaves of all arguments in order; non-tensor
  # arguments (keyword options) are not parameters.
  defp param_indices(args, arg) do
    offset = args |> Enum.take(arg) |> Enum.map(&leaf_count/1) |> Enum.sum()
    Enum.to_list(offset..(offset + leaf_count(Enum.at(args, arg)) - 1)//1)
  end

  # Keyword lists (kernel options) are not parameters; every other argument
  # is a container of tensors (tuples, NxFixed.Fixed, ...).
  defp leaf_count(list) when is_list(list), do: 0
  defp leaf_count(arg), do: length(leaves(arg))

  defp leaves(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&leaves/1)
  defp leaves(n) when is_integer(n), do: [n]
  defp leaves(arg), do: Nx.Defn.Composite.flatten_list([arg])

  # next_state must have exactly the state's types and shapes.
  defp check_state_types(args, arg, graph, next_ids) do
    states = args |> Enum.at(arg) |> leaves() |> Enum.map(&Nx.to_template/1)
    nexts = next_ids |> leaves() |> Enum.map(&graph.nodes[&1])

    mismatch =
      length(states) != length(nexts) or
        Enum.any?(Enum.zip(states, nexts), fn {s, n} -> s.type != n.type or s.shape != n.shape end)

    if mismatch do
      expected = Enum.map_join(states, ", ", &"#{inspect(&1.type)}#{inspect(&1.shape)}")
      got = Enum.map_join(nexts, ", ", &"#{inspect(&1.type)}#{inspect(&1.shape)}")

      {:error,
       %ScheduleError{
         message:
           "stream_scan: next_state must match the state exactly; state is #{expected}, next_state is #{got}"
       }}
    else
      :ok
    end
  end
end
