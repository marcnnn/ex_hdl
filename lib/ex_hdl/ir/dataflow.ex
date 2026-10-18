defmodule ExHdl.IR.Dataflow do
  @moduledoc """
  Backend-independent dataflow graph built from a traced `Nx.Defn.Expr`.

  Nodes are stored in topological order (inputs before users). `:metadata`
  wrappers are dropped; Nx blocks are either kept as dedicated ops (`:take`)
  or inlined through their default implementation.
  """

  defmodule Node do
    @moduledoc """
    One operation. `inputs` are node ids, `attrs` holds non-tensor arguments
    (parameter index, constant value, constant tensor, ...). `range` is filled
    in by `ExHdl.Passes.WidthCheck`.
    """
    defstruct [:id, :op, :inputs, :attrs, :type, :shape, :range]
  end

  defstruct nodes: %{}, order: [], outputs: nil

  @type t :: %__MODULE__{
          nodes: %{non_neg_integer() => %Node{}},
          order: [non_neg_integer()],
          outputs: term()
        }

  # Ops whose tensor arguments are all data inputs and whose remaining
  # arguments do not matter for value ranges.
  @elementwise ~w(add subtract multiply negate abs min max clip select
                  right_shift left_shift bitwise_and bitwise_or bitwise_xor
                  equal not_equal less less_equal greater greater_equal
                  logical_and logical_or logical_not)a

  # Ops that only move values around without changing them.
  @shape_only ~w(reshape broadcast squeeze transpose)a

  @doc """
  Builds the graph from the output container of a traced defn (a tensor
  expression or nested tuples of them). The tuple structure is kept in
  `outputs`, with node ids in place of tensors.
  """
  def from_expr(output) do
    {outputs, state} =
      convert_container(output, %{
        graph: %__MODULE__{},
        memo: %{},
        scope: :root,
        env: %{},
        next: 0
      })

    %{state.graph | outputs: outputs, order: Enum.reverse(state.graph.order)}
  end

  @doc """
  The constant values behind a node, looking through value-preserving ops
  (`as_type`, `reshape`), or `nil` if the node is not a constant tensor.
  """
  def constant_values(%__MODULE__{} = graph, id) do
    case graph.nodes[id] do
      %{op: :tensor, attrs: t} -> Nx.to_flat_list(t)
      %{op: :constant, attrs: v} -> [v]
      %{op: op, inputs: [x]} when op in [:as_type, :reshape] -> constant_values(graph, x)
      _ -> nil
    end
  end

  @doc "Output node ids, flattened."
  def output_ids(%__MODULE__{outputs: outputs}), do: flatten(outputs)

  defp flatten(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&flatten/1)
  defp flatten(id) when is_integer(id), do: [id]

  defp convert_container(t, state) when is_tuple(t) do
    {items, state} = t |> Tuple.to_list() |> Enum.map_reduce(state, &convert_container/2)
    {List.to_tuple(items), state}
  end

  defp convert_container(%Nx.Tensor{} = t, state), do: convert(t, state)

  defp convert(%Nx.Tensor{data: %Nx.Defn.Expr{id: expr_id, op: op, args: args}} = t, state) do
    key = {state.scope, expr_id}

    case state.memo do
      %{^key => id} -> {id, state}
      _ -> convert_op(op, args, t, key, state)
    end
  end

  # Parameters of an inlined block refer to the block's inputs.
  defp convert_op(:parameter, [index], _t, key, %{scope: scope} = state) when scope != :root do
    id = Map.fetch!(state.env, index)
    {id, put_in(state.memo[key], id)}
  end

  defp convert_op(:parameter, [index], t, key, state),
    do: add(state, key, :parameter, [], index, t)

  defp convert_op(:constant, [value], t, key, state), do: add(state, key, :constant, [], value, t)
  defp convert_op(:tensor, [tensor], t, key, state), do: add(state, key, :tensor, [], tensor, t)

  defp convert_op(:metadata, [expr, _meta], _t, key, state) do
    {id, state} = convert(expr, state)
    {id, put_in(state.memo[key], id)}
  end

  defp convert_op(:as_type, [x], t, key, state), do: unary(:as_type, x, t, key, state)

  defp convert_op(:concatenate, [tensors, axis], t, key, state) do
    {ids, state} = Enum.map_reduce(tensors, state, &convert/2)
    add(state, key, :concatenate, ids, axis, t)
  end

  defp convert_op(:slice, [x, starts, lengths, strides], t, key, state) do
    unless Enum.all?(starts, &is_integer/1),
      do: raise(ArgumentError, "ExHdl supports Nx.slice only with constant start indices")

    {id, state} = convert(x, state)
    add(state, key, :slice, [id], {starts, lengths, strides}, t)
  end

  defp convert_op(:dot, [a, contract_a, batch_a, b, contract_b, batch_b], t, key, state) do
    # The range rule assumes one sum of products per output element.
    if batch_a != [], do: raise(ArgumentError, "ExHdl does not support batched Nx.dot yet")

    {a_id, state} = convert(a, state)
    {b_id, state} = convert(b, state)
    add(state, key, :dot, [a_id, b_id], {contract_a, batch_a, contract_b, batch_b}, t)
  end

  defp convert_op(:sum, [x, opts], t, key, state) do
    {id, state} = convert(x, state)
    add(state, key, :sum, [id], opts, t)
  end

  defp convert_op(
         :block,
         [%Nx.Block.Take{axis: 0}, [table, indices], _default, _fun],
         t,
         key,
         state
       ) do
    {table_id, state} = convert(table, state)
    {idx_id, state} = convert(indices, state)
    add(state, key, :take, [table_id, idx_id], nil, t)
  end

  # Any other block: inline its default implementation.
  defp convert_op(:block, [_struct, inputs, default, _fun], _t, key, state) do
    {input_ids, state} = inputs |> List.wrap() |> Enum.map_reduce(state, &convert/2)
    outer = %{scope: state.scope, env: state.env}
    inner_env = input_ids |> Enum.with_index() |> Map.new(fn {id, i} -> {i, id} end)
    state = %{state | scope: make_ref(), env: inner_env}
    {id, state} = convert(default, state)
    state = %{state | scope: outer.scope, env: outer.env}
    {id, put_in(state.memo[key], id)}
  end

  defp convert_op(op, args, t, key, state) when op in @elementwise or op in @shape_only do
    {ids, state} =
      args
      |> Enum.filter(&match?(%Nx.Tensor{}, &1))
      |> Enum.map_reduce(state, &convert/2)

    add(state, key, op, ids, nil, t)
  end

  defp convert_op(op, _args, t, _key, _state) do
    raise ArgumentError,
          "ExHdl does not support Nx operation #{inspect(op)} (#{inspect(t.type)}#{inspect(t.shape)}) yet"
  end

  defp unary(op, x, t, key, state) do
    {id, state} = convert(x, state)
    add(state, key, op, [id], nil, t)
  end

  defp add(state, key, op, inputs, attrs, %Nx.Tensor{type: type, shape: shape}) do
    id = state.next
    node = %Node{id: id, op: op, inputs: inputs, attrs: attrs, type: type, shape: shape}

    graph = %{
      state.graph
      | nodes: Map.put(state.graph.nodes, id, node),
        order: [id | state.graph.order]
    }

    {id, %{state | graph: graph, next: id + 1, memo: Map.put(state.memo, key, id)}}
  end
end
