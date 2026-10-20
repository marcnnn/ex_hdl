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
  `:channels`, `:state_mem` and `:ram_latency` (state of all channels in
  a memory, see `ExHdl.Backends.SystemVerilog.Scan`), timing overrides
  (`:clock_mhz`, `:dsp_latency`, ...), and everything `analyze/3` accepts.

  Returns `{:ok, %ExHdl.IR.Scan{}}` or `{:error, %NxFixed.RangeError{} | %ScheduleError{}}`.
  """
  def analyze_scan(fun, args, opts) when is_function(fun) and is_list(args) do
    state_arg = Keyword.fetch!(opts, :state)

    output = fun |> Nx.Defn.debug_expr() |> apply(args)

    with :ok <- check_scan_shape(output),
         {:ok, graph} <- NxFixed.analyze_expr(output, opts) do
      {out_ids, next_ids} = graph.outputs
      state_indices = param_indices(args, state_arg)

      params_by_index =
        for id <- graph.order,
            graph.nodes[id].op == :parameter,
            into: %{},
            do: {graph.nodes[id].attrs, id}

      leaf_params = Enum.map(state_indices, &Map.get(params_by_index, &1))

      with :ok <- check_state_types(args, state_arg, graph, next_ids),
           {:ok, scan} <-
             ExHdl.Passes.Recurrence.run(graph, leaf_params, out_ids, next_ids, opts) do
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

  @doc """
  Composes stream kernels into one: the output of each stage is the sample
  of the next, and the result is a single kernel (one pipeline, one clock
  enable) whose state is the tuple of the stages' states. The recurrence
  analysis keeps every stage's loop separate (`ExHdl.IR.Scan`), so a
  cascade of `k` filters needs the `ii`/`channels` of its slowest stage,
  not `k` times that.

  `stages` is a list of keyword lists, each with `:fun`, `:args` (argument
  templates; keyword lists are kernel options and are passed as given),
  `:state` (index of the state argument) and optionally `:init`,
  `:param_ranges` (per-leaf, indexed over the stage's own arguments),
  `:param_names` and `:name`.

  Returns `[fun:, args:, state: 1, init:, param_ranges:, param_names:]`
  for `analyze_scan/3` and `scan_to_sv/3` (pass the rest of the keyword list
  as options). The composed kernel is `step(sample, states, params...)`
  with the parameter arguments of all stages in order; their port names
  are the stages' names prefixed by the stage's `:name` (default
  `s<k>`): `"eq1_coef"`.

      spec = ExHdl.DSP.cascade([biquad(name: "eq1"), biquad(name: "eq2")])
      {:ok, design} =
        ExHdl.DSP.scan_to_sv(spec[:fun], spec[:args],
          Keyword.drop(spec, [:fun, :args]) ++ [channels: 16, state_mem: :block])

  Declared ranges of a later stage's sample are dropped: that value is
  computed, and its range is proven.
  """
  def cascade([_ | _] = stages) do
    stages =
      stages
      |> Enum.with_index()
      |> Enum.map(fn {st, k} ->
        args = Keyword.fetch!(st, :args)
        state = Keyword.fetch!(st, :state)
        roles = Enum.map(Enum.with_index(args), fn {a, i} -> role(a, i, state) end)

        %{
          k: k,
          fun: Keyword.fetch!(st, :fun),
          args: args,
          state: state,
          roles: roles,
          params: for({a, :param} <- Enum.zip(args, roles), do: a),
          init: Keyword.get_lazy(st, :init, fn -> zeros(Enum.at(args, state)) end),
          ranges: Keyword.get(st, :param_ranges, %{}),
          names: Keyword.get(st, :param_names, []),
          prefix: Keyword.get(st, :name, "s#{k}")
        }
      end)

    sample = hd(hd(stages).args)
    states = stages |> Enum.map(&Enum.at(&1.args, &1.state)) |> List.to_tuple()
    params = Enum.flat_map(stages, & &1.params)
    n_params = length(params)

    impl = fn [x, st | ps] ->
      {y, nexts, _} =
        Enum.reduce(stages, {x, [], ps}, fn stage, {x, nexts, ps} ->
          {own, ps} = Enum.split(ps, length(stage.params))

          {call, _} =
            stage.args
            |> Enum.zip(stage.roles)
            |> Enum.with_index()
            |> Enum.map_reduce(own, fn
              {{_, :sample}, _}, own -> {x, own}
              {{_, :state}, _}, own -> {elem(st, stage.k), own}
              {{opts, :opts}, _}, own -> {opts, own}
              {{_, :param}, _}, [p | own] -> {p, own}
            end)

          {y, next} = apply(stage.fun, call)
          {y, [next | nexts], ps}
        end)

      {y, nexts |> Enum.reverse() |> List.to_tuple()}
    end

    [
      fun: arity_fun(n_params + 2, impl),
      args: [sample, states | params],
      state: 1,
      init: stages |> Enum.map(& &1.init) |> List.to_tuple(),
      param_ranges: cascade_ranges(stages),
      param_names:
        Enum.flat_map(stages, fn st ->
          st.params
          |> Enum.with_index()
          |> Enum.map(fn {_, j} -> "#{st.prefix}_#{Enum.at(st.names, j) || "param#{j}"}" end)
        end)
    ]
  end

  defp role(a, _i, _state) when is_list(a), do: :opts
  defp role(_a, 0, _state), do: :sample
  defp role(_a, i, i), do: :state
  defp role(_a, _i, _state), do: :param

  defp zeros(template),
    do: Nx.Defn.Composite.traverse(template, &Nx.broadcast(Nx.tensor(0, type: &1.type), &1.shape))

  # Re-indexes the stages' per-leaf ranges over the composed arguments:
  # the first stage's sample, the states in stage order, then the
  # parameters in stage order.
  defp cascade_ranges(stages) do
    count = fn args -> args |> Enum.map(&leaf_count/1) |> Enum.sum() end
    sample_leaves = leaf_count(hd(hd(stages).args))
    state_total = stages |> Enum.map(&leaf_count(Enum.at(&1.args, &1.state))) |> Enum.sum()

    {ranges, _, _} =
      Enum.reduce(stages, {%{}, sample_leaves, sample_leaves + state_total}, fn st,
                                                                                {acc, s_off,
                                                                                 p_off} ->
        # global start of every argument of the stage
        {starts, _} =
          st.args
          |> Enum.zip(st.roles)
          |> Enum.map_reduce({s_off, p_off}, fn {a, r}, {s, p} ->
            case r do
              :sample -> {if(st.k == 0, do: 0), {s, p}}
              :state -> {s, {s + leaf_count(a), p}}
              :param -> {p, {s, p + leaf_count(a)}}
              :opts -> {nil, {s, p}}
            end
          end)

        local =
          st.args
          |> Enum.zip(starts)
          |> Enum.flat_map(fn {a, start} ->
            for j <- 0..(leaf_count(a) - 1)//1, do: start && start + j
          end)

        acc =
          for {i, r} <- st.ranges, g = Enum.at(local, i), g != nil, into: acc, do: {g, r}

        {acc, s_off + leaf_count(Enum.at(st.args, st.state)), p_off + count.(st.params)}
      end)

    ranges
  end

  # A function of `n` arguments that calls `impl` with the argument list.
  defp arity_fun(n, impl) do
    vars = Macro.generate_arguments(n, __MODULE__)

    {fun, _} =
      Code.eval_quoted(
        quote do
          fn unquote_splicing(vars) -> var!(impl).([unquote_splicing(vars)]) end
        end,
        impl: impl
      )

    fun
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
