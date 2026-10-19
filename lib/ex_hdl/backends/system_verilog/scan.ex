defmodule ExHdl.Backends.SystemVerilog.Scan do
  @moduledoc """
  Emits a synthesisable SystemVerilog-2012 module for a stream kernel
  analysed by `ExHdl.DSP.analyze_scan/3`, bit-exact with the Nx reference.

  ## Interface

    * `s_axis_*` - one sample per beat. `tdata` holds the sample's tensor
      leaves in argument order, leaf 0 in the LSBs, each element in the
      width of its Nx type (two's complement), padded to whole bytes.
    * `m_axis_*` - one output per beat, packed the same way.
    * `p_<name>` - one input port per tensor leaf of the remaining
      arguments (gains, phase increments, ...), elements packed like
      `tdata`. They are read continuously, so change them only while the
      stream is idle.

  `rst_n` (synchronous, active low) loads the initial state (`:init`).

  ## Structure

  Every node of the range-annotated graph becomes signals of its proven
  width (signed or unsigned), one per tensor element; views (slices,
  concatenations, reshapes) are wiring. The schedule
  (`ExHdl.Passes.Schedule`, `ExHdl.Target.Timing`) decides the pipeline
  stage of every node; values crossing stages go through pipeline
  registers. Multiplies use the DSP48E1 register pattern (input, product
  and output registers), large tables become block RAM with a registered
  read, small ones LUT ROM. All pipeline registers share one clock enable
  `ce`, which stops the whole pipeline while the output is stalled, so
  backpressure costs no extra buffering.

  The state is read in stage `S`, where everything the state update needs
  from outside the loop is available, and written back at the end of the
  stage where the next state is complete. With `ii: n` the input accepts
  one sample every `n` enabled cycles. With `channels: n` the kernel holds
  `n` states and accepts one sample per cycle; samples belong to channels
  0, 1, ..., n-1, 0, ... in arrival order (reset starts at channel 0).

  Unsupported operations raise `UnsupportedError` naming the op.
  """

  import Bitwise

  alias ExHdl.Backends.SystemVerilog.Fir
  alias ExHdl.IR.Scan
  alias ExHdl.Passes.Schedule
  alias ExHdl.Target.Timing
  alias NxFixed.Dataflow
  alias NxFixed.IntSet

  defmodule UnsupportedError do
    defexception [:message]
  end

  defmodule Design do
    @moduledoc """
    A generated kernel module.

      * `source` - the SystemVerilog text of module `name`.
      * `latency` - cycles from accepting a sample to presenting its output
        (without stalls).
      * `ii`, `channels` - as in `ExHdl.IR.Scan`.
      * `state_stage`, `write_stage` - pipeline stages reading and writing
        the state.
      * `inputs`, `outputs` - the tdata fields:
        `%{index:, type:, shape:, offset:, bits:}` (`bits` per element).
      * `params` - the parameter ports: `%{port:, index:, type:, shape:, bits:}`.
      * `in_width`, `out_width` - tdata widths.
    """
    defstruct [
      :name,
      :source,
      :latency,
      :ii,
      :channels,
      :state_stage,
      :write_stage,
      :inputs,
      :outputs,
      :params,
      :in_width,
      :out_width
    ]
  end

  @elementwise ~w(add subtract multiply negate abs min max clip select
                  right_shift left_shift bitwise_and bitwise_or bitwise_xor
                  equal not_equal less less_equal greater greater_equal
                  logical_and logical_or logical_not)a

  @compare %{
    equal: "==",
    not_equal: "!=",
    less: "<",
    less_equal: "<=",
    greater: ">",
    greater_equal: ">="
  }

  @binary %{add: "+", subtract: "-", bitwise_and: "&", bitwise_or: "|", bitwise_xor: "^"}

  @doc """
  Generates the module for `scan`.

  Options:
    * `:name` - module name (default `"scan_kernel"`).
    * `:init` - initial state, a container shaped like the state argument
      (tensors, `NxFixed.Fixed`, integers); default all zeros.
    * `:param_names` - port names for the parameter arguments in order
      (default `param<i>` for argument `i`); ports are prefixed with `p_`.

  Returns a `%Design{}`; raises `UnsupportedError`.
  """
  def generate(%Scan{} = scan, opts \\ []) do
    name = Keyword.get(opts, :name, "scan_kernel")
    graph = scan.graph
    timing = scan.timing || Timing.new(opts)

    check_supported!(graph)

    layout = layout(scan, opts)
    {state_stage, sched} = schedule(scan, timing, layout)
    c = context(scan, timing, layout, state_stage, sched, %{})

    # FIR dot products become DSP chains with their own latency: plan them
    # on a first lowering, then schedule and lower again.
    fir =
      if Keyword.get(opts, :fir, :chain) == :chain,
        do: Fir.plan(Enum.reduce(graph.order, c, &lower/2), scan),
        else: %{}

    c =
      if fir == %{} do
        c
      else
        {state_stage, sched} = schedule(scan, timing, layout, Fir.costs(fir))
        context(scan, timing, layout, state_stage, sched, fir)
      end

    c = Enum.reduce(graph.order, c, &lower/2)
    {c, write_stage, state_writes} = state_writes(c, scan)

    spacing = scan.ii
    loop = write_stage - state_stage + 1

    if loop > spacing do
      raise UnsupportedError,
            "scan: the generated state update needs #{loop} cycles (stages #{state_stage}-#{write_stage}), " <>
              "more than ii: #{spacing}; this is a mismatch between the schedule and the generator"
    end

    {c, latency, out_expr} = outputs(c, scan)
    depth = max(latency, write_stage)

    source =
      emit(c, %{
        name: name,
        scan: scan,
        latency: latency,
        depth: depth,
        write_stage: write_stage,
        state_writes: state_writes,
        out_expr: out_expr
      })

    %Design{
      name: name,
      source: source,
      latency: latency,
      ii: scan.ii,
      channels: scan.channels,
      state_stage: state_stage,
      write_stage: write_stage,
      inputs: layout.inputs,
      outputs: layout.outputs,
      params: layout.params,
      in_width: layout.in_width,
      out_width: layout.out_width
    }
  end

  defp context(scan, timing, layout, state_stage, sched, fir) do
    %{
      graph: scan.graph,
      timing: timing,
      sched: sched,
      layout: layout,
      state_stage: state_stage,
      channels: scan.channels,
      sigs: %{},
      defs: %{},
      decls: [],
      assigns: [],
      ffs: [],
      sample_ffs: [],
      blocks: [],
      elems: %{},
      roms: %{},
      fir: fir
    }
  end

  # -- checks ------------------------------------------------------------------------------

  @supported [
               :parameter,
               :constant,
               :tensor,
               :as_type,
               :reshape,
               :squeeze,
               :broadcast,
               :transpose,
               :slice,
               :concatenate,
               :take,
               :dot,
               :sum
             ] ++ @elementwise

  defp check_supported!(graph) do
    for id <- graph.order do
      node = graph.nodes[id]

      cond do
        node.op not in @supported ->
          unsupported!(graph, node, "is not supported by the SystemVerilog backend")

        match?({k, _} when k not in [:s, :u], node.type) ->
          unsupported!(graph, node, "is floating point (#{inspect(node.type)})")

        not is_list(node.range) or node.range == [] ->
          unsupported!(graph, node, "has no proven integer range")

        true ->
          :ok
      end
    end
  end

  defp unsupported!(graph, node, problem) do
    inputs = Enum.map_join(node.inputs, ", ", &"#{graph.nodes[&1].op}")

    raise UnsupportedError,
          "scan: Nx operation #{inspect(node.op)} (node #{node.id}, #{inspect(node.type)}#{inspect(node.shape)}, " <>
            "inputs: #{inputs}) #{problem}"
  end

  # -- layout of ports -------------------------------------------------------------------------

  defp layout(scan, opts) do
    by_role = Enum.group_by(scan.args, & &1.role)
    sample = by_role |> Map.get(:sample, []) |> Enum.flat_map(& &1.leaves)
    state = by_role |> Map.get(:state, []) |> Enum.flat_map(& &1.leaves)
    param_args = Map.get(by_role, :param, [])
    names = Keyword.get(opts, :param_names, [])

    {inputs, in_bits} = fields(sample)

    outputs =
      scan.outputs
      |> flatten()
      |> Enum.map(fn id ->
        %{index: id, type: scan.graph.nodes[id].type, shape: scan.graph.nodes[id].shape}
      end)

    {outputs, out_bits} = fields(outputs)

    params =
      param_args
      |> Enum.with_index()
      |> Enum.flat_map(fn {arg, k} ->
        base = Enum.at(names, k) || "param#{arg.arg}"

        case arg.leaves do
          [leaf] -> [{base, leaf}]
          leaves -> leaves |> Enum.with_index() |> Enum.map(fn {l, i} -> {"#{base}_#{i}", l} end)
        end
      end)
      |> Enum.map(fn {n, leaf} ->
        Map.merge(leaf, %{port: "p_#{n}", bits: type_bits(leaf.type)})
      end)

    params_by_index = Map.new(params, &{&1.index, &1})
    inputs_by_index = Map.new(inputs, &{&1.index, &1})

    init = init_values(Keyword.get(opts, :init), state)

    states =
      state
      |> Enum.with_index()
      |> Enum.map(fn {leaf, k} -> Map.merge(leaf, %{leaf: k, init: Enum.at(init, k)}) end)

    %{
      inputs: inputs,
      outputs: outputs,
      params: params,
      params_by_index: params_by_index,
      inputs_by_index: inputs_by_index,
      states: states,
      states_by_index: Map.new(states, &{&1.index, &1}),
      in_width: byte_align(in_bits),
      out_width: byte_align(out_bits)
    }
  end

  defp fields(leaves) do
    Enum.map_reduce(leaves, 0, fn leaf, offset ->
      bits = type_bits(leaf.type)
      field = Map.merge(leaf, %{offset: offset, bits: bits})
      {field, offset + bits * size(leaf.shape)}
    end)
  end

  defp init_values(nil, states), do: Enum.map(states, &List.duplicate(0, size(&1.shape)))

  defp init_values(init, states) do
    values =
      [init]
      |> Nx.Defn.Composite.flatten_list()
      |> Enum.map(&(&1 |> Nx.tensor() |> Nx.to_flat_list()))

    unless length(values) == length(states) and
             Enum.all?(Enum.zip(values, states), fn {v, s} -> length(v) == size(s.shape) end),
           do: raise(ArgumentError, "scan: :init must be shaped like the state argument")

    values
  end

  defp byte_align(0), do: 8
  defp byte_align(bits), do: div(bits + 7, 8) * 8

  # -- schedule ------------------------------------------------------------------------------

  # Static values (parameter ports, constants and what is computed only from
  # them) need no pipeline registers. The state is read in the stage where
  # every non-static value entering the loop is available.
  defp schedule(scan, timing, layout, costs \\ %{}) do
    graph = scan.graph
    base = Schedule.asap(graph, graph.order, timing, %{}, costs)
    static = static_nodes(graph, layout)

    next_ids = flatten(scan.next_state)

    entering =
      for(
        id <- MapSet.to_list(scan.recurrence),
        input <- graph.nodes[id].inputs,
        not MapSet.member?(scan.recurrence, input),
        do: input
      ) ++ Enum.reject(next_ids, &MapSet.member?(scan.recurrence, &1))

    stage =
      entering
      |> Enum.uniq()
      |> Enum.reject(&(MapSet.member?(static, &1) or &1 in scan.state_params))
      |> Enum.map(fn id -> available(base[id].at) end)
      |> Enum.max(fn -> 0 end)

    seeds = Map.new(scan.state_params, &{&1, {stage, 0.0}})
    {stage, Schedule.asap(graph, graph.order, timing, seeds, costs)}
  end

  defp available({c, t}) when t == 0, do: c
  defp available({c, _t}), do: c + 1

  defp static_nodes(graph, layout) do
    Enum.reduce(graph.order, MapSet.new(), fn id, static ->
      node = graph.nodes[id]

      s =
        case node.op do
          :parameter -> Map.has_key?(layout.params_by_index, node.attrs)
          op when op in [:constant, :tensor] -> true
          _ -> Enum.all?(node.inputs, &MapSet.member?(static, &1))
        end

      if s, do: MapSet.put(static, id), else: static
    end)
  end

  defp exec_stage(c, id) do
    %{at: {cycle, _}, cost: cost} = c.sched[id]

    case cost do
      {:reg, k, _} -> cycle - k
      _ -> cycle
    end
  end

  # -- lowering --------------------------------------------------------------------------------

  defp lower(id, c) do
    node = c.graph.nodes[id]
    n = size(node.shape)

    {c, elems} =
      cond do
        node.op != :parameter and singleton?(node.range) ->
          [{v, v}] = node.range
          {c, List.duplicate({:lit, v}, n)}

        true ->
          lower_op(node.op, node, c)
      end

    %{c | elems: Map.put(c.elems, id, List.to_tuple(elems))}
  end

  defp singleton?([{v, v}]) when is_integer(v), do: true
  defp singleton?(_), do: false

  defp lower_op(:parameter, node, c) do
    l = c.layout
    index = node.attrs
    fmt = IntSet.bit_width(node.range)

    cond do
      field = l.inputs_by_index[index] ->
        map_c(0..(size(node.shape) - 1), c, fn e, c ->
          name = elem_name(node, e)
          c = c |> new_sig(name, fmt, 0, false) |> define(name, {:in, index, e})
          lo = field.offset + e * field.bits
          {assign(c, name, "s_axis_tdata[#{lo} +: #{bits(fmt)}]"), {:sig, name}}
        end)

      port = l.params_by_index[index] ->
        map_c(0..(size(node.shape) - 1), c, fn e, c ->
          name = elem_name(node, e)
          c = new_sig(c, name, fmt, :static, false)
          {assign(c, name, "#{port.port}[#{e * port.bits} +: #{bits(fmt)}]"), {:sig, name}}
        end)

      state = l.states_by_index[index] ->
        state_read(c, node, state)
    end
  end

  defp lower_op(:constant, node, c), do: {c, List.duplicate({:lit, node.attrs}, size(node.shape))}

  defp lower_op(:tensor, node, c),
    do: {c, node.attrs |> Nx.to_flat_list() |> Enum.map(&{:lit, &1})}

  defp lower_op(op, node, c) when op in [:as_type, :reshape, :squeeze],
    do: {c, input_elems(c, node, 0)}

  defp lower_op(:broadcast, node, c) do
    [x] = node.inputs
    in_shape = c.graph.nodes[x].shape
    src = c.elems[x]

    elems =
      for i <- indices(node.shape) do
        idx =
          node.attrs
          |> Enum.with_index()
          |> Enum.map(fn {axis, k} ->
            if elem(in_shape, k) == 1, do: 0, else: Enum.at(i, axis)
          end)

        elem(src, flat(idx, in_shape))
      end

    {c, elems}
  end

  defp lower_op(:transpose, node, c) do
    [x] = node.inputs
    in_shape = c.graph.nodes[x].shape
    src = c.elems[x]
    axes = node.attrs

    elems =
      for i <- indices(node.shape) do
        idx = axes |> Enum.zip(i) |> Enum.sort() |> Enum.map(&elem(&1, 1))
        elem(src, flat(idx, in_shape))
      end

    {c, elems}
  end

  defp lower_op(:slice, node, c) do
    [x] = node.inputs
    in_shape = c.graph.nodes[x].shape
    src = c.elems[x]
    {starts, _lengths, strides} = node.attrs

    elems =
      for i <- indices(node.shape) do
        idx = Enum.zip_with([starts, strides, i], fn [s, st, k] -> s + k * st end)
        elem(src, flat(idx, in_shape))
      end

    {c, elems}
  end

  defp lower_op(:concatenate, node, c) do
    axis = node.attrs

    parts =
      Enum.map(node.inputs, fn x ->
        shape = c.graph.nodes[x].shape
        {shape, elem(shape, axis), c.elems[x]}
      end)

    elems =
      for i <- indices(node.shape) do
        pos = Enum.at(i, axis)

        {shape, local, src} =
          Enum.reduce_while(parts, pos, fn {shape, len, src}, pos ->
            if pos < len, do: {:halt, {shape, pos, src}}, else: {:cont, pos - len}
          end)

        elem(src, flat(List.replace_at(i, axis, local), shape))
      end

    {c, elems}
  end

  defp lower_op(op, node, c) when op in @elementwise do
    stage = exec_stage(c, node.id)
    operands = Enum.map(node.inputs, &{c.graph.nodes[&1].shape, c.elems[&1]})
    fmt = IntSet.bit_width(node.range)

    0..(size(node.shape) - 1)
    |> map_c(c, fn e, c ->
      i = multi(e, node.shape)
      refs = Enum.map(operands, fn {shape, src} -> elem(src, broadcast_index(i, shape)) end)
      name = elem_name(node, e)
      c = define(c, name, {:op, op, refs})

      if op == :multiply and match?({:reg, _, _}, c.sched[node.id].cost) and
           not Enum.all?(refs, &static?(c, &1)) do
        {:reg, k, _} = c.sched[node.id].cost
        product(c, name, refs, stage, k, fmt)
      else
        {c, expr} = expr(c, op, refs, stage, fmt)
        s = if Enum.all?(refs, &static?(c, &1)), do: :static, else: stage
        c = c |> new_sig(name, fmt, s, false) |> assign(name, expr)
        {c, {:sig, name}}
      end
    end)
  end

  defp lower_op(:take, node, c) do
    [table_id, idx_id] = node.inputs
    table = Dataflow.constant_tensor(c.graph, table_id)

    unless table && tuple_size(table.shape) == 1,
      do: unsupported!(c.graph, node, "needs a constant 1-D table")

    values = Nx.to_flat_list(table)
    stage = exec_stage(c, node.id)
    fmt = IntSet.bit_width(node.range)
    {c, rom} = rom(c, values, c.sched[node.id].cost)
    aw = max(1, ceil_log2(length(values)))

    c.elems[idx_id]
    |> Tuple.to_list()
    |> Enum.with_index()
    |> map_c(c, fn {ref, e}, c ->
      name = elem_name(node, e)

      case ref do
        {:lit, v} ->
          {c, {:lit, Enum.at(values, v)}}

        {:sig, _} ->
          {c, addr} = raw(c, ref, stage)
          addr = "#{aw}'(#{addr})"

          case rom do
            {:lut, fun} ->
              s = if static?(c, ref), do: :static, else: stage

              c =
                c
                |> new_sig(name, fmt, s, false)
                |> assign(name, "#{bits(fmt)}'(#{fun}(#{addr}))")

              {c, {:sig, name}}

            {:bram, mem, tfmt, k} ->
              q = "#{name}_q"
              c = c |> new_sig(q, tfmt, stage + 1, true) |> ff(q, "#{mem}[#{addr}]")
              {c, qd} = at(c, q, stage + k)
              c = c |> new_sig(name, fmt, stage + k, true) |> assign(name, "#{bits(fmt)}'(#{qd})")
              {c, {:sig, name}}
          end
      end
    end)
  end

  defp lower_op(:dot, node, c) do
    {_contract_a, batch_a, _contract_b, _batch_b} = node.attrs

    if batch_a != [], do: unsupported!(c.graph, node, "with batch axes is not supported")

    stage = exec_stage(c, node.id)
    {:reg, k, _} = c.sched[node.id].cost
    fmt = IntSet.bit_width(node.range)
    id = node.id

    0..(size(node.shape) - 1)
    |> map_c(c, fn e, c ->
      case c.fir do
        %{^id => %{elems: %{^e => groups}}} ->
          fir_chains(c, elem_name(node, e), groups, stage, k, fmt)

        _ ->
          reduce_products(c, elem_name(node, e), Fir.dot_pairs(c, node, e), stage, k, fmt)
      end
    end)
  end

  defp lower_op(:sum, node, c) do
    [x] = node.inputs

    if size(node.shape) != 1,
      do: unsupported!(c.graph, node, "over some axes is not supported (only full reductions)")

    stage = exec_stage(c, node.id)
    fmt = IntSet.bit_width(node.range)
    terms = c.elems[x] |> Tuple.to_list() |> Enum.map(&{&1, ref_range(c, &1)})
    name = elem_name(node, 0)

    {c, ref} =
      case c.sched[node.id].cost do
        {:reg, k, _} ->
          adder_tree(c, name, terms, stage, k, fmt)

        _ ->
          {c, expr} = sum_expr(c, Enum.map(terms, &elem(&1, 0)), stage, fmt)
          s = if Enum.all?(terms, &static?(c, elem(&1, 0))), do: :static, else: stage
          {c |> new_sig(name, fmt, s, false) |> assign(name, expr), {:sig, name}}
      end

    {c, [ref]}
  end

  defp input_elems(c, node, k), do: c.elems[Enum.at(node.inputs, k)] |> Tuple.to_list()

  # -- state -------------------------------------------------------------------------------

  defp state_read(c, node, state) do
    fmt = IntSet.bit_width(node.range)
    s = c.state_stage

    map_c(0..(size(node.shape) - 1), c, fn e, c ->
      name = elem_name(node, e)
      c = define(c, name, {:state, state.index, e, Enum.at(state.init, e)})

      if c.channels == 1 do
        {new_sig(c, name, fmt, s, true), {:sig, name}}
      else
        c = c |> new_sig(name, fmt, s, false) |> assign(name, "#{name}_mem[#{ch(s)}]")
        {c, {:sig, name}}
      end
    end)
  end

  # Delays every next-state element to the latest one's stage; returns the
  # write stage and `[{reg_or_mem_name, fmt, init, expr}]`.
  defp state_writes(c, scan) do
    graph = c.graph
    next_ids = flatten(scan.next_state)

    leaves =
      for {state, next_id} <- Enum.zip(c.layout.states, next_ids),
          param = Enum.find(scan.state_params, &(graph.nodes[&1].attrs == state.index)),
          do: {state, graph.nodes[param], next_id}

    for {_state, pnode, next_id} <- leaves,
        not IntSet.subtype?(graph.nodes[next_id].range, pnode.range) do
      raise UnsupportedError,
            "scan: next state (node #{next_id}) can leave the state's range " <>
              "(#{inspect(IntSet.bounds(graph.nodes[next_id].range))} vs #{inspect(IntSet.bounds(pnode.range))})"
    end

    write_stage =
      for {_, _, next_id} <- leaves,
          ref <- Tuple.to_list(c.elems[next_id]),
          not static?(c, ref),
          reduce: c.state_stage do
        acc -> max(acc, c.sigs[elem(ref, 1)].stage)
      end

    {writes, c} =
      Enum.flat_map_reduce(leaves, c, fn {state, pnode, next_id}, c ->
        fmt = IntSet.bit_width(pnode.range)

        c.elems[next_id]
        |> Tuple.to_list()
        |> Enum.with_index()
        |> Enum.map_reduce(c, fn {ref, e}, c ->
          {c, x, _} = operand(c, ref, write_stage)
          init = Enum.at(state.init, e)
          {{elem_name(pnode, e), fmt, init, "#{bits(fmt)}'(#{x})"}, c}
        end)
      end)

    {c, write_stage, writes}
  end

  # -- outputs --------------------------------------------------------------------------------

  defp outputs(c, scan) do
    refs =
      for id <- flatten(scan.outputs),
          ref <- Tuple.to_list(c.elems[id]),
          do: {id, ref}

    latency =
      refs
      |> Enum.reject(fn {_, ref} -> static?(c, ref) end)
      |> Enum.map(fn {_, {:sig, n}} ->
        s = c.sigs[n]
        if s.reg, do: s.stage, else: s.stage + 1
      end)
      |> Enum.max(fn -> 1 end)
      |> max(1)

    {c, parts} =
      map_c(refs, c, fn {id, ref}, c ->
        tb = type_bits(c.graph.nodes[id].type)

        case ref do
          {:lit, v} ->
            {c, lit(v, tb)}

          _ ->
            {c, x, _} = operand(c, ref, latency)
            {c, "#{tb}'(#{x})"}
        end
      end)

    used = Enum.reduce(refs, 0, fn {id, _}, acc -> acc + type_bits(c.graph.nodes[id].type) end)
    pad = c.layout.out_width - used
    parts = if pad > 0, do: ["#{pad}'d0" | Enum.reverse(parts)], else: Enum.reverse(parts)
    {c, latency, "{" <> Enum.join(parts, ", ") <> "}"}
  end

  # -- arithmetic ----------------------------------------------------------------------------

  # Every operand is used as a signed expression (unsigned signals get a
  # zero sign bit), extended to a common width that holds the operands and
  # the exact result, so SystemVerilog's width and sign rules cannot change
  # the value; the result is then cut to the node's proven width.
  defp expr(c, op, refs, stage, fmt) do
    w = bits(fmt)
    rsw = signed_bits(fmt)

    case op do
      op when is_map_key(@binary, op) ->
        {c, [a, b], _} = operands(c, refs, stage, rsw)
        {c, "#{w}'(#{a} #{@binary[op]} #{b})"}

      :multiply ->
        case Enum.find_index(refs, &power_of_two?/1) do
          nil ->
            {c, [a, b], _} = operands(c, refs, stage, rsw)
            {c, "#{w}'(#{a} * #{b})"}

          i ->
            {:lit, v} = Enum.at(refs, i)
            other = Enum.at(refs, 1 - i)
            {c, [x], _} = operands(c, [other], stage, rsw)
            {c, "#{w}'(#{x} <<< #{ceil_log2(v)})"}
        end

      :negate ->
        {c, [a], _} = operands(c, refs, stage, rsw)
        {c, "#{w}'(-#{a})"}

      :abs ->
        {c, [a], e} = operands(c, refs, stage, rsw)
        {c, "#{w}'((#{a} < #{lit(0, e)}) ? -#{a} : #{a})"}

      :min ->
        {c, [a, b], _} = operands(c, refs, stage, rsw)
        {c, "#{w}'((#{a} < #{b}) ? #{a} : #{b})"}

      :max ->
        {c, [a, b], _} = operands(c, refs, stage, rsw)
        {c, "#{w}'((#{a} > #{b}) ? #{a} : #{b})"}

      :clip ->
        # min(max(x, lo), hi), exactly as Nx.clip
        {c, [x, lo, hi], _} = operands(c, refs, stage, rsw)
        t = "((#{x} < #{lo}) ? #{lo} : #{x})"
        {c, "#{w}'((#{t} > #{hi}) ? #{hi} : #{t})"}

      op when is_map_key(@compare, op) ->
        {c, [a, b], _} = operands(c, refs, stage, 1)
        {c, "(#{a} #{@compare[op]} #{b})"}

      :select ->
        [p | rest] = refs

        case p do
          {:lit, v} ->
            {c, [x], _} =
              operands(c, [if(v != 0, do: hd(rest), else: List.last(rest))], stage, rsw)

            {c, "#{w}'(#{x})"}

          _ ->
            {c, pr} = raw(c, p, stage)
            {c, [a, b], _} = operands(c, rest, stage, rsw)
            {c, "#{w}'((|#{pr}) ? #{a} : #{b})"}
        end

      op when op in [:right_shift, :left_shift] ->
        [x, k] = refs
        {c, [a], _} = operands(c, [x], stage, rsw)
        {c, amount} = raw(c, k, stage)
        sv = if op == :right_shift, do: ">>>", else: "<<<"
        {c, "#{w}'(#{a} #{sv} #{amount})"}

      :logical_not ->
        {c, [a]} = raws(c, refs, stage)
        {c, "!(|#{a})"}

      :logical_and ->
        {c, [a, b]} = raws(c, refs, stage)
        {c, "((|#{a}) && (|#{b}))"}

      :logical_or ->
        {c, [a, b]} = raws(c, refs, stage)
        {c, "((|#{a}) || (|#{b}))"}
    end
  end

  # Signed operand expressions extended to a common width (at least `min`).
  defp operands(c, refs, stage, min) do
    {c, ops} =
      Enum.map_reduce(refs, c, fn ref, c ->
        {c, x, sw} = operand(c, ref, stage)
        {{ref, x, sw}, c}
      end)
      |> swap()

    e = ops |> Enum.map(&elem(&1, 2)) |> Enum.max() |> max(min)

    exprs =
      Enum.map(ops, fn
        {{:lit, v}, _, _} -> lit(v, e)
        {_, x, ^e} -> x
        {_, x, _} -> "#{e}'(#{x})"
      end)

    {c, exprs, e}
  end

  defp raws(c, refs, stage) do
    Enum.map_reduce(refs, c, fn ref, c ->
      {c, x} = raw(c, ref, stage)
      {x, c}
    end)
    |> swap()
  end

  # `{c, signed_expr, signed_width}` of a value used in `stage`.
  defp operand(c, {:lit, v}, _stage), do: {c, lit(v, lit_bits(v)), lit_bits(v)}

  defp operand(c, {:sig, name}, stage) do
    {c, x} = at(c, name, stage)
    s = c.sigs[name]
    if s.signed, do: {c, x, s.bits}, else: {c, "signed'({1'b0, #{x}})", s.bits + 1}
  end

  # The bits of a non-negative value (indices, shift amounts) or for a
  # zero test.
  defp raw(c, {:lit, v}, _stage) when v >= 0, do: {c, "#{max(1, bit_len(v))}'d#{v}"}
  defp raw(c, {:lit, v}, _stage), do: {c, lit(v, lit_bits(v))}
  defp raw(c, {:sig, name}, stage), do: at(c, name, stage)

  defp sum_expr(c, refs, stage, fmt) do
    {c, xs, _} = operands(c, refs, stage, signed_bits(fmt))
    {c, "#{bits(fmt)}'(#{Enum.join(xs, " + ")})"}
  end

  # A DSP48E1 multiply of k cycles: input registers (k >= 2), the product,
  # then output registers.
  defp product(c, name, [a, b], stage, k, fmt) do
    {c, {pa, wa}} = mul_input(c, "#{name}_a", a, stage, k)
    {c, {pb, wb}} = mul_input(c, "#{name}_b", b, stage, k)
    mul_stage = if k >= 2, do: stage + 1, else: stage
    p = "#{name}_p"
    c = c |> new_sig(p, {:s, wa + wb}, mul_stage, false) |> assign(p, "#{pa} * #{pb}")
    {c, pd} = at(c, p, stage + k)
    c = c |> new_sig(name, fmt, stage + k, true) |> assign(name, "#{bits(fmt)}'(#{pd})")
    {c, {:sig, name}}
  end

  defp mul_input(c, _reg, {:lit, v}, _stage, _k), do: {c, {lit(v, lit_bits(v)), lit_bits(v)}}

  defp mul_input(c, reg, ref, stage, k) do
    {c, x, sw} = operand(c, ref, stage)

    if k >= 2 and not static?(c, ref) do
      c = c |> new_sig(reg, {:s, sw}, stage + 1, true) |> ff(reg, x)
      {c, {reg, sw}}
    else
      {c, {x, sw}}
    end
  end

  # Sum of products for one dot output: zero terms dropped, positive powers
  # of two as shifts, the rest DSP multiplies, then a registered adder tree.
  defp reduce_products(c, name, pairs, stage, k, fmt) do
    dl = min(c.timing.dsp_latency, k)

    {c, terms} =
      pairs
      |> Enum.with_index()
      |> Enum.reduce({c, []}, fn {{a, b}, j}, {c, terms} ->
        tname = "#{name}_t#{j}"
        range = IntSet.multiply(ref_range(c, a), ref_range(c, b))
        tfmt = IntSet.bit_width(range)

        cond do
          a == {:lit, 0} or b == {:lit, 0} ->
            {c, terms}

          match?({{:lit, _}, {:lit, _}}, {a, b}) ->
            {{:lit, x}, {:lit, y}} = {a, b}
            {c, [{{:lit, x * y}, range} | terms]}

          static?(c, a) and static?(c, b) ->
            {c, expr} = expr(c, :multiply, [a, b], stage, tfmt)
            c = c |> new_sig(tname, tfmt, :static, false) |> assign(tname, expr)
            {c, [{{:sig, tname}, range} | terms]}

          power_of_two?(a) or power_of_two?(b) ->
            {c, expr} = expr(c, :multiply, [a, b], stage, tfmt)
            c = c |> new_sig(tname, tfmt, stage, false) |> assign(tname, expr)
            {c, [{{:sig, tname}, range} | terms]}

          true ->
            {c, ref} = product(c, tname, [a, b], stage, dl, tfmt)
            {c, [{ref, range} | terms]}
        end
      end)

    adder_tree(c, name, Enum.reverse(terms), stage + dl, k - dl, fmt)
  end

  # FIR groups of one dot element (`Fir`) as transposed DSP chains from
  # `stage`, summed by an adder tree when there are several.
  defp fir_chains(c, name, groups, stage, k, fmt) do
    {c, terms} =
      groups
      |> Enum.with_index()
      |> map_c(c, fn {g, gi}, c -> fir_chain(c, "#{name}_f#{gi}", g, stage) end)

    lg = groups |> Enum.map(&Fir.chain_latency/1) |> Enum.max()
    adder_tree(c, name, terms, stage + lg, k - lg, fmt)
  end

  # One transposed chain: `P_k <= m_k * h_k + P_k+1`, P registers advancing
  # once per sample (enabled with the sample leaving the multiply stage).
  # Returns `{c, {P_0 ref, range}}`.
  defp fir_chain(c, name, g, stage) do
    lg = Fir.chain_latency(g)
    p_stage = stage + lg
    {c, x, xw} = operand(c, g.x0, stage)
    x_range = ref_range(c, g.x0)

    {c, acc} =
      g
      |> Fir.terms()
      |> Enum.reverse()
      |> Enum.reduce({c, nil}, fn {k, h, second}, {c, next} ->
        if h == 0 and next == nil do
          {c, nil}
        else
          {c, product, range} =
            if h == 0 do
              {c, nil, IntSet.singleton(0)}
            else
              fir_product(c, "#{name}_#{k}", g, {x, xw, x_range}, h, second, stage)
            end

          range = if next, do: IntSet.add(range, elem(next, 1)), else: range
          p = "#{name}_p#{k}"
          w = signed_bits(IntSet.bit_width(range))

          sum =
            [product, next && elem(next, 0)]
            |> Enum.reject(&is_nil/1)
            |> Enum.map_join(" + ", &"#{w}'(#{&1})")

          c = c |> new_sig(p, {:s, w}, p_stage, true) |> sample_ff(p_stage - 1, p, sum)

          {c, {p, range}}
        end
      end)

    case acc do
      nil -> {c, {{:lit, 0}, IntSet.singleton(0)}}
      {p, range} -> {c, {{:sig, p}, range}}
    end
  end

  # Input registers (and pre-adder register) of one tap; returns the
  # product expression `m * h` and its range.
  defp fir_product(c, name, g, {x, xw, x_range}, h, second, stage) do
    xr = "#{name}_x"
    c = c |> new_sig(xr, {:s, xw}, stage + 1, true) |> ff(xr, x)

    {c, m, m_range} =
      case {g.fold, second} do
        {nil, _} ->
          {c, xr, x_range}

        {_, nil} ->
          ad = "#{name}_ad"
          c = c |> new_sig(ad, {:s, xw}, stage + 2, true) |> ff(ad, xr)
          {c, ad, x_range}

        {_, {sign, ref}} ->
          {c, y, yw} = operand(c, ref, stage)
          yr = "#{name}_y"
          c = c |> new_sig(yr, {:s, yw}, stage + 1, true) |> ff(yr, y)

          range =
            if sign == :add,
              do: IntSet.add(x_range, ref_range(c, ref)),
              else: IntSet.subtract(x_range, ref_range(c, ref))

          aw = signed_bits(IntSet.bit_width(range))
          ad = "#{name}_ad"
          op = if sign == :add, do: "+", else: "-"

          c =
            c
            |> new_sig(ad, {:s, aw}, stage + 2, true)
            |> ff(ad, "#{aw}'(#{aw}'(#{xr}) #{op} #{aw}'(#{yr}))")

          {c, ad, range}
      end

    {c, "#{m} * #{tap(h)}", IntSet.multiply(m_range, IntSet.singleton(h))}
  end

  # A tap constant for a DSP multiplier input. Synthesis drops the constant
  # zero LSBs of an even tap, and Yosys then no longer packs the post-adder
  # into the DSP; `tap_lsb` (high only in reset, when the partial sums are
  # held at zero anyway) keeps the LSB a signal.
  defp tap(h) do
    w = lit_bits(h)
    if band(h, 1) == 1, do: lit(h, w), else: "$signed(#{lit(h, w)} | #{w}'(tap_lsb))"
  end

  defp sample_ff(c, stage, name, expr),
    do: %{c | sample_ffs: [{stage, name, expr} | c.sample_ffs]}

  # Registered binary adder tree from `stage`; the result is delayed to
  # `stage + k` and cut to `fmt`.
  defp adder_tree(c, name, terms, stage, k, fmt) do
    {lits, terms} = Enum.split_with(terms, &match?({{:lit, _}, _}, &1))
    constant = lits |> Enum.map(fn {{:lit, v}, _} -> v end) |> Enum.sum()

    terms =
      if constant != 0 or terms == [],
        do: terms ++ [{{:lit, constant}, IntSet.singleton(constant)}],
        else: terms

    {c, root, level} = tree_levels(c, name, terms, stage, 0)

    if level > k do
      raise UnsupportedError,
            "scan: adder tree for #{name} needs #{level} cycles, the schedule gives #{k}"
    end

    case root do
      {{:lit, v}, _} ->
        {c, {:lit, v}}

      {ref, _} ->
        end_stage = stage + k

        s =
          if static?(c, ref), do: :static, else: end_stage

        {c, x, _} = operand(c, ref, end_stage)
        c = c |> new_sig(name, fmt, s, true) |> assign(name, "#{bits(fmt)}'(#{x})")
        {c, {:sig, name}}
    end
  end

  defp tree_levels(c, _name, [single], _stage, level), do: {c, single, level}

  defp tree_levels(c, name, terms, stage, level) do
    at_stage = stage + level

    {c, next} =
      terms
      |> Enum.chunk_every(2)
      |> Enum.with_index()
      |> Enum.map_reduce(c, fn
        {[single], _j}, c ->
          {single, c}

        {[{a, ra}, {b, rb}], j}, c ->
          range = IntSet.add(ra, rb)
          fmt = IntSet.bit_width(range)
          sname = "#{name}_s#{level}_#{j}"
          {c, [x, y], _} = operands(c, [a, b], at_stage, signed_bits(fmt))

          c =
            if static?(c, a) and static?(c, b),
              do:
                c
                |> new_sig(sname, fmt, :static, false)
                |> assign(sname, "#{bits(fmt)}'(#{x} + #{y})"),
              else:
                c
                |> new_sig(sname, fmt, at_stage + 1, true)
                |> ff(sname, "#{bits(fmt)}'(#{x} + #{y})")

          {{{:sig, sname}, range}, c}
      end)
      |> swap()

    tree_levels(c, name, next, stage, level + 1)
  end

  # -- tables ----------------------------------------------------------------------------------

  # One ROM per distinct table and kind; block RAM ROMs can be read by
  # several takes (dual-port).
  defp rom(c, values, cost) do
    tfmt = values |> IntSet.from_list() |> IntSet.widen() |> IntSet.bit_width()
    key = {values, cost}

    case c.roms do
      %{^key => rom} ->
        {c, rom}

      _ ->
        id = map_size(c.roms)
        aw = max(1, ceil_log2(length(values)))
        decl = decl_type(tfmt)

        {rom, block} =
          case cost do
            {:reg, k, _} ->
              mem = "rom#{id}"

              init =
                values
                |> Enum.with_index()
                |> Enum.map(fn {v, i} -> "    #{mem}[#{i}] = #{lit(v, bits(tfmt))};\n" end)

              {{:bram, mem, tfmt, k},
               [
                 "  #{decl} #{mem} [#{length(values)}];\n",
                 "  initial begin\n",
                 init,
                 "  end\n\n"
               ]}

            _ ->
              fun = "rom#{id}_f"

              cases =
                values
                |> Enum.with_index()
                |> Enum.map(fn {v, i} ->
                  "      #{aw}'d#{i}: #{fun} = #{lit(v, bits(tfmt))};\n"
                end)

              {{:lut, fun},
               [
                 "  function automatic #{decl} #{fun}(input logic [#{aw - 1}:0] a);\n",
                 "    case (a)\n",
                 cases,
                 "      default: #{fun} = '0;\n",
                 "    endcase\n",
                 "  endfunction\n\n"
               ]}
          end

        {%{c | roms: Map.put(c.roms, key, rom), blocks: [block | c.blocks]}, rom}
    end
  end

  # -- signals ---------------------------------------------------------------------------------

  defp new_sig(c, name, {kind, bits}, stage, reg?) do
    if Map.has_key?(c.sigs, name), do: raise("scan backend: duplicate signal #{name}")
    sig = %{bits: bits, signed: kind == :s, stage: stage, reg: reg?}
    %{c | sigs: Map.put(c.sigs, name, sig), decls: [name | c.decls]}
  end

  # What a signal computes, for `Fir.plan/2`.
  defp define(c, name, def), do: %{c | defs: Map.put(c.defs, name, def)}

  defp assign(c, name, expr), do: %{c | assigns: ["  assign #{name} = #{expr};\n" | c.assigns]}
  defp ff(c, name, expr), do: %{c | ffs: ["      #{name} <= #{expr};\n" | c.ffs]}

  # `name` as seen in `stage`: through pipeline registers `<name>_d<k>`.
  defp at(c, name, stage) do
    s = c.sigs[name]

    cond do
      s.stage == :static or s.stage == stage ->
        {c, name}

      s.stage > stage ->
        raise "scan backend: #{name} (stage #{s.stage}) used in stage #{stage}"

      true ->
        d = "#{name}_d#{stage - s.stage}"

        if Map.has_key?(c.sigs, d) do
          {c, d}
        else
          {c, prev} = at(c, name, stage - 1)
          kind = if s.signed, do: :s, else: :u
          {c |> new_sig(d, {kind, s.bits}, stage, true) |> ff(d, prev), d}
        end
    end
  end

  defp static?(_c, {:lit, _}), do: true
  defp static?(c, {:sig, name}), do: c.sigs[name].stage == :static

  defp ref_range(_c, {:lit, v}), do: IntSet.singleton(v)

  defp ref_range(c, {:sig, name}) do
    s = c.sigs[name]

    if s.signed,
      do: IntSet.range(-(1 <<< (s.bits - 1)), (1 <<< (s.bits - 1)) - 1),
      else: IntSet.range(0, (1 <<< s.bits) - 1)
  end

  defp power_of_two?({:lit, v}) when v > 0, do: band(v, v - 1) == 0
  defp power_of_two?(_), do: false

  # -- emission --------------------------------------------------------------------------------

  defp emit(c, d) do
    l = c.layout
    scan = d.scan
    depth = d.depth
    s = c.state_stage
    w = d.write_stage
    n = scan.channels

    params =
      Enum.map(l.params, fn p ->
        "  input  logic [#{p.bits * size(p.shape) - 1}:0] #{p.port},\n"
      end)

    decls =
      c.decls
      |> Enum.reverse()
      |> Enum.reject(&state_reg?(c, &1, d.state_writes))
      |> Enum.map(fn name ->
        sig = c.sigs[name]
        "  #{decl_type({if(sig.signed, do: :s, else: :u), sig.bits})} #{name};\n"
      end)

    shift =
      if depth == 1,
        do: "vld_0",
        else: "{vld[#{depth - 1}:1], vld_0}"

    control = [
      "  // control: one clock enable for the whole pipeline\n",
      "  logic ce;\n",
      "  logic issue_ok;\n",
      "  logic vld_0;\n",
      "  logic [#{depth}:1] vld;  // vld[k]: stage k holds a sample\n",
      "  assign ce = !#{valid(d.latency)} || m_axis_tready;\n",
      "  assign s_axis_tready = ce && issue_ok;\n",
      "  assign vld_0 = s_axis_tvalid && issue_ok;\n",
      "  always_ff @(posedge clk) begin\n",
      "    if (!rst_n) vld <= '0;\n",
      "    else if (ce) vld <= #{shift};\n",
      "  end\n"
    ]

    throttle =
      if n > 1 or scan.ii == 1 do
        "  assign issue_ok = 1'b1;\n"
      else
        cw = max(1, bit_len(scan.ii - 1))
        last = "#{cw}'d#{scan.ii - 1}"

        [
          "  // one sample every #{scan.ii} enabled cycles\n",
          "  logic [#{cw - 1}:0] gap;\n",
          "  assign issue_ok = (gap == #{last});\n",
          "  always_ff @(posedge clk) begin\n",
          "    if (!rst_n) gap <= #{last};\n",
          "    else if (ce) gap <= vld_0 ? #{cw}'d0 : (issue_ok ? gap : gap + #{cw}'d1);\n",
          "  end\n"
        ]
      end

    channel =
      if n > 1 do
        cw = max(1, bit_len(n - 1))
        regs = Enum.map(0..depth, &"  logic [#{cw - 1}:0] #{ch(&1)};\n")
        pipe = Enum.map(1..depth//1, &"      #{ch(&1)} <= #{ch(&1 - 1)};\n")

        [
          "  // channel of the sample in each stage, round robin in arrival order\n",
          regs,
          "  always_ff @(posedge clk) begin\n",
          "    if (!rst_n) #{ch(0)} <= '0;\n",
          "    else if (ce && vld_0) #{ch(0)} <= (#{ch(0)} == #{cw}'d#{n - 1}) ? '0 : #{ch(0)} + #{cw}'d1;\n",
          "  end\n",
          "  always_ff @(posedge clk) begin\n",
          "    if (ce) begin\n",
          pipe,
          "    end\n",
          "  end\n"
        ]
      else
        []
      end

    {state_decls, state_logic} = state_logic(d.state_writes, n, s, w)
    sample_logic = sample_logic(c)

    ffs =
      case c.ffs do
        [] ->
          []

        ffs ->
          [
            "  always_ff @(posedge clk) begin\n    if (ce) begin\n",
            Enum.reverse(ffs),
            "    end\n  end\n"
          ]
      end

    IO.iodata_to_binary([
      "// Generated by ExHdl from a stream kernel. Do not edit.\n",
      "// #{d.name}: latency #{d.latency}, ii #{scan.ii}, channels #{n}\n",
      "// s_axis_tdata: #{describe_fields(l.inputs)}\n",
      "// m_axis_tdata: #{describe_fields(l.outputs)}\n",
      "/* verilator lint_off UNUSEDSIGNAL */\n",
      "module #{d.name} (\n",
      "  input  logic clk,\n",
      "  input  logic rst_n,\n",
      params,
      "  input  logic [#{l.in_width - 1}:0] s_axis_tdata,\n",
      "  input  logic s_axis_tvalid,\n",
      "  output logic s_axis_tready,\n",
      "  output logic [#{l.out_width - 1}:0] m_axis_tdata,\n",
      "  output logic m_axis_tvalid,\n",
      "  input  logic m_axis_tready\n",
      ");\n\n",
      control,
      throttle,
      channel,
      "\n",
      Enum.reverse(c.blocks),
      state_decls,
      "  // datapath\n",
      decls,
      Enum.reverse(c.assigns),
      ffs,
      "\n",
      state_logic,
      sample_logic,
      "\n",
      "  assign m_axis_tvalid = #{valid(d.latency)};\n",
      "  assign m_axis_tdata = #{d.out_expr};\n",
      "endmodule\n",
      "/* verilator lint_on UNUSEDSIGNAL */\n"
    ])
  end

  defp state_logic([], _n, _s, _w), do: {[], []}

  defp state_logic(writes, n, s, w) do
    {decls, resets, updates, what} =
      if n == 1 do
        {
          Enum.map(writes, fn {name, fmt, _, _} -> "  #{decl_type(fmt)} #{name};\n" end),
          Enum.map(writes, fn {name, fmt, init, _} ->
            "      #{name} <= #{lit(init, bits(fmt))};\n"
          end),
          Enum.map(writes, fn {name, _, _, x} -> "      #{name} <= #{x};\n" end),
          "state"
        }
      else
        {
          Enum.map(writes, fn {name, fmt, _, _} -> "  #{decl_type(fmt)} #{name}_mem [#{n}];\n" end),
          Enum.map(writes, fn {name, fmt, init, _} ->
            "      for (int i = 0; i < #{n}; i++) #{name}_mem[i] <= #{lit(init, bits(fmt))};\n"
          end),
          Enum.map(writes, fn {name, _, _, x} -> "      #{name}_mem[#{ch(w)}] <= #{x};\n" end),
          "state of #{n} channels"
        }
      end

    {
      ["  // #{what}: read in stage #{s}, written at the end of stage #{w}\n", decls, "\n"],
      [
        "  always_ff @(posedge clk) begin\n",
        "    if (!rst_n) begin\n",
        resets,
        "    end else if (ce && #{valid(w)}) begin\n",
        updates,
        "    end\n",
        "  end\n"
      ]
    }
  end

  # Registers that advance once per sample (FIR partial sums): written with
  # the sample leaving their input stage, reset to zero.
  defp sample_logic(%{sample_ffs: []}), do: []

  defp sample_logic(c) do
    blocks =
      c.sample_ffs
      |> Enum.reverse()
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.sort()
      |> Enum.map(fn {stage, ffs} ->
        [
          "  always_ff @(posedge clk) begin\n",
          "    if (!rst_n) begin\n",
          Enum.map(ffs, fn {_, name, _} -> "      #{name} <= '0;\n" end),
          "    end else if (ce && #{valid(stage)}) begin\n",
          Enum.map(ffs, fn {_, name, expr} -> "      #{name} <= #{expr};\n" end),
          "    end\n",
          "  end\n"
        ]
      end)

    [
      "\n  // FIR partial sums: advance once per sample\n",
      "  logic tap_lsb;\n",
      "  assign tap_lsb = !rst_n;\n",
      blocks
    ]
  end

  defp valid(0), do: "vld_0"
  defp valid(k), do: "vld[#{k}]"

  defp ch(k), do: "ch_#{k}"

  defp state_reg?(c, name, writes) do
    c.channels == 1 and Enum.any?(writes, fn {n, _, _, _} -> n == name end)
  end

  defp describe_fields([]), do: "(none)"

  defp describe_fields(fields) do
    Enum.map_join(fields, ", ", fn f ->
      n = size(f.shape)
      hi = f.offset + f.bits * n - 1
      shape = if n == 1, do: "", else: inspect(f.shape)
      "[#{hi}:#{f.offset}] #{type_name(f.type)}#{shape}"
    end)
  end

  # -- helpers -----------------------------------------------------------------------------------

  defp elem_name(node, e) do
    if size(node.shape) == 1, do: "n#{node.id}", else: "n#{node.id}_#{e}"
  end

  defp decl_type({:s, b}), do: "logic signed [#{b - 1}:0]"
  defp decl_type({:u, b}), do: "logic [#{b - 1}:0]"

  defp bits({_, b}), do: b
  defp signed_bits({:s, b}), do: b
  defp signed_bits({:u, b}), do: b + 1

  defp type_bits({_, b}), do: b
  defp type_name({k, b}), do: "#{k}#{b}"

  # A signed literal of `w` bits (two's complement).
  defp lit(v, w), do: "#{w}'sh#{Integer.to_string(band(v, (1 <<< w) - 1), 16)}"

  defp lit_bits(v), do: v |> IntSet.singleton() |> IntSet.bit_width() |> signed_bits()

  defp bit_len(0), do: 0
  defp bit_len(v) when v > 0, do: 1 + bit_len(v >>> 1)

  defp ceil_log2(n) when n <= 1, do: 0
  defp ceil_log2(n), do: bit_len(n - 1)

  defp size(shape), do: shape |> Tuple.to_list() |> Enum.product()

  defp indices(shape), do: for(e <- 0..(size(shape) - 1)//1, do: multi(e, shape))

  defp multi(flat, shape) do
    shape
    |> Tuple.to_list()
    |> Enum.reverse()
    |> Enum.map_reduce(flat, fn d, rest -> {rem(rest, d), div(rest, d)} end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp flat(idx, shape) do
    idx
    |> Enum.zip(Tuple.to_list(shape))
    |> Enum.reduce(0, fn {i, d}, acc -> acc * d + i end)
  end

  # Index into an operand of `shape` for output index `i` (Nx broadcasting
  # aligns shapes on the right; size-1 axes repeat).
  defp broadcast_index(i, shape) do
    rank = tuple_size(shape)
    offset = length(i) - rank

    idx =
      for k <- 0..(rank - 1)//1,
          do: if(elem(shape, k) == 1, do: 0, else: Enum.at(i, k + offset))

    flat(idx, shape)
  end

  defp swap({a, b}), do: {b, a}

  # Enum.map_reduce with the context first: `fun.(x, c)` returns `{c, y}`.
  defp map_c(enum, c, fun) do
    {list, c} =
      Enum.map_reduce(enum, c, fn x, c ->
        {c, y} = fun.(x, c)
        {y, c}
      end)

    {c, list}
  end

  defp flatten(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&flatten/1)
  defp flatten(id) when is_integer(id), do: [id]
end
