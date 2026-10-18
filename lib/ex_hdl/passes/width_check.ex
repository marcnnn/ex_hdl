defmodule ExHdl.Passes.WidthCheck do
  @moduledoc """
  Integer range analysis over an `ExHdl.IR.Dataflow` graph.

  Every node gets the set of values it can take, as an `ExHdl.Types.IntSet`
  (a set-theoretic integer type: a union of intervals). A node whose set is
  not a subtype of its Nx type is a violation: the Nx reference and the CPU
  backend would wrap there, while the FPGA (which sizes signals from these
  sets) would not, so the backends could disagree. Overflow is only allowed
  where it is written down, via `ExHdl.DSP.Primitives.wrap/2`.

  The analysis runs in three stages:

    1. **Transfer**: each node's set is computed from its inputs' sets.
       Sound but blind to correlation: in `i*cos - q*sin`, cos and sin are
       treated as independent.
    2. **Case splitting**: the type of `f(x)` for `x in A or B` is
       `f(A) or f(B)`. For a node with a small set (at most
       `:split_threshold` values) and several users, its downstream cone is
       re-analysed once per value and the results are joined. Correlated
       values (cos and sin from one table index) are then related again.
       The refined set is intersected with the plain one, so both stay sound.
    3. **Check**: every set is compared with its declared type.
  """

  import Bitwise
  alias ExHdl.IR.Dataflow
  alias ExHdl.Types.IntSet

  defmodule Violation do
    @moduledoc "A place where values may not fit the declared type. `range` is `{min, max}`."
    defstruct [:node, :kind, :range, :set, :detail]

    @type kind :: :overflow | :narrowing | :constant | :index | :shift | :float | :param
  end

  @compare ~w(equal not_equal less less_equal greater greater_equal)a
  @logical ~w(logical_and logical_or logical_not)a
  @transparent ~w(as_type reshape broadcast squeeze transpose)a
  @arith ~w(add subtract multiply min max bitwise_and bitwise_or bitwise_xor)a

  @doc """
  Annotates every node with `range` (an `IntSet`, or `:unknown` for floats)
  and returns `{graph, violations}`.

  Options:
    * `:param_ranges` - `%{param_index => lo..hi}` to narrow inputs below
      their type, e.g. symmetric Q15 `-32767..32767`.
    * `:case_split` - enable stage 2 (default `true`).
    * `:split_threshold` - max values of a split node (default 4096).
    * `:split_budget` - max node evaluations spent on splitting (default 2_000_000).
  """
  @spec run(Dataflow.t(), keyword()) :: {Dataflow.t(), [Violation.t()]}
  def run(%Dataflow{} = graph, opts \\ []) do
    param_ranges = Keyword.get(opts, :param_ranges, %{})
    ranges = forward(graph, graph.order, %{}, param_ranges)

    ranges =
      if Keyword.get(opts, :case_split, true),
        do: case_split(graph, ranges, param_ranges, opts),
        else: ranges

    graph = %{
      graph
      | nodes: Map.new(graph.nodes, fn {id, n} -> {id, %{n | range: ranges[id]}} end)
    }

    {graph, check(graph, param_ranges)}
  end

  @doc "Value range `{min, max}` representable by an Nx integer type."
  def type_range({:s, bits}), do: {-(1 <<< (bits - 1)), (1 <<< (bits - 1)) - 1}
  def type_range({:u, bits}), do: {0, (1 <<< bits) - 1}

  # -- stage 1: transfer -------------------------------------------------------------

  defp forward(graph, ids, ranges, param_ranges) do
    Enum.reduce(ids, ranges, fn id, ranges ->
      node = graph.nodes[id]
      inputs = Enum.map(node.inputs, &Map.fetch!(ranges, &1))

      range =
        if float?(node.type) or :unknown in inputs,
          do: :unknown,
          else: transfer(node, inputs, graph, param_ranges)

      Map.put(ranges, id, range)
    end)
  end

  defp transfer(%{op: :parameter, attrs: index} = node, [], _graph, param_ranges) do
    full = IntSet.of_type(node.type)

    case Map.fetch(param_ranges, index) do
      {:ok, lo..hi//1} -> IntSet.intersection(IntSet.range(lo, hi), full)
      _ -> full
    end
  end

  defp transfer(%{op: :constant, attrs: v}, [], _graph, _) when is_integer(v),
    do: IntSet.singleton(v)

  defp transfer(%{op: :constant}, [], _graph, _), do: :unknown

  defp transfer(%{op: :tensor, attrs: t}, [], _graph, _),
    do: t |> Nx.to_flat_list() |> IntSet.from_list() |> IntSet.widen()

  defp transfer(%{op: op}, [x], _graph, _) when op in @transparent, do: x
  defp transfer(%{op: op}, [a, b], _graph, _) when op in @arith, do: apply(IntSet, op, [a, b])
  defp transfer(%{op: :negate}, [x], _graph, _), do: IntSet.negate(x)
  defp transfer(%{op: :abs}, [x], _graph, _), do: IntSet.abs(x)
  defp transfer(%{op: :clip}, [x, lo, hi], _graph, _), do: IntSet.clip(x, lo, hi)
  defp transfer(%{op: op}, [a, b], _graph, _) when op in @compare, do: IntSet.compare(op, a, b)
  defp transfer(%{op: op}, _, _graph, _) when op in @logical, do: IntSet.range(0, 1)

  defp transfer(%{op: :select}, [pred, a, b], _graph, _) do
    cond do
      pred == IntSet.singleton(1) -> a
      pred == IntSet.singleton(0) -> b
      true -> IntSet.union(a, b)
    end
  end

  # Shift amounts outside the operand width are reported by check/2; the
  # transfer only uses the valid part (or gives up to the result type).
  defp transfer(%{op: op} = node, [x, k], graph, _) when op in [:right_shift, :left_shift] do
    {_, bits} = graph.nodes[hd(node.inputs)].type

    case IntSet.intersection(k, IntSet.range(0, bits - 1)) do
      [] -> IntSet.of_type(node.type)
      k -> apply(IntSet, op, [x, k])
    end
  end

  # Every element of the result is one of the inputs' elements.
  defp transfer(%{op: :concatenate}, sets, _graph, _), do: Enum.reduce(sets, &IntSet.union/2)
  defp transfer(%{op: :slice}, [x], _graph, _), do: x

  # n elements, each from x: the hull scaled by n.
  defp transfer(%{op: :sum, inputs: [x_id], attrs: opts}, [x], graph, _) do
    shape = graph.nodes[x_id].shape
    axes = opts[:axes] || Enum.to_list(0..(tuple_size(shape) - 1)//1)
    n = axes |> Enum.map(&elem(shape, &1)) |> Enum.product()
    {lo, hi} = IntSet.bounds(x)
    IntSet.range(n * lo, n * hi)
  end

  # With a constant operand c (e.g. FIR taps): sum over i of x * c_i, so the
  # bound is exact per coefficient. Otherwise n times the product hull.
  defp transfer(%{op: :dot, inputs: [a_id, b_id], attrs: {contract_a, _, _, _}}, [a, b], graph, _) do
    case {Dataflow.constant_values(graph, a_id), Dataflow.constant_values(graph, b_id)} do
      {_, coeffs} when is_list(coeffs) ->
        weighted_sum(a, coeffs)

      {coeffs, _} when is_list(coeffs) ->
        weighted_sum(b, coeffs)

      _ ->
        shape = graph.nodes[a_id].shape
        n = contract_a |> Enum.map(&elem(shape, &1)) |> Enum.product()
        {lo, hi} = a |> IntSet.multiply(b) |> IntSet.bounds()
        IntSet.range(n * lo, n * hi)
    end
  end

  # Exact lookup for small index sets; the whole table otherwise.
  defp transfer(%{op: :take, inputs: [table_id, _]}, [table, idx], graph, _) do
    values = graph.nodes[table_id].attrs |> Nx.to_flat_list() |> List.to_tuple()
    size = tuple_size(values)
    idx = IntSet.intersection(idx, IntSet.range(0, size - 1))

    if IntSet.size(idx) <= 4096,
      do:
        idx
        |> IntSet.to_list()
        |> Enum.map(&elem(values, &1))
        |> IntSet.from_list()
        |> IntSet.widen(),
      else: table
  end

  defp weighted_sum(x, coeffs) do
    {lo, hi} = IntSet.bounds(x)

    {sum_lo, sum_hi} =
      Enum.reduce(coeffs, {0, 0}, fn c, {acc_lo, acc_hi} ->
        {acc_lo + min(lo * c, hi * c), acc_hi + max(lo * c, hi * c)}
      end)

    IntSet.range(sum_lo, sum_hi)
  end

  # -- stage 2: case splitting --------------------------------------------------------

  defp case_split(graph, ranges, param_ranges, opts) do
    threshold = Keyword.get(opts, :split_threshold, 4096)
    budget = Keyword.get(opts, :split_budget, 2_000_000)
    users = users(graph)

    candidates =
      for id <- graph.order,
          graph.nodes[id].op not in [:constant, :tensor],
          length(Map.get(users, id, [])) >= 2,
          is_list(ranges[id]),
          IntSet.size(ranges[id]) in 2..threshold//1,
          do: id

    {ranges, _budget} =
      Enum.reduce(candidates, {ranges, budget}, fn id, {ranges, budget} ->
        cone = cone(graph, users, id)
        cost = IntSet.size(ranges[id]) * length(cone)

        if cost > budget,
          do: {ranges, budget},
          else: {split(graph, id, cone, ranges, param_ranges), budget - cost}
      end)

    ranges
  end

  # Re-analyses the downstream cone of `id` once per value of `id` and
  # intersects the joined result with what the cone had before.
  defp split(graph, id, cone, ranges, param_ranges) do
    joined =
      ranges[id]
      |> IntSet.to_list()
      |> Enum.reduce(%{}, fn k, acc ->
        local = forward(graph, cone, Map.put(ranges, id, IntSet.singleton(k)), param_ranges)

        Map.new(cone, fn n ->
          case {Map.get(acc, n), local[n]} do
            {_, :unknown} -> {n, :unknown}
            {nil, set} -> {n, set}
            {:unknown, _} -> {n, :unknown}
            {prev, set} -> {n, prev |> IntSet.union(set) |> widen_lazily()}
          end
        end)
      end)

    Enum.reduce(cone, ranges, fn n, ranges ->
      case {ranges[n], joined[n]} do
        {old, new} when is_list(old) and is_list(new) ->
          Map.put(ranges, n, IntSet.widen(IntSet.intersection(old, new)))

        _ ->
          ranges
      end
    end)
  end

  defp widen_lazily(set) do
    if length(set) > 2 * IntSet.max_intervals(), do: IntSet.widen(set), else: set
  end

  defp users(graph) do
    for id <- graph.order, input <- Enum.uniq(graph.nodes[id].inputs), reduce: %{} do
      acc -> Map.update(acc, input, [id], &[id | &1])
    end
  end

  # All transitive users of `id`, in topological order.
  defp cone(graph, users, id) do
    reach = reach(users, Map.get(users, id, []), MapSet.new())
    Enum.filter(graph.order, &MapSet.member?(reach, &1))
  end

  defp reach(_users, [], seen), do: seen

  defp reach(users, [id | rest], seen) do
    if MapSet.member?(seen, id),
      do: reach(users, rest, seen),
      else: reach(users, Map.get(users, id, []) ++ rest, MapSet.put(seen, id))
  end

  # -- stage 3: check -------------------------------------------------------------------

  defp check(graph, param_ranges) do
    Enum.flat_map(graph.order, fn id -> check_node(graph.nodes[id], graph, param_ranges) end)
  end

  defp check_node(node, graph, param_ranges) do
    cond do
      float?(node.type) or (node.op == :constant and not is_integer(node.attrs)) ->
        [violation(node, :float, nil)]

      node.range == :unknown ->
        []

      true ->
        specific(node, graph, param_ranges) ++ fit(node)
    end
  end

  defp specific(%{op: :parameter, attrs: index} = node, _graph, param_ranges) do
    case Map.fetch(param_ranges, index) do
      {:ok, lo..hi//1} ->
        if IntSet.subtype?(IntSet.range(lo, hi), IntSet.of_type(node.type)),
          do: [],
          else: [violation(node, :param, IntSet.range(lo, hi))]

      _ ->
        []
    end
  end

  defp specific(%{op: :take, inputs: [table_id, idx_id]} = node, graph, _) do
    size = graph.nodes[table_id].shape |> elem(0)
    idx = graph.nodes[idx_id].range

    if IntSet.subtype?(idx, IntSet.range(0, size - 1)),
      do: [],
      else: [violation(node, :index, idx, size)]
  end

  defp specific(%{op: op, inputs: [x_id, k_id]} = node, graph, _)
       when op in [:right_shift, :left_shift] do
    {_, bits} = graph.nodes[x_id].type
    k = graph.nodes[k_id].range

    if IntSet.subtype?(k, IntSet.range(0, bits - 1)), do: [], else: [violation(node, :shift, k)]
  end

  defp specific(_node, _graph, _), do: []

  defp fit(%{op: :parameter}), do: []

  defp fit(%{op: :constant} = node) do
    if IntSet.subtype?(node.range, IntSet.of_type(node.type)),
      do: [],
      else: [violation(node, :constant, node.range)]
  end

  defp fit(node) do
    cond do
      IntSet.subtype?(node.range, IntSet.of_type(node.type)) -> []
      node.op == :as_type -> [violation(node, :narrowing, node.range)]
      true -> [violation(node, :overflow, node.range)]
    end
  end

  defp float?({kind, _}), do: kind not in [:s, :u]

  defp violation(node, kind, set, detail \\ nil) do
    range = if is_list(set) and set != [], do: IntSet.bounds(set)
    %Violation{node: node.id, kind: kind, range: range, set: set, detail: detail}
  end

  # -- reporting --------------------------------------------------------------------------

  @doc "Human-readable description of the violations, one block per problem."
  def format(%Dataflow{} = graph, violations, name \\ "defn") do
    header =
      "#{name}: #{length(violations)} fixed-point problem(s); the backends would not be bit-identical\n"

    blocks =
      Enum.map(violations, fn v ->
        node = graph.nodes[v.node]

        inputs =
          Enum.map(node.inputs, fn id ->
            n = graph.nodes[id]
            "        #{expr(graph, id, 1)} : #{type_name(n.type)} #{set_name(n.range)}\n"
          end)

        """

          * #{problem(v, node)}
            at #{expr(graph, v.node, 3)}
        #{if inputs == [], do: "", else: "      inputs:\n#{inputs}"}      fix: #{hint(v.kind)}
        """
      end)

    IO.iodata_to_binary([header | blocks])
  end

  defp problem(%{kind: :overflow, set: s}, node),
    do:
      "#{node.op} needs #{set_name(s)}, but #{type_name(node.type)} holds #{set_name(IntSet.of_type(node.type))}"

  defp problem(%{kind: :narrowing, set: s}, node),
    do: "as_type to #{type_name(node.type)} would wrap values in #{set_name(s)}"

  defp problem(%{kind: :constant, range: {v, _}}, node),
    do: "constant #{v} does not fit #{type_name(node.type)}"

  defp problem(%{kind: :index, set: s, detail: size}, _node),
    do: "take index can be #{set_name(s)}, table has #{size} entries"

  defp problem(%{kind: :shift, set: s}, node),
    do: "#{node.op} amount can be #{set_name(s)}, outside 0..#{elem(node.type, 1) - 1}"

  defp problem(%{kind: :param, set: s}, node),
    do:
      "param_ranges entry #{set_name(s)} for parameter #{node.attrs} exceeds #{type_name(node.type)}"

  defp problem(%{kind: :float}, node), do: "floating point value (#{type_name(node.type)})"

  defp hint(:overflow),
    do:
      "widen the operands with Nx.as_type/2 first, or bound the value with saturate/2, or wrap on purpose with wrap/2"

  defp hint(:narrowing), do: "use wrap/2 for modular arithmetic or saturate/2 to clamp"
  defp hint(:constant), do: "widen the other operand before combining it with this constant"
  defp hint(:index), do: "mask or clamp the index to the table size"
  defp hint(:shift), do: "use a constant shift amount within the operand width"
  defp hint(:param), do: "narrow the range or widen the parameter type"
  defp hint(:float), do: "use integer fixed-point types (e.g. :s16 for Q15)"

  # Compact expression text for locating a node, `depth` levels deep.
  defp expr(graph, id, depth) do
    node = graph.nodes[id]

    case node do
      %{op: :parameter, attrs: i} -> "param#{i}"
      %{op: :constant, attrs: v} -> to_string(v)
      %{op: :tensor} -> "table#{inspect(node.shape)}"
      _ when depth == 0 -> "#{node.op}(...)"
      _ -> "#{node.op}(#{Enum.map_join(node.inputs, ", ", &expr(graph, &1, depth - 1))})"
    end
  end

  defp type_name({k, b}), do: "#{k}#{b}"

  # Short sets in full type syntax, long ones as their hull.
  defp set_name(set) when is_list(set) and length(set) <= 4, do: IntSet.to_quoted_string(set)

  defp set_name(set) when is_list(set) do
    {lo, hi} = IntSet.bounds(set)
    "#{lo}..#{hi} (#{length(set)} intervals)"
  end

  defp set_name(_), do: "?"
end
