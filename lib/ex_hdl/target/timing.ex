defmodule ExHdl.Target.Timing do
  @moduledoc """
  Coarse delay and latency model of an FPGA family, for scheduling.

  Each IR node costs either combinational delay (`{:comb, ns}`) or a fixed
  number of register stages (`{:reg, cycles, kind}`). Widths come from the
  range analysis, so a 32-bit Nx add whose values need 17 bits is costed as
  a 17-bit adder. Constant shifts and masks are wiring and cost nothing.

  Products wider than the DSP multiplier are costed as their pieces
  (`dsp_split/3`): the DSP latency plus one adder level per halving of
  the piece count, so loops and pipelines match the generated split.

  The numbers are deliberately simple and only meant for scheduling
  decisions (where to put registers, how long a feedback loop is). Real
  timing closure is decided by place and route.

  ## Families

    * `:zynq7` (default) - Zynq-7000 / 7-series, speed grade `"-1"`:
      DSP48E1 (25 x 18 multiplier, 25-bit pre-adder, 48-bit accumulator),
      RAMB36E1, no URAM. `lut_ns` (0.6) includes routing; the flip-flop
      and net delays are 0 and folded into `margin` (0.75).
    * `:ultrascale_plus` - Kintex/Virtex/Zynq UltraScale+, speed grades
      `"-1"` (default) and `"-2"`: DSP48E2 (27 x 18 multiplier, 27-bit
      pre-adder, 48-bit accumulator), RAMB36E2, URAM288 (4096 x 72, 2
      cycles with output register). Delays are typical routed values
      (`lut_ns` 0.12/0.10 cell delay plus `net_typ_ns` 0.35/0.30 per
      level, `ff_clk_to_q_ns` and `ff_setup_ns` subtracted from the
      period), `margin` 0.85. The family names of `ExHdlXilinx.Device`
      (`:kintex_ultrascale_plus`, ...) are accepted.

  `new/1` takes `family:`, `speed_grade:` and overrides for every field;
  `from_device/3` builds the model from device data in the shape of
  `ExHdlXilinx.Device` (family, `dsp`, `bram`, `uram`, `delays`,
  `fmax_mhz`, `resources`). Unknown keys are ignored, so the options of a
  stream kernel (`:ii`, `:channels`, ...) can be passed through.

  Fields: `clock_mhz`, `margin` (fraction of the period available to
  logic), `lut_ns`, `net_typ_ns` (routing per logic level), `carry_ns_per_bit`,
  `ff_clk_to_q_ns`, `ff_setup_ns`, `dsp_latency` (A/B, M and P
  registers), `dsp_multiplier` (`{a_bits, b_bits}` signed), `dsp_preadder_bits`,
  `dsp_accumulator_bits`, `bram_latency` (with output register),
  `uram_latency` (nil without URAM), `uram_min_bits` (memories at least
  this large go to URAM in `memory_style/3`), `lut_rom_max` (tables up to
  this many entries become LUT ROM), `fmax_mhz` (`%{dsp: mhz, bram: mhz,
  uram: mhz}` for the grade), `resources` (`%{lut:, ff:, bram:, uram:,
  dsp:, gt:}` of a device, or nil).
  """

  alias NxFixed.IntSet

  defstruct family: :zynq7,
            speed_grade: "-1",
            clock_mhz: 150,
            margin: 0.75,
            dsp_latency: 3,
            dsp_multiplier: {25, 18},
            dsp_preadder_bits: 25,
            dsp_accumulator_bits: 48,
            bram_latency: 2,
            uram_latency: nil,
            uram_min_bits: nil,
            lut_rom_max: 64,
            lut_ns: 0.6,
            net_typ_ns: 0.0,
            carry_ns_per_bit: 0.03,
            ff_clk_to_q_ns: 0.0,
            ff_setup_ns: 0.0,
            fmax_mhz: %{dsp: 464, bram: 388},
            resources: nil

  @type t :: %__MODULE__{}
  @type cost :: {:comb, float()} | {:reg, pos_integer(), atom()}

  @free ~w(parameter constant tensor as_type reshape broadcast squeeze transpose concatenate slice)a
  @adder ~w(add subtract negate equal not_equal less less_equal greater greater_equal)a
  @bitwise ~w(bitwise_and bitwise_or bitwise_xor)a

  @ultrascale_plus %{
    common: [
      margin: 0.85,
      dsp_latency: 3,
      dsp_multiplier: {27, 18},
      dsp_preadder_bits: 27,
      dsp_accumulator_bits: 48,
      bram_latency: 2,
      uram_latency: 2,
      # four RAMB36 worth of bits
      uram_min_bits: 147_456
    ],
    grades: %{
      "-1" => [
        lut_ns: 0.12,
        carry_ns_per_bit: 0.012,
        ff_clk_to_q_ns: 0.10,
        ff_setup_ns: 0.03,
        net_typ_ns: 0.35,
        fmax_mhz: %{dsp: 645, bram: 650, uram: 600}
      ],
      "-2" => [
        lut_ns: 0.10,
        carry_ns_per_bit: 0.010,
        ff_clk_to_q_ns: 0.09,
        ff_setup_ns: 0.03,
        net_typ_ns: 0.30,
        fmax_mhz: %{dsp: 775, bram: 737, uram: 650}
      ]
    }
  }

  @us_plus_aliases [
    :ultrascale_plus,
    :kintex_ultrascale_plus,
    :virtex_ultrascale_plus,
    :zynq_ultrascale_plus,
    :artix_ultrascale_plus
  ]

  @doc """
  The model for `family:` and `speed_grade:` with any field overridden
  by `opts`. Raises for unknown families or grades.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    family = family!(Keyword.get(opts, :family, :zynq7))
    grade = Keyword.get(opts, :speed_grade, "-1")
    base = defaults(family, grade)
    fields = Map.keys(%__MODULE__{}) -- [:__struct__, :family, :speed_grade]
    over = Keyword.take(opts, fields)

    struct!(
      __MODULE__,
      base |> Keyword.merge(over) |> Keyword.merge(family: family, speed_grade: grade)
    )
  end

  defp family!(f) when f in @us_plus_aliases, do: :ultrascale_plus
  defp family!(f) when f in [:zynq7, :zynq7000, :series7], do: :zynq7

  defp family!(f),
    do: raise(ArgumentError, "unknown family #{inspect(f)}; use :zynq7 or :ultrascale_plus")

  defp defaults(:zynq7, "-1"), do: []

  defp defaults(:ultrascale_plus, grade) do
    case @ultrascale_plus.grades do
      %{^grade => g} -> @ultrascale_plus.common ++ g
      _ -> grade_error(:ultrascale_plus, grade, Map.keys(@ultrascale_plus.grades))
    end
  end

  defp defaults(family, grade), do: grade_error(family, grade, ["-1"])

  defp grade_error(family, grade, known),
    do:
      raise(
        ArgumentError,
        "no delays for #{family} speed grade #{inspect(grade)}; known: #{Enum.join(known, ", ")}"
      )

  @doc """
  The model from device data shaped like `ExHdlXilinx.Device` (`family`,
  `delays` per grade, `dsp`, `bram`, `uram`, `fmax_mhz`, `resources`) for
  speed grade `grade`; `opts` override fields (`clock_mhz:`, ...).
  """
  @spec from_device(map(), String.t(), keyword()) :: t()
  def from_device(%{family: fam, delays: delays} = d, grade, opts \\ []) do
    g =
      Map.get(delays, grade) ||
        grade_error(fam, grade, Map.keys(delays))

    dsp = Map.get(d, :dsp) || %{}
    bram = Map.get(d, :bram) || %{}
    uram = Map.get(d, :uram)

    fmax =
      for {k, key} <- [dsp: :dsp48e2_all_regs, bram: :bram_all_regs, uram: :uram],
          by_grade = get_in(d, [Access.key(:fmax_mhz, %{}), Access.key(key, %{})]),
          Map.has_key?(by_grade, grade),
          into: %{},
          do: {k, by_grade[grade]}

    from_data =
      [
        family: fam,
        speed_grade: grade,
        lut_ns: g[:lut_ns],
        carry_ns_per_bit: g[:carry_ns_per_bit],
        ff_clk_to_q_ns: g[:ff_clk_to_q_ns],
        ff_setup_ns: g[:ff_setup_ns],
        net_typ_ns: g[:net_typ_ns],
        dsp_multiplier: dsp[:multiplier],
        dsp_preadder_bits: dsp[:preadder_bits],
        dsp_accumulator_bits: dsp[:accumulator_bits],
        dsp_latency: dsp[:latency_full],
        bram_latency: bram[:latency_with_output_reg],
        uram_latency: uram && uram[:latency_with_output_reg],
        fmax_mhz: if(fmax == %{}, do: nil, else: fmax),
        resources: device_resources(Map.get(d, :resources))
      ]
      |> Enum.reject(fn {_, v} -> v == nil end)

    new(from_data ++ [speed_grade: grade] ++ opts)
  end

  defp device_resources(nil), do: nil

  defp device_resources(r) do
    %{
      lut: r[:clb_luts],
      ff: r[:clb_ffs],
      bram: r[:bram36],
      uram: r[:uram288] || 0,
      dsp: r[:dsp],
      gt: r[:gty] || r[:gth] || r[:gtx] || 0
    }
  end

  @doc "Combinational budget per clock cycle in ns (flip-flop overhead subtracted)."
  def period_ns(%__MODULE__{clock_mhz: mhz, margin: m} = t),
    do: 1000 / mhz * m - t.ff_clk_to_q_ns - t.ff_setup_ns

  @doc "Delay of one logic level (LUT plus typical routing)."
  def level_ns(%__MODULE__{lut_ns: l, net_typ_ns: n}), do: l + n

  @doc """
  Warnings when `clock_mhz` exceeds the maximum frequency of a primitive
  for the grade (`fmax_mhz`).
  """
  @spec warnings(t()) :: [String.t()]
  def warnings(%__MODULE__{fmax_mhz: nil}), do: []

  def warnings(%__MODULE__{} = t) do
    for {kind, f} <- Enum.sort(t.fmax_mhz), t.clock_mhz > f do
      "#{t.clock_mhz} MHz exceeds the #{kind} maximum of #{f} MHz for #{t.family} #{t.speed_grade}"
    end
  end

  @doc """
  Where a memory of `width` x `depth` bits belongs: `:distributed` up to
  `lut_rom_max` words, `:ultra` when the family has URAM and the memory
  has at least `uram_min_bits`, `:block` otherwise. The result is an
  `ExHdl.RTL` memory `style:`.
  """
  @spec memory_style(t(), pos_integer(), pos_integer()) :: :distributed | :block | :ultra
  def memory_style(%__MODULE__{} = t, width, depth) do
    cond do
      depth <= t.lut_rom_max ->
        :distributed

      t.uram_latency != nil and t.uram_min_bits != nil and width * depth >= t.uram_min_bits ->
        :ultra

      true ->
        :block
    end
  end

  @doc """
  Cost of a signed `a` x `b` bit product: one DSP slice when it fits the
  multiplier, otherwise the pieces of `dsp_split/3` and their adder tree.
  """
  @spec mul_cost(t(), pos_integer(), pos_integer()) :: cost()
  def mul_cost(%__MODULE__{} = t, a, b) do
    case dsp_split(t, a, b) do
      %{count: 1} -> {:reg, t.dsp_latency, :dsp48}
      %{levels: l} -> {:reg, t.dsp_latency + l, :dsp48_split}
    end
  end

  @doc """
  How a signed `a` x `b` bit product maps onto DSP multipliers
  (`dsp_multiplier`, `{27, 18}` for DSP48E2, `{25, 18}` for DSP48E1).

  Each operand is cut into pieces that fit one port: unsigned low pieces of
  `port - 1` bits (a zero sign bit is added) and a signed top piece. Every
  pair of pieces is one DSP slice; the partial products, shifted, are summed
  by a registered adder tree of `levels` levels. The orientation (which
  operand goes to the wide port) with fewer slices wins.

  Returns `%{count:, levels:, swap:, a: [{lsb, bits, signed?}], b: [...]}`
  where `swap` is true when `b` goes to the wide port; `a` and `b` are the
  pieces of the two operands as given.

      iex> t = ExHdl.Target.Timing.new(family: :ultrascale_plus)
      iex> ExHdl.Target.Timing.dsp_split(t, 32, 24).count
      2
      iex> ExHdl.Target.Timing.dsp_split(t, 32, 32).count
      4
  """
  @spec dsp_split(t(), pos_integer(), pos_integer()) :: map()
  def dsp_split(%__MODULE__{dsp_multiplier: {wide, narrow}}, a, b) do
    straight = {pieces(a, wide), pieces(b, narrow)}
    swapped = {pieces(a, narrow), pieces(b, wide)}

    {{pa, pb}, swap} =
      if length(elem(swapped, 0)) * length(elem(swapped, 1)) <
           length(elem(straight, 0)) * length(elem(straight, 1)),
         do: {swapped, true},
         else: {straight, false}

    count = length(pa) * length(pb)
    %{count: count, levels: ceil_log2(count), swap: swap, a: pa, b: pb}
  end

  @doc "DSP slices of a signed `a` x `b` bit product (`dsp_split/3`)."
  def dsp_count(%__MODULE__{} = t, a, b), do: dsp_split(t, a, b).count

  # Pieces of a signed `w`-bit operand for a signed `port`-bit input.
  defp pieces(w, port) when w <= port, do: [{0, w, true}]

  defp pieces(w, port) do
    rest = pieces(w - (port - 1), port)
    [{0, port - 1, false} | Enum.map(rest, fn {lsb, n, s} -> {lsb + port - 1, n, s} end)]
  end

  @doc "True when a signed `a` x `b` bit product fits one DSP multiplier."
  def dsp_fits?(%__MODULE__{dsp_multiplier: {ma, mb}}, a, b),
    do: (a <= ma and b <= mb) or (a <= mb and b <= ma)

  @doc "Cost of `node` in `graph` (whose nodes carry ranges)."
  @spec cost(map(), NxFixed.Dataflow.t(), t()) :: cost()
  def cost(%{op: op}, _graph, _t) when op in @free, do: {:comb, 0.0}

  def cost(%{op: op} = node, graph, t) when op in @adder do
    bits = node.inputs |> Enum.map(&width(graph, &1)) |> Enum.max() |> Kernel.+(1)
    {:comb, adder(t, bits)}
  end

  def cost(%{op: op} = node, graph, t) when op in [:min, :max, :abs] do
    {:comb, cost_ns(cost(%{node | op: :subtract}, graph, t)) + level_ns(t)}
  end

  # Both bounds compare in parallel, then two mux levels.
  def cost(%{op: :clip, inputs: [x | _]}, graph, t),
    do: {:comb, adder(t, width(graph, x) + 1) + 2 * level_ns(t)}

  def cost(%{op: op} = node, graph, t) when op in @bitwise do
    if Enum.any?(node.inputs, &constant?(graph, &1)),
      do: {:comb, 0.0},
      else: {:comb, level_ns(t)}
  end

  def cost(%{op: op, inputs: [_, k]}, graph, t) when op in [:right_shift, :left_shift] do
    if constant?(graph, k), do: {:comb, 0.0}, else: {:comb, 3 * level_ns(t)}
  end

  def cost(%{op: :select}, _graph, t), do: {:comb, level_ns(t)}

  def cost(%{op: op}, _graph, t) when op in [:logical_and, :logical_or, :logical_not],
    do: {:comb, level_ns(t)}

  def cost(%{op: :multiply, inputs: [a, b]}, graph, t) do
    if power_of_two?(graph, a) or power_of_two?(graph, b),
      do: {:comb, 0.0},
      else: mul_cost(t, signed_width(graph, a), signed_width(graph, b))
  end

  def cost(%{op: :take, inputs: [table, _]}, graph, t) do
    size = graph.nodes[table].shape |> elem(0)

    if size <= t.lut_rom_max,
      do: {:comb, level_ns(t) * (div(ceil_log2(size), 6) + 1)},
      else: {:reg, t.bram_latency, :bram}
  end

  # One multiplier per product (split like a multiply), then a registered
  # adder tree.
  def cost(%{op: :dot, inputs: [a, b], attrs: {contract, _, _, _}}, graph, t) do
    n = contract |> Enum.map(&elem(graph.nodes[a].shape, &1)) |> Enum.product()
    split = dsp_split(t, signed_width(graph, a), signed_width(graph, b))
    {:reg, t.dsp_latency + split.levels + ceil_log2(n), :dsp48_tree}
  end

  # Wiring (signed wrap to fewer bits, `ExHdl.Passes.Idioms`).
  def cost(%{op: :wrap}, _graph, _t), do: {:comb, 0.0}

  # Priority encoder: OR trees over halves, then one mux level per bit of
  # the result, two per LUT.
  def cost(%{op: :msb, attrs: {j0, j1}}, _graph, t),
    do: {:comb, level_ns(t) * (2 + div(ceil_log2(j1 - j0 + 2) + 1, 2))}

  # Upper bound: all elements summed.
  def cost(%{op: :sum, inputs: [x]}, graph, t) do
    case graph.nodes[x].shape |> Tuple.to_list() |> Enum.product() do
      n when n <= 2 -> {:comb, adder(t, width(graph, x) + 1)}
      n -> {:reg, ceil_log2(n), :adder_tree}
    end
  end

  def cost(_node, _graph, t), do: {:comb, level_ns(t)}

  @doc "Short human description of a cost."
  def describe({:comb, ns}) when ns == 0, do: "wiring"
  def describe({:comb, ns}), do: "#{Float.round(ns, 2)} ns"
  def describe({:reg, n, kind}), do: "#{kind}, #{n} cycle#{if n > 1, do: "s"}"

  defp cost_ns({:comb, ns}), do: ns

  defp adder(t, bits), do: level_ns(t) + t.carry_ns_per_bit * bits

  defp width(graph, id) do
    {_, bits} = IntSet.bit_width(graph.nodes[id].range)
    bits
  end

  @doc false
  # Signed bits of a node's proven range.
  def signed_width(graph, id) do
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
