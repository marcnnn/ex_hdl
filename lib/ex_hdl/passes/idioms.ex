defmodule ExHdl.Passes.Idioms do
  @moduledoc """
  Rewrites Nx idioms of a range-annotated graph into hardware operations
  that cost less than the Nx operations they are written with. The value of
  every rewritten node is unchanged, so the Nx reference stays the model.

    * `:wrap` - `((x + 2^(b-1)) & (2^b - 1)) - 2^(b-1)`, the signed wrap of
      `NxFixed.Primitives.wrap/2` and `ExHdl.DSP.wrap/2`: the low `b` bits
      of `x` as a signed value. Wiring, where the Nx form costs three adders.
      An accumulator `wrap(acc + x, b)` has a proven range without a clamp,
      so its loop is one adder.
    * `:msb` - `sum(x >= [2^j0, 2^(j0+1), ..., 2^j1])` for a scalar `x`: the
      number of thresholds `x` reaches, which for `x >= 0` is
      `min(msb(x), j1) - j0 + 1` (0 below `2^j0`). A priority encoder,
      where the Nx form is `j1 - j0 + 1` comparators and an adder tree
      (`ExHdl.DSP.msb/2`, `ExHdl.DSP.count_leading_zeros/2`).

  Nodes no longer used by an output or a next state are dropped from
  `order` (parameters stay).
  """

  alias NxFixed.Dataflow

  @views [:as_type, :reshape, :squeeze]

  @doc "Rewrites `graph`; `roots` are the ids that must stay (outputs, next state)."
  def run(%Dataflow{} = graph, roots) do
    nodes =
      Enum.reduce(graph.order, graph.nodes, fn id, nodes ->
        node = nodes[id]

        case rewrite(%{graph | nodes: nodes}, node) do
          nil -> nodes
          new -> Map.put(nodes, id, new)
        end
      end)

    graph = %{graph | nodes: nodes}
    live = live(graph, roots)

    %{
      graph
      | order: Enum.filter(graph.order, &(MapSet.member?(live, &1) or nodes[&1].op == :parameter))
    }
  end

  defp rewrite(graph, %{op: :subtract, inputs: [a, h]} = node) do
    with {:ok, half} <- const(graph, h),
         true <- half > 0 and pow2?(half),
         %{op: :bitwise_and, inputs: and_in} <- graph.nodes[a],
         {:ok, b, mask} <- split_const(graph, and_in),
         true <- mask == 2 * half - 1,
         %{op: :add, inputs: add_in} <- graph.nodes[b],
         {:ok, x, ^half} <- split_const(graph, add_in),
         true <- graph.nodes[x].shape == node.shape do
      %{node | op: :wrap, inputs: [x], attrs: bit_len(mask)}
    else
      _ -> nil
    end
  end

  defp rewrite(graph, %{op: :sum, inputs: [s], shape: {}} = node) do
    with %{op: op, inputs: [l, r]} <- graph.nodes[view_source(graph, s)],
         {x, t} <- compare_operands(op, l, r),
         %{shape: {}} <- graph.nodes[x],
         values when is_list(values) <- Dataflow.constant_values(graph, t),
         [first | _] <- values,
         true <- first > 0 and pow2?(first),
         j0 = bit_len(first) - 1,
         true <- values == for(j <- j0..(j0 + length(values) - 1), do: 2 ** j) do
      %{node | op: :msb, inputs: [x], attrs: {j0, j0 + length(values) - 1}}
    else
      _ -> nil
    end
  end

  defp rewrite(_graph, _node), do: nil

  defp compare_operands(:greater_equal, x, t), do: {x, t}
  defp compare_operands(:less_equal, t, x), do: {x, t}
  defp compare_operands(_, _, _), do: nil

  defp view_source(graph, id) do
    case graph.nodes[id] do
      %{op: op, inputs: [x]} when op in @views -> view_source(graph, x)
      _ -> id
    end
  end

  # `{:ok, other, constant}` when one of the two inputs is a scalar constant.
  defp split_const(graph, [p, q]) do
    case {const(graph, p), const(graph, q)} do
      {_, {:ok, v}} -> {:ok, p, v}
      {{:ok, v}, _} -> {:ok, q, v}
      _ -> :error
    end
  end

  defp const(graph, id) do
    case graph.nodes[id] do
      %{range: [{v, v}], shape: {}} when is_integer(v) -> {:ok, v}
      _ -> :error
    end
  end

  defp pow2?(v), do: Bitwise.band(v, v - 1) == 0

  defp bit_len(0), do: 0
  defp bit_len(v), do: 1 + bit_len(Bitwise.bsr(v, 1))

  defp live(graph, roots), do: reach(roots, &graph.nodes[&1].inputs, MapSet.new())

  defp reach([], _next, seen), do: seen

  defp reach([id | rest], next, seen) do
    if MapSet.member?(seen, id),
      do: reach(rest, next, seen),
      else: reach(next.(id) ++ rest, next, MapSet.put(seen, id))
  end
end
