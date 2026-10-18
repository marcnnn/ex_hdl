defmodule ExHdl.DSP do
  @moduledoc """
  Entry point for analysing `defn` kernels.

      ExHdl.DSP.analyze(&MySDR.DSP.ddc_step/4, [
        {Nx.template({}, :s16), Nx.template({}, :s16)},
        Nx.template({}, :u16),
        Nx.template({}, :u16),
        Nx.template({}, :s16)
      ])

  Arguments are passed like to the function itself; tensors may be templates.
  """

  alias ExHdl.IR.Dataflow
  alias ExHdl.Passes.WidthCheck

  defmodule RangeError do
    defexception [:message, :graph, :violations]
  end

  defmodule ScheduleError do
    defexception [:message]
  end

  @doc """
  Traces `fun` with `args`, builds the dataflow IR and runs the width check.

  Returns `{:ok, graph}` with every node's `range` set, or
  `{:error, %RangeError{}}`. Options: `:param_ranges`, `:name`.
  """
  def analyze(fun, args, opts \\ []) when is_function(fun) and is_list(args) do
    fun
    |> Nx.Defn.debug_expr()
    |> apply(args)
    |> analyze_expr(opts)
  end

  @doc "Like `analyze/3` but raises `RangeError`."
  def analyze!(fun, args, opts \\ []) do
    case analyze(fun, args, opts) do
      {:ok, graph} -> graph
      {:error, error} -> raise error
    end
  end

  @doc """
  Analyses a stream kernel `step(..., state, ...) -> {output, next_state}`.

  `opts[:state]` is the index of the state argument in `args`. Runs the
  width check, then `ExHdl.Passes.Recurrence`. Further options: `:ii`,
  `:channels`, timing overrides (`:clock_mhz`, `:dsp_latency`, ...), and
  everything `analyze/3` accepts.

  Returns `{:ok, %ExHdl.IR.Scan{}}` or `{:error, %RangeError{} | %ScheduleError{}}`.
  """
  def analyze_scan(fun, args, opts) when is_function(fun) and is_list(args) do
    state_arg = Keyword.fetch!(opts, :state)

    output = fun |> Nx.Defn.debug_expr() |> apply(args)

    with :ok <- check_scan_shape(output),
         {:ok, graph} <- analyze_expr(output, opts) do
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
        {:ok, scan}
      else
        {:error, message} when is_binary(message) -> {:error, %ScheduleError{message: message}}
        {:error, %ScheduleError{}} = error -> error
      end
    end
  end

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

  defp leaf_count(t) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.map(&leaf_count/1) |> Enum.sum()

  defp leaf_count(%Nx.Tensor{}), do: 1
  defp leaf_count(n) when is_number(n), do: 1
  defp leaf_count(_), do: 0

  defp leaves(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&leaves/1)
  defp leaves(other), do: [other]

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

  @doc """
  Runs a stream kernel `step(sample, state, params...)` over `samples` on
  the CPU, threading the state from sample to sample. This is the checked
  Nx reference (`ExHdl.DSP.Compiler`): the kernel is width-checked once
  when it is compiled.

  `params` are the remaining tensor arguments, constant over the stream.
  Options: `:kernel_opts` (a trailing keyword list for the kernel) plus
  everything `ExHdl.DSP.Compiler` accepts.

  Returns `{outputs, final_state}`.
  """
  def run_scan(fun, samples, initial_state, params \\ [], opts \\ [])

  def run_scan(_fun, [], initial_state, _params, _opts), do: {[], initial_state}

  def run_scan(fun, [first | _] = samples, initial_state, params, opts) do
    {kernel_opts, opts} = Keyword.pop(opts, :kernel_opts)
    template = &Nx.Defn.Composite.traverse(&1, fn t -> Nx.to_template(Nx.tensor(t)) end)

    templates =
      [template.(first), template.(initial_state) | Enum.map(params, template)] ++
        if(kernel_opts, do: [kernel_opts], else: [])

    step = Nx.Defn.compile(fun, templates, Keyword.put(opts, :compiler, ExHdl.DSP.Compiler))

    Enum.map_reduce(samples, initial_state, fn sample, state ->
      apply(step, [sample, state | params])
    end)
  end

  @doc "Runs the analysis on an already traced output expression."
  def analyze_expr(output, opts \\ []) do
    {graph, violations} = output |> Dataflow.from_expr() |> WidthCheck.run(opts)

    case violations do
      [] ->
        {:ok, graph}

      _ ->
        name = Keyword.get(opts, :name, "defn")
        message = WidthCheck.format(graph, violations, name)
        {:error, %RangeError{message: message, graph: graph, violations: violations}}
    end
  end
end
