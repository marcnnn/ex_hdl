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

  # Keyword lists (kernel options) are not parameters; every other argument
  # is a container of tensors (tuples, ExHdl.Num.Fixed, ...).
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

  @doc """
  Runs a stream kernel `step(sample, state, params...)` over `samples` on
  the CPU, threading the state from sample to sample. This is the checked
  Nx reference (`ExHdl.DSP.Compiler`): the kernel is width-checked once
  when it is compiled.

  `params` are the remaining tensor arguments, constant over the stream.
  Options: `:kernel_opts` (a trailing keyword list for the kernel) plus
  everything `ExHdl.DSP.Compiler` accepts.

  With `compiler: EXLA` (or another Nx compiler) all samples run in one
  compiled `while` loop (`ExHdl.DSP.ScanLoop`), after the same width check;
  results are bit-identical. `stacked: true` then returns the outputs as
  tensors with the sample index as first axis instead of a list.

  Returns `{outputs, final_state}`.
  """
  def run_scan(fun, samples, initial_state, params \\ [], opts \\ [])

  def run_scan(_fun, [], initial_state, _params, _opts), do: {[], initial_state}

  def run_scan(fun, [first | _] = samples, initial_state, params, opts) do
    {kernel_opts, opts} = Keyword.pop(opts, :kernel_opts)
    template = &Nx.Defn.Composite.traverse(&1, fn t -> Nx.to_template(Nx.tensor(t)) end)

    # Float reference instances (ExHdl.Num.float/0) are allowed to contain floats.
    float? =
      [first, initial_state | params]
      |> Nx.Defn.Composite.flatten_list()
      |> Enum.any?(&match?({:f, _}, Nx.type(&1)))

    opts = Keyword.put_new(opts, :allow_float, float?)

    templates =
      [template.(first), template.(initial_state) | Enum.map(params, template)] ++
        if(kernel_opts, do: [kernel_opts], else: [])

    case Keyword.pop(opts, :compiler) do
      {nil, opts} ->
        {_stacked, opts} = Keyword.pop(opts, :stacked)
        step = Nx.Defn.compile(fun, templates, Keyword.put(opts, :compiler, ExHdl.DSP.Compiler))

        Enum.map_reduce(samples, initial_state, fn sample, state ->
          apply(step, [sample, state | params])
        end)

      {compiler, opts} ->
        run_scan_loop(fun, samples, initial_state, params, templates, kernel_opts, compiler, opts)
    end
  end

  # Width-checks the step once, then runs all samples in one compiled loop.
  defp run_scan_loop(fun, samples, initial_state, params, _templates, kernel_opts, compiler, opts) do
    {stacked?, opts} = Keyword.pop(opts, :stacked, false)
    opts = [compiler: compiler, kernel_opts: kernel_opts] ++ opts

    {outputs, final} =
      run_scan_stacked(fun, ExHdl.DSP.ScanLoop.stack(samples), initial_state, params, opts)

    if stacked?, do: {outputs, final}, else: {unstack(outputs, length(samples)), final}
  end

  @doc """
  Like `run_scan/5`, but `samples` is one container whose tensors carry the
  sample index as first axis (e.g. `{i, q}` with two `s16[n]` tensors), and
  the outputs come back the same way. This is the fast path: no per-sample
  Elixir data.

  Options: `:compiler` (default `EXLA` if available, else the Nx evaluator),
  `:kernel_opts`, and the width-check options of `analyze/3`. With EXLA the
  inputs are moved to `EXLA.Backend` first; the results stay there.
  """
  def run_scan_stacked(fun, samples, initial_state, params \\ [], opts \\ []) do
    {kernel_opts, opts} = Keyword.pop(opts, :kernel_opts)
    {compiler, opts} = Keyword.pop_lazy(opts, :compiler, &default_compiler/0)

    {own, compiler_opts} =
      Keyword.split(opts, [
        :param_ranges,
        :case_split,
        :split_threshold,
        :split_budget,
        :allow_float,
        :name
      ])

    sample_template =
      Nx.Defn.Composite.traverse(samples, fn t ->
        t = Nx.tensor(t)
        Nx.template(t.shape |> Tuple.delete_at(0), t.type)
      end)

    template = &Nx.Defn.Composite.traverse(&1, fn t -> Nx.to_template(Nx.tensor(t)) end)
    extra = if kernel_opts, do: [kernel_opts], else: []
    templates = [sample_template, template.(initial_state) | Enum.map(params, template)] ++ extra

    float? =
      templates
      |> Enum.take(2 + length(params))
      |> Nx.Defn.Composite.flatten_list()
      |> Enum.any?(&match?({:f, _}, &1.type))

    own = Keyword.put_new(own, :allow_float, float?)

    out_templates = checked_output_templates(fun, templates, own)
    n = [samples] |> Nx.Defn.Composite.flatten_list() |> hd() |> Nx.axis_size(0)

    # jit with BinaryBackend arguments is several times slower than with
    # arguments that already live on the compiler's backend.
    move = fn container ->
      if compiler == EXLA,
        do:
          Nx.Defn.Composite.traverse(container, &Nx.backend_transfer(Nx.tensor(&1), EXLA.Backend)),
        else: container
    end

    loop =
      Nx.Defn.jit(&ExHdl.DSP.ScanLoop.loop/4, Keyword.put(compiler_opts, :compiler, compiler))

    loop.(move.(samples), move.(initial_state), move.(List.to_tuple(params)),
      step: fun,
      kernel_opts: kernel_opts,
      outputs: out_templates,
      n: n
    )
  end

  # The width check depends only on the kernel, the argument types/shapes and
  # the options, so its result (the output templates) is cached per VM.
  defp checked_output_templates(fun, templates, own) do
    key = {__MODULE__, :checked, fun, templates, own}

    case :persistent_term.get(key, nil) do
      nil ->
        traced = fun |> Nx.Defn.debug_expr() |> apply(templates)

        case analyze_expr(traced, own) do
          {:ok, _graph} -> :ok
          {:error, error} -> raise error
        end

        {out_templates, _} = traced
        out_templates = Nx.Defn.Composite.traverse(out_templates, &Nx.to_template/1)
        :persistent_term.put(key, out_templates)
        out_templates

      out_templates ->
        out_templates
    end
  end

  defp default_compiler, do: if(Code.ensure_loaded?(EXLA), do: EXLA, else: Nx.Defn.Evaluator)

  defp unstack(stacked, n) do
    for i <- 0..(n - 1)//1 do
      Nx.Defn.Composite.traverse(
        stacked,
        &Nx.squeeze(Nx.slice_along_axis(&1, i, 1, axis: 0), axes: [0])
      )
    end
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
