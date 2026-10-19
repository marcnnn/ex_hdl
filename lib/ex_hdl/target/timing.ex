defmodule ExHdl.Target.Timing do
  @moduledoc """
  Coarse delay and latency model for Zynq-7000 fabric (speed grade -1).

  Each IR node costs either combinational delay (`{:comb, ns}`) or a fixed
  number of register stages (`{:reg, cycles, kind}`). Widths come from the
  range analysis, so a 32-bit Nx add whose values need 17 bits is costed as
  a 17-bit adder. Constant shifts and masks are wiring and cost nothing.

  The numbers are deliberately simple and only meant for scheduling
  decisions (where to put registers, how long a feedback loop is). Real
  timing closure is decided by place and route. All fields can be
  overridden through options.
  """

  alias NxFixed.IntSet

  defstruct clock_mhz: 150,
            # fraction of the period available to logic (routing, setup)
            margin: 0.75,
            # DSP48E1 with A/B, M and P registers
            dsp_latency: 3,
            # RAMB36E1 with output register
            bram_latency: 2,
            # tables up to this many entries become LUT ROM
            lut_rom_max: 64,
            lut_ns: 0.6,
            carry_ns_per_bit: 0.03

  @type t :: %__MODULE__{}
  @type cost :: {:comb, float()} | {:reg, pos_integer(), atom()}

  @free ~w(parameter constant tensor as_type reshape broadcast squeeze transpose concatenate slice)a
  @adder ~w(add subtract negate equal not_equal less less_equal greater greater_equal)a
  @bitwise ~w(bitwise_and bitwise_or bitwise_xor)a

  def new(opts \\ []),
    do: struct!(__MODULE__, Keyword.take(opts, Map.keys(%__MODULE__{}) -- [:__struct__]))

  @doc "Combinational budget per clock cycle in ns."
  def period_ns(%__MODULE__{clock_mhz: mhz, margin: m}), do: 1000 / mhz * m

  @doc "Cost of `node` in `graph` (whose nodes carry ranges)."
  @spec cost(map(), NxFixed.Dataflow.t(), t()) :: cost()
  def cost(%{op: op}, _graph, _t) when op in @free, do: {:comb, 0.0}

  def cost(%{op: op} = node, graph, t) when op in @adder do
    bits = node.inputs |> Enum.map(&width(graph, &1)) |> Enum.max() |> Kernel.+(1)
    {:comb, adder(t, bits)}
  end

  def cost(%{op: op} = node, graph, t) when op in [:min, :max, :abs] do
    {:comb, cost_ns(cost(%{node | op: :subtract}, graph, t)) + t.lut_ns}
  end

  # Both bounds compare in parallel, then two mux levels.
  def cost(%{op: :clip, inputs: [x | _]}, graph, t),
    do: {:comb, adder(t, width(graph, x) + 1) + 2 * t.lut_ns}

  def cost(%{op: op} = node, graph, t) when op in @bitwise do
    if Enum.any?(node.inputs, &constant?(graph, &1)), do: {:comb, 0.0}, else: {:comb, t.lut_ns}
  end

  def cost(%{op: op, inputs: [_, k]}, graph, t) when op in [:right_shift, :left_shift] do
    if constant?(graph, k), do: {:comb, 0.0}, else: {:comb, 3 * t.lut_ns}
  end

  def cost(%{op: :select}, _graph, t), do: {:comb, t.lut_ns}

  def cost(%{op: op}, _graph, t) when op in [:logical_and, :logical_or, :logical_not],
    do: {:comb, t.lut_ns}

  def cost(%{op: :multiply, inputs: [a, b]}, graph, t) do
    cond do
      power_of_two?(graph, a) or power_of_two?(graph, b) ->
        {:comb, 0.0}

      dsp_fits?(signed_width(graph, a), signed_width(graph, b)) ->
        {:reg, t.dsp_latency, :dsp48}

      true ->
        # Cascade of two DSP48E1 slices.
        {:reg, t.dsp_latency + 2, :dsp48_cascade}
    end
  end

  def cost(%{op: :take, inputs: [table, _]}, graph, t) do
    size = graph.nodes[table].shape |> elem(0)

    if size <= t.lut_rom_max,
      do: {:comb, t.lut_ns * (div(ceil_log2(size), 6) + 1)},
      else: {:reg, t.bram_latency, :bram}
  end

  # One multiplier per product, then a registered adder tree.
  def cost(%{op: :dot, inputs: [a | _], attrs: {contract, _, _, _}}, graph, t) do
    n = contract |> Enum.map(&elem(graph.nodes[a].shape, &1)) |> Enum.product()
    {:reg, t.dsp_latency + ceil_log2(n), :dsp48_tree}
  end

  # Upper bound: all elements summed.
  def cost(%{op: :sum, inputs: [x]}, graph, t) do
    case graph.nodes[x].shape |> Tuple.to_list() |> Enum.product() do
      n when n <= 2 -> {:comb, adder(t, width(graph, x) + 1)}
      n -> {:reg, ceil_log2(n), :adder_tree}
    end
  end

  def cost(_node, _graph, t), do: {:comb, t.lut_ns}

  @doc "Short human description of a cost."
  def describe({:comb, ns}) when ns == 0, do: "wiring"
  def describe({:comb, ns}), do: "#{Float.round(ns, 2)} ns"
  def describe({:reg, n, kind}), do: "#{kind}, #{n} cycle#{if n > 1, do: "s"}"

  defp cost_ns({:comb, ns}), do: ns

  defp adder(t, bits), do: t.lut_ns + t.carry_ns_per_bit * bits

  # 25x18 signed multiplier.
  defp dsp_fits?(a, b), do: (a <= 25 and b <= 18) or (a <= 18 and b <= 25)

  defp width(graph, id) do
    {_, bits} = IntSet.bit_width(graph.nodes[id].range)
    bits
  end

  defp signed_width(graph, id) do
    case IntSet.bit_width(graph.nodes[id].range) do
      {:s, bits} -> bits
      {:u, bits} -> bits + 1
    end
  end

  defp constant?(graph, id), do: IntSet.size(graph.nodes[id].range) == 1

  defp power_of_two?(graph, id) do
    case graph.nodes[id].range do
      [{k, k}] when k > 0 -> Bitwise.band(k, k - 1) == 0
      _ -> false
    end
  end

  defp ceil_log2(n) when n <= 1, do: 0
  defp ceil_log2(n), do: 1 + ceil_log2(div(n + 1, 2))
end
