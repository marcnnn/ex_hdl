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
      `tdata`, and `p_load`. A cycle with `p_load` high captures all
      parameter ports into shadow registers; the kernel then accepts no
      further sample until the samples accepted so far (including one
      accepted in the `p_load` cycle) have left the pipeline, applies the
      new values and continues. So every sample sees one consistent
      parameter set, and the change takes effect at a known sample.

  `rst_n` (synchronous, active low) loads the initial state (`:init`) and
  the parameter ports directly.

  With `channels: n` the module also has

    * `m_axis_tid` - the channel of each output;
    * `s_axis_tid` (option `tid: true`) - the channel of each input sample,
      instead of the arrival order. Two samples of one channel must then be
      at least `n` beats apart (the loop's read-after-write distance; the
      round-robin order guarantees it).

  `tuser: bits` adds `s_axis_tuser`/`m_axis_tuser`, carried through the
  pipeline with the sample unchanged (shift registers without reset).

  ## State in memory

  `state_mem: :distributed | :block | :ultra` (with `channels: n`) keeps the
  state of all channels in one memory per state group (see
  `ExHdl.IR.Scan`), one word per channel, instead of registers. The word of
  a channel is read `ram_latency` cycles before the group's state stage and
  written back at its write stage. No forwarding is needed: the analysis
  requires `n >= loop latency + ram_latency`, so a channel's next sample
  reads after the write. `state_init: :clear` (default) writes `:init` to
  every word after reset, one per cycle, while the output `busy` is high
  and no sample is accepted; `state_init: :initial` puts `:init` into the
  memory's initial contents instead (no sweep, but reset does not clear).

  `state_fold: k` spreads a channel's state word over `k` rows of a memory
  `k` times narrower and `k` times deeper (row `r` of channel `ch` at
  `ch * k + r`), for states wider than they are deep. The memory keeps one
  port, so the kernel accepts one sample every `k` enabled cycles
  (throughput `1/k`; `s_axis_tready` drops for `k - 1` cycles after each
  sample). The rows are read one per cycle in the `k` stages before the
  state stage and written one per cycle from the write stage on. The
  datapath is not shared over the `k` cycles, so the DSP count does not
  change; folding pays where the stream has the idle cycles anyway (a
  1024 channel strip at 48 kHz on 250 MHz uses 1024 of 5208 cycles per
  frame).

  Every stage that reads state has its own memory, and a memory takes at
  least one UltraRAM (72 bits) however narrow it is. So with folding,
  consecutive memories merge while a row stays within `state_row_bits`
  (default 72) and the merged read-to-write span fits `channels * k`
  cycles; the later groups' state waits in pipeline registers from the
  first group's stage, the earlier groups' next state until the last
  write. ex_audio's strip (four biquads, gate, compressor: 636 bits in 13
  memories, 17 UltraRAMs at 1024 channels) with `k = 4` becomes 3
  memories of 66, 66 and 28 bits by 4096 rows, 3 UltraRAMs, for about
  13500 more pipeline register bits (`state_row_bits: 36`: 5 UltraRAMs,
  6200 bits; 0: no merging, 13 UltraRAMs). `Design.state_memories` has
  the shapes.

  ## Per-channel parameters

  `channel_params: [name, ...]` (or `:all`) reads those parameter arguments
  from a memory indexed by the channel instead of from ports, each leaf at
  the stage of its first use. The memory has two banks of `n` words. The
  host writes the inactive bank through

    * `pc_addr`, `pc_data`, `pc_we` - channel, all per-channel leaves packed
      like parameter ports (`Design.channel_params` has the offsets);
    * `pc_swap` - a pulse requesting a bank swap. The swap happens at the
      next frame boundary: when the next sample is channel 0 (round robin),
      or with `tid: true` before a sample whose channel is not greater than
      the previous one's (and right after reset). So every frame sees one
      consistent coefficient set;
    * `pc_pending` - high from `pc_swap` until the swap is done and no
      sample that reads the old bank is left in the pipeline. Write only
      while it is low.

  `pc_clock: :separate` adds `pc_clk` for the write port (`pc_addr`,
  `pc_data`, `pc_we`); `pc_swap` and `pc_pending` stay in the `clk` domain.
  `param_mem:` picks the memory style (default `:block`).

  ## Memories

  Parameters named in `memories:` (`ExHdl.IR.Memory`) are RAMs instead of
  ports: `Nx.take(table, index)` with an index from the sample or the
  state reads them, one read port per index element (a gather of 16 values
  is 16 reads), each from its own copy of the memory, `latency` cycles in
  the schedule. Each memory has a write port

    * `<name>_waddr`, `<name>_wdata`, `<name>_we` (and `<name>_wclk` with
      `clock: :separate`): one word, the row's values packed from bit 0 at
      the width of their proven range (`Design.memories` has the widths);
    * with `banks: 2` (default) the write goes to the inactive bank;
      `<name>_swap` makes it active from the next accepted sample (with
      `channels: n` from the next frame start, as for channel parameters),
      and `<name>_pending` stays high until no sample reading the old bank
      is left before its read stage. Write only while it is low.

  So a mixer reads a crosspoint table at the row of the sample and the
  samples of a frame memory at the sources it holds, while the host
  rewrites the table and the strip stage writes the next frame.

  ## Frame sideband

  With `frame: true` the sample is `{data..., {first, last}}`: `last` is
  `s_axis_tlast`, `first` is high for the first beat after reset and after
  every beat with `tlast`. A kernel that reduces over a frame (the rows of
  one output) uses them instead of counting, so frames have a runtime
  length. `m_axis_tlast` carries `tlast` to the last item of each sample.

  ## DSP products

  Products that fit the family's multiplier (`ExHdl.Target.Timing`, 25 x 18
  for DSP48E1, 27 x 18 for DSP48E2) are one slice with input, product and
  output registers. Wider ones are cut into pieces of one slice each
  (`Timing.dsp_split/3`), and a registered adder tree sums the shifted
  partial products: a 32 x 24 product is two slices, 32 x 32 four.
  `Design.dsp` counts the slices.

  With `ii: n` (one channel) multiplies of the same size share a DSP unit
  when no two samples can be at their stages at once: the stages of a unit
  are distinct and within `n` of each other, and the unit's inputs are
  multiplexed by the stage's valid bit. A multiply outside every feedback
  loop is delayed by up to `n - 1` stages to join a unit (`share: false`
  turns this off). The biquad at `ii: 8` needs 10 slices instead of 14.

  No ready path is combinational: `s_axis_tready` depends only on
  registers, `m_axis_tready` only on the two-entry output buffer.

  ## Structure

  Every node of the range-annotated graph becomes signals of its proven
  width (signed or unsigned), one per tensor element; views (slices,
  concatenations, reshapes) are wiring. The schedule
  (`ExHdl.Passes.Schedule`, `ExHdl.Target.Timing`) decides the pipeline
  stage of every node; values crossing stages go through pipeline
  registers. Multiplies use the DSP register pattern (input, product
  and output registers), large tables become block RAM with a registered
  read, small ones LUT ROM. Signed wraps are wiring and the leading-one
  idiom a priority encoder (`ExHdl.Passes.Idioms`). Dot products of constant taps with a delay
  line become transposed DSP chains (`ExHdl.Backends.SystemVerilog.Fir`).
  All pipeline registers share one clock enable `ce`: the pipeline
  advances while the two-entry output buffer has room.

  Each state group is read in its stage `S`, where everything its update
  needs from outside its loop (including other groups' results) is
  available, and written back at the end of the stage where its next state
  is complete. With `ii: n` the input accepts
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
        (without stalls), including the output buffer.
      * `ii`, `channels` - as in `ExHdl.IR.Scan`.
      * `state_stage`, `write_stage` - first stage reading and last stage
        writing state; `state_groups` the stages per group:
        `%{leaves:, state_stage:, write_stage:}`.
      * `state_mem` - where the state lives (`:registers`, `:distributed`,
        `:block`, `:ultra`); `busy` is true when the module has a `busy`
        output (state clear after reset).
      * `state_fold` - memory rows per channel state word, and
        `state_memories` the state memories as
        `%{bits:, width:, depth:}` (`bits` of state per channel, `width`
        and `depth` of the memory: `width * state_fold >= bits`,
        `depth = channels * state_fold`).
      * `channel_params` - the per-channel parameter leaves
        `%{name:, index:, type:, shape:, bits:, offset:}` in the `pc_data`
        word of `pc_width` bits; `pc_clock` `:shared` or `:separate`.
      * `tid`, `tuser` - whether the module has `s_axis_tid`, and the
        `tuser` width (0 without).
      * `inputs`, `outputs` - the tdata fields:
        `%{index:, type:, shape:, offset:, bits:}` (`bits` per element).
      * `params` - the parameter ports: `%{port:, index:, type:, shape:, bits:}`.
      * `in_width`, `out_width` - tdata widths.
      * `lanes` - `nil`, or the most items one sample can give (variable rate).
      * `frame` - true when the module has `s_axis_tlast`/`m_axis_tlast`
        (frame sideband, `frame: true`).
      * `memories` - the memory parameters with their write ports:
        `%{name:, depth:, row:, bits:, signed:, banks:, style:, latency:,
        clock:, read_ports:, addr_bits:, data_bits:}`.
      * `dsp` - DSP slices the module needs by the timing model's multiplier
        size (split products count all pieces, a shared unit once), and
        `shared` the number of units shared by several multiplies.
    """
    defstruct [
      :name,
      :lanes,
      :source,
      :latency,
      :ii,
      :channels,
      :state_stage,
      :write_stage,
      :inputs,
      :busy,
      :outputs,
      :params,
      :in_width,
      :out_width,
      state_groups: [],
      state_mem: :registers,
      state_fold: 1,
      state_memories: [],
      channel_params: [],
      pc_width: 0,
      pc_clock: :shared,
      tid: false,
      tuser: 0,
      frame: false,
      memories: [],
      dsp: 0,
      shared: 0
    ]
  end

  @elementwise ~w(add subtract multiply remainder quotient negate abs min max clip select
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

  # data-dependent takes from computed values up to this size become a multiplexer
  @max_mux 1024

  @binary %{add: "+", subtract: "-", bitwise_and: "&", bitwise_or: "|", bitwise_xor: "^"}

  @doc """
  Generates the module for `scan`.

  Options:
    * `:name` - module name (default `"scan_kernel"`).
    * `:init` - initial state, a container shaped like the state argument
      (tensors, `NxFixed.Fixed`, integers); default all zeros.
    * `:param_names` - port names for the parameter arguments in order
      (default `param<i>` for argument `i`); ports are prefixed with `p_`.
    * `:lanes` - variable rate: the kernel returns `{values, count}` with
      `lanes` items on the first axis of every value; the first `count`
      are valid and leave through the output buffer one per beat.
    * `:fir` - `:chain` (default) maps FIR dot products onto DSP chains,
      `:tree` keeps multipliers and an adder tree.
    * `:state_init` - `:clear` (default) or `:initial`, for `state_mem:`
      other than `:registers` (see "State in memory").
    * `:state_row_bits` - with `state_fold: k`, the row width up to which
      state memories merge (default 72; 0 keeps one memory per stage).
    * `:tid`, `:tuser` - channel input and sideband width.
    * `:channel_params`, `:param_mem`, `:param_ram_latency`, `:pc_clock` -
      per-channel parameters (see "Per-channel parameters").
    * `:share` - `:auto` (default) or `false`: DSP sharing under `ii: n`.

  Returns a `%Design{}`; raises `UnsupportedError`.
  """
  def generate(%Scan{} = scan, opts \\ []) do
    name = Keyword.get(opts, :name, "scan_kernel")
    graph = scan.graph
    timing = scan.timing || Timing.new(opts)

    check_supported!(graph)

    layout = layout(scan, opts)
    check_options!(scan, layout)
    check_memories!(scan)
    {stages, sched} = schedule(scan, timing, layout, scan.costs)
    c = context(scan, timing, layout, stages, sched, %{})

    # FIR dot products become DSP chains with their own latency: plan them
    # on a first lowering, then schedule and lower again.
    fir =
      if Keyword.get(opts, :fir, :chain) == :chain,
        do: Fir.plan(Enum.reduce(graph.order, %{c | planning: true}, &lower/2), scan),
        else: %{}

    costs = Map.merge(scan.costs, Fir.costs(fir))

    c =
      if fir == %{} do
        c
      else
        {stages, sched} = schedule(scan, timing, layout, costs)
        context(scan, timing, layout, stages, sched, fir)
      end

    # multiplies sharing DSP slices under ii: n
    c =
      case share_plan(scan, timing, layout, costs, c) do
        nil ->
          c

        {starts, plan} ->
          {stages, sched} = schedule(scan, timing, layout, costs, starts)
          %{context(scan, timing, layout, stages, sched, fir) | share: plan}
      end

    c = Enum.reduce(graph.order, c, &lower/2)
    c = emit_units(c)
    {c, groups} = state_writes(c, scan)

    for g <- groups, scan.state_fold == 1 do
      loop = g.write_stage - g.state_stage + 1 + scan.ram_latency

      if loop > scan.ii do
        raise UnsupportedError,
              "scan: the generated state update needs #{loop} cycles (stages #{g.state_stage}-#{g.write_stage}" <>
                "#{if scan.ram_latency > 0, do: ", memory read #{scan.ram_latency}", else: ""}), " <>
                "more than ii: #{scan.ii}; this is a mismatch between the schedule and the generator"
      end
    end

    check_folded!(c, groups, scan)

    state_stage = groups |> Enum.map(& &1.state_stage) |> Enum.min(fn -> 0 end)
    write_stage = groups |> Enum.map(& &1.write_stage) |> Enum.max(fn -> 0 end)

    {c, latency, out_expr} = outputs(c, scan)

    depth =
      Enum.max(
        [latency, write_stage + scan.state_fold - 1 | Map.values(c.pc_stages)] ++
          Enum.map(c.mem_reads, & &1.stage) ++
          Enum.flat_map(Map.values(c.units), fn ms -> Enum.map(ms, & &1.stage) end)
      )

    source =
      emit(c, %{
        name: name,
        scan: scan,
        latency: latency,
        depth: depth,
        groups: groups,
        out_expr: out_expr
      })

    %Design{
      name: name,
      lanes: layout.lanes,
      source: source,
      latency: latency + 1,
      ii: scan.ii,
      channels: scan.channels,
      state_stage: state_stage,
      write_stage: write_stage,
      state_groups: Enum.map(groups, &Map.take(&1, [:leaves, :state_stage, :write_stage])),
      state_mem: scan.state_mem,
      state_fold: scan.state_fold,
      state_memories: state_memories(c),
      busy: scan.state_mem != :registers and layout.state_init == :clear and groups != [],
      inputs: layout.inputs,
      outputs: layout.outputs,
      params: layout.params,
      channel_params: layout.chan_params,
      pc_width: layout.pc_width,
      pc_clock: layout.pc_clock,
      tid: layout.tid,
      tuser: layout.tuser,
      frame: layout.frame != nil,
      memories: memory_ports(c),
      dsp: c.dsp,
      shared: c.share |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length(),
      in_width: layout.in_width,
      out_width: layout.out_width
    }
  end

  defp context(scan, timing, layout, stages, sched, fir) do
    users =
      for id <- scan.graph.order, input <- Enum.uniq(scan.graph.nodes[id].inputs), reduce: %{} do
        acc -> Map.update(acc, input, [id], &[id | &1])
      end

    c = %{
      graph: scan.graph,
      timing: timing,
      sched: sched,
      layout: layout,
      users: users,
      # state stage of every state parameter (Nx index), and of each group
      state_stages: stages.by_index,
      groups: scan.groups,
      group_stages: stages.groups,
      state_mem: scan.state_mem,
      ram_latency: scan.ram_latency,
      state_fold: scan.state_fold,
      pc_stages: %{},
      channels: scan.channels,
      sigs: %{},
      defs: %{},
      decls: [],
      assigns: [],
      ffs: [],
      sample_ffs: [],
      combs: [],
      raw_decls: [],
      blocks: [],
      elems: %{},
      roms: %{},
      fir: fir,
      planning: false,
      # DSP slices, `{id, e} => unit` of shared multiplies, units' members
      dsp: 0,
      share: %{},
      units: %{},
      # memory reads: `%{mem:, copy:, stage:, addr:, q:}`
      mem_reads: []
    }

    # per-channel parameters are read from their memory where first used
    pc_stages =
      for p <- layout.chan_params, into: %{} do
        id = Enum.find(scan.graph.order, &(param_index(scan.graph, &1) == p.index))
        use = id && first_use(c, id)
        {p.index, max(layout.pc_latency, use || layout.pc_latency)}
      end

    %{c | pc_stages: pc_stages}
  end

  defp param_index(graph, id) do
    node = graph.nodes[id]
    if node.op == :parameter, do: node.attrs
  end

  # Views are wiring: the stage where the value first enters an operation.
  @views [:as_type, :reshape, :squeeze, :broadcast, :transpose, :slice, :concatenate]

  defp first_use(c, id) do
    c.users
    |> Map.get(id, [])
    |> Enum.map(fn u ->
      if c.graph.nodes[u].op in @views, do: first_use(c, u), else: exec_stage(c, u)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
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
               :sum,
               :wrap,
               :msb
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
    mem_indices = MapSet.new(scan.memories, & &1.index)

    frame_indices =
      if scan.frame, do: MapSet.new([scan.frame.first, scan.frame.last]), else: MapSet.new()

    {inputs, in_bits} =
      sample |> Enum.reject(&MapSet.member?(frame_indices, &1.index)) |> fields()

    lanes = Keyword.get(opts, :lanes)
    {value_ids, count_id} = output_ids(scan, lanes)

    outputs =
      Enum.map(value_ids, fn id ->
        shape = scan.graph.nodes[id].shape
        shape = if lanes, do: Tuple.delete_at(shape, 0), else: shape
        %{index: id, type: scan.graph.nodes[id].type, shape: shape}
      end)

    {outputs, out_bits} = fields(outputs)

    per_channel = Keyword.get(opts, :channel_params, [])

    {chan_params, params} =
      param_args
      |> Enum.with_index()
      |> Enum.flat_map(fn {arg, k} ->
        base = Enum.at(names, k) || "param#{arg.arg}"
        chan? = per_channel == :all or base in List.wrap(per_channel)

        case arg.leaves do
          [leaf] ->
            [{base, leaf, chan?}]

          leaves ->
            leaves |> Enum.with_index() |> Enum.map(fn {l, i} -> {"#{base}_#{i}", l, chan?} end)
        end
      end)
      |> Enum.reject(fn {_n, leaf, _chan?} -> MapSet.member?(mem_indices, leaf.index) end)
      |> Enum.map(fn {n, leaf, chan?} ->
        {chan?, Map.merge(leaf, %{port: "p_#{n}", name: n, bits: type_bits(leaf.type)})}
      end)
      |> Enum.split_with(&elem(&1, 0))

    params = Enum.map(params, &elem(&1, 1))

    {chan_params, pc_bits} =
      chan_params
      |> Enum.map(&(&1 |> elem(1) |> Map.delete(:port)))
      |> fields()

    known =
      param_args
      |> Enum.with_index()
      |> Enum.map(fn {arg, k} -> Enum.at(names, k) || "param#{arg.arg}" end)

    for name <- if(per_channel == :all, do: [], else: List.wrap(per_channel)),
        name not in known,
        do:
          raise(
            ArgumentError,
            "scan: channel_params: no parameter argument named #{inspect(name)}"
          )

    params_by_index = Map.new(params, &{&1.index, &1})
    inputs_by_index = Map.new(inputs, &{&1.index, &1})

    init = init_values(Keyword.get(opts, :init), state)

    states =
      state
      |> Enum.with_index()
      |> Enum.map(fn {leaf, k} -> Map.merge(leaf, %{leaf: k, init: Enum.at(init, k)}) end)

    param_mem = Keyword.get(opts, :param_mem, :block)
    pc_latency = Keyword.get(opts, :param_ram_latency, if(param_mem == :ultra, do: 2, else: 1))

    %{
      lanes: lanes,
      count_id: count_id,
      inputs: inputs,
      outputs: outputs,
      params: params,
      chan_params: chan_params,
      chan_by_index: Map.new(chan_params, &{&1.index, &1}),
      pc_width: pc_bits,
      pc_latency: pc_latency,
      param_mem: param_mem,
      pc_clock: Keyword.get(opts, :pc_clock, :shared),
      tid: Keyword.get(opts, :tid, false),
      tuser: Keyword.get(opts, :tuser, 0),
      frame: scan.frame,
      memories: scan.memories,
      mem_by_index: Map.new(scan.memories, &{&1.index, &1}),
      share: Keyword.get(opts, :share, :auto),
      state_init: Keyword.get(opts, :state_init, :clear),
      state_row_bits: Keyword.get(opts, :state_row_bits, 72),
      params_by_index: params_by_index,
      inputs_by_index: inputs_by_index,
      states: states,
      states_by_index: Map.new(states, &{&1.index, &1}),
      in_width: byte_align(in_bits),
      out_width: byte_align(out_bits)
    }
  end

  # Variable rate (`lanes: max`): the kernel output is `{values, count}`,
  # every value leaf with `max` items on its first axis.
  defp output_ids(scan, nil), do: {flatten(scan.outputs), nil}

  defp output_ids(scan, lanes) do
    case scan.outputs do
      {values, count} when is_integer(count) ->
        ids = flatten(values)

        bad =
          Enum.reject(ids, fn id ->
            shape = scan.graph.nodes[id].shape
            tuple_size(shape) >= 1 and elem(shape, 0) == lanes
          end)

        if bad != [] or scan.graph.nodes[count].shape != {},
          do:
            raise(
              UnsupportedError,
              "scan: lanes: #{lanes} needs the output {values, count} with #{lanes} items on the first axis of every value and a scalar count"
            )

        {ids, count}

      _ ->
        raise UnsupportedError, "scan: lanes: #{lanes} needs the kernel output {values, count}"
    end
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

  defp check_options!(scan, l) do
    multi = scan.channels > 1

    problem =
      cond do
        l.tid and not multi ->
          "tid: true needs channels: n"

        l.chan_params != [] and not multi ->
          "channel_params: needs channels: n"

        l.param_mem not in [:distributed, :block, :ultra] ->
          "param_mem: must be :distributed, :block or :ultra"

        not (is_integer(l.pc_latency) and l.pc_latency >= 1) ->
          "param_ram_latency: must be a positive integer"

        l.pc_clock not in [:shared, :separate] ->
          "pc_clock: must be :shared or :separate"

        l.state_init not in [:clear, :initial] ->
          "state_init: must be :clear or :initial"

        not (is_integer(l.state_row_bits) and l.state_row_bits >= 0) ->
          "state_row_bits: must be a non-negative integer"

        not (is_integer(l.tuser) and l.tuser >= 0) ->
          "tuser: must be a bit width"

        true ->
          nil
      end

    if problem, do: raise(ArgumentError, "scan: " <> problem)
  end

  # -- schedule ------------------------------------------------------------------------------

  # Static values (parameter ports, constants and what is computed only from
  # them) need no pipeline registers. Per-channel parameters arrive from
  # their memory `pc_latency` cycles after the sample. Each state group
  # (in dependency order) is read in the stage where every non-static value
  # entering its loop is available, at least `ram_latency` (the state
  # memory's read is issued that much earlier).
  defp schedule(scan, timing, layout, costs, starts \\ %{}) do
    graph = scan.graph
    static = static_nodes(graph, layout)

    pc_seeds =
      for id <- graph.order,
          Map.has_key?(layout.chan_by_index, param_index(graph, id)),
          into: %{},
          do: {id, {layout.pc_latency, 0.0}}

    {seeds, stages} =
      Enum.reduce(scan.groups, {pc_seeds, []}, fn g, {seeds, stages} ->
        sched = Schedule.asap(graph, graph.order, timing, seeds, costs, starts)

        entering =
          for(
            id <- MapSet.to_list(g.recurrence),
            input <- graph.nodes[id].inputs,
            not MapSet.member?(g.recurrence, input),
            do: input
          ) ++ Enum.reject(g.next, &MapSet.member?(g.recurrence, &1))

        stage =
          entering
          |> Enum.uniq()
          |> Enum.reject(&(MapSet.member?(static, &1) or &1 in g.params))
          |> Enum.map(fn id -> available(sched[id].at) end)
          |> Enum.max(fn -> 0 end)
          |> max(scan.ram_latency + scan.state_fold - 1)

        {Enum.reduce(g.params, seeds, &Map.put(&2, &1, {stage, 0.0})), [stage | stages]}
      end)

    by_index = Map.new(scan.state_params, &{graph.nodes[&1].attrs, elem(seeds[&1], 0)})

    {%{by_index: by_index, groups: Enum.reverse(stages)},
     Schedule.asap(graph, graph.order, timing, seeds, costs, starts)}
  end

  # -- DSP sharing under ii: n -----------------------------------------------------------

  # With one sample every ii cycles a DSP unit can serve multiplies of
  # different stages, as long as no two samples can be at two of them at
  # once: samples are at least ii enabled cycles apart, so the stages of a
  # unit must be distinct and within a window of ii. A unit's inputs are
  # multiplexed by the valid bit of each member's stage. Multiplies are
  # placed greedily in graph order; one outside every feedback loop may be
  # delayed by up to ii - 1 stages to join a unit (latency, not loop time).
  # Multiplies of different sizes (DSP pieces) do not share. Returns nil
  # or `{starts, %{signal => {unit, swap?}}}`.
  defp share_plan(scan, timing, layout, costs, c) do
    if layout.share == false or scan.channels != 1 or scan.ii < 2 do
      nil
    else
      graph = scan.graph
      static = static_nodes(graph, layout)

      cands =
        for id <- graph.order,
            node = graph.nodes[id],
            node.op == :multiply,
            not singleton?(node.range),
            match?({:reg, _, _}, c.sched[id].cost),
            not Enum.all?(node.inputs, &MapSet.member?(static, &1)),
            do: id

      {starts, units, plan} =
        Enum.reduce(cands, {%{}, [], %{}}, fn id, {starts, units, plan} ->
          node = graph.nodes[id]
          {_, sched} = schedule(scan, timing, layout, costs, starts)
          e0 = sched_exec(sched, id)
          [wa, wb] = Enum.map(node.inputs, &Timing.signed_width(graph, &1))
          swap = wb > wa
          {wa, wb} = if swap, do: {wb, wa}, else: {wa, wb}
          count = Timing.dsp_split(timing, wa, wb).count
          n = size(node.shape)
          last = if MapSet.member?(scan.recurrence, id), do: e0, else: e0 + scan.ii - 1
          fits = fn s -> fitting_units(units, s, timing, count, wa, wb, scan.ii) end

          {s, chosen} =
            Enum.find_value(e0..last, fn s ->
              fit = fits.(s)
              if length(fit) >= n, do: {s, Enum.take(fit, n)}
            end) || {e0, Enum.take(fits.(e0), n)}

          fresh = Enum.to_list(length(units)..(length(units) + n - length(chosen) - 1)//1)
          new = for _ <- fresh, do: %{stages: [], wa: wa, wb: wb, count: count, members: []}
          units = units ++ new

          units =
            Enum.reduce(chosen ++ fresh, units, fn u, units ->
              List.update_at(units, u, fn unit ->
                %{
                  unit
                  | stages: [s | unit.stages],
                    wa: max(unit.wa, wa),
                    wb: max(unit.wb, wb),
                    members: [id | unit.members]
                }
              end)
            end)

          plan =
            (chosen ++ fresh)
            |> Enum.with_index()
            |> Enum.reduce(plan, fn {u, e}, plan ->
              Map.put(plan, elem_name(node, e), {u, swap})
            end)

          starts = if s > e0, do: Map.put(starts, id, s), else: starts
          {starts, units, plan}
        end)

      shared =
        for {u, i} <- Enum.with_index(units), length(u.members) >= 2, into: MapSet.new(), do: i

      plan = for {name, {u, _} = v} <- plan, MapSet.member?(shared, u), into: %{}, do: {name, v}
      {_, sched} = schedule(scan, timing, layout, costs, starts)

      ok? =
        Enum.all?(shared, fn u ->
          stages = units |> Enum.at(u) |> Map.fetch!(:members) |> Enum.map(&sched_exec(sched, &1))

          length(Enum.uniq(stages)) == length(stages) and
            Enum.max(stages) - Enum.min(stages) < scan.ii
        end)

      if plan != %{} and ok?, do: {starts, plan}
    end
  end

  defp fitting_units(units, s, timing, count, wa, wb, ii) do
    for {u, i} <- Enum.with_index(units),
        u.count == count,
        s not in u.stages,
        Enum.max([s | u.stages]) - Enum.min([s | u.stages]) < ii,
        Timing.dsp_split(timing, max(u.wa, wa), max(u.wb, wb)).count == count,
        do: i
  end

  defp sched_exec(sched, id) do
    case sched[id] do
      %{at: {cycle, _}, cost: {:reg, k, _}} -> cycle - k
      %{at: {cycle, _}} -> cycle
    end
  end

  # A member of a shared unit: its operands go to the unit's input
  # multiplexer (`emit_units/1`), its result is the unit's output in its
  # own stage + k.
  defp shared_product(c, name, {u, swap}, [a, b], stage, k, fmt) do
    {a, b} = if swap, do: {b, a}, else: {a, b}
    {c, xa, wa} = operand(c, a, stage)
    {c, xb, wb} = operand(c, b, stage)
    member = %{stage: stage, a: xa, wa: wa, b: xb, wb: wb, k: k}
    c = %{c | units: Map.update(c.units, u, [member], &[member | &1])}
    c = c |> new_sig(name, fmt, stage + k, true) |> assign(name, "#{bits(fmt)}'(u#{u}_r)")
    {c, {:sig, name}}
  end

  defp emit_units(c) do
    c.units
    |> Enum.sort()
    |> Enum.reduce(c, fn {u, members}, c ->
      members = Enum.sort_by(members, & &1.stage)
      wa = members |> Enum.map(& &1.wa) |> Enum.max()
      wb = members |> Enum.map(& &1.wb) |> Enum.max()
      k = hd(members).k

      mux = fn key, w ->
        {init, rest} = List.pop_at(members, -1)

        rest
        |> Enum.reverse()
        |> Enum.reduce("#{w}'(#{Map.fetch!(init, key)})", fn m, acc ->
          "#{valid(m.stage)} ? #{w}'(#{Map.fetch!(m, key)}) : #{acc}"
        end)
      end

      ain = "u#{u}_ain"
      bin = "u#{u}_bin"

      c =
        c
        |> new_sig(ain, {:s, wa}, 0, false)
        |> assign(ain, mux.(:a, wa))
        |> new_sig(bin, {:s, wb}, 0, false)
        |> assign(bin, mux.(:b, wb))

      {c, _} = dsp_product(c, "u#{u}_r", [{:sig, ain}, {:sig, bin}], 0, k, {:s, wa + wb})
      c
    end)
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
      Map.has_key?(l.mem_by_index, index) ->
        # a memory: only its takes read it (`memory_read`)
        {c, []}

      l.frame && index in [l.frame.first, l.frame.last] ->
        name = elem_name(node, 0)
        src = if index == l.frame.first, do: "fr_first", else: "s_axis_tlast"
        c = c |> new_sig(name, fmt, 0, false) |> assign(name, "#{bits(fmt)}'(#{src})")
        {c, [{:sig, name}]}

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
          {assign(c, name, "#{port.port}_q[#{e * port.bits} +: #{bits(fmt)}]"), {:sig, name}}
        end)

      Map.has_key?(l.chan_by_index, index) ->
        # read from the leaf's memory (emitted with the bank logic) in its stage
        k = Enum.find_index(l.chan_params, &(&1.index == index))
        r = c.pc_stages[index]
        w = bits(fmt)

        map_c(0..(size(node.shape) - 1), c, fn e, c ->
          name = elem_name(node, e)
          c = c |> new_sig(name, fmt, r, false) |> assign(name, "pc#{k}_q[#{e * w} +: #{w}]")
          {c, {:sig, name}}
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

  defp lower_op(:wrap, node, c) do
    [x] = node.inputs
    stage = exec_stage(c, node.id)
    fmt = IntSet.bit_width(node.range)
    w = bits(fmt)

    c.elems[x]
    |> Tuple.to_list()
    |> Enum.with_index()
    |> map_c(c, fn
      {{:lit, v}, _e}, c ->
        half = 1 <<< (node.attrs - 1)
        {c, {:lit, band(v + half, (1 <<< node.attrs) - 1) - half}}

      {ref, e}, c ->
        name = elem_name(node, e)
        {c, x} = raw(c, ref, stage)
        s = if static?(c, ref), do: :static, else: stage
        # the low bits of x, sign-extended from bit attrs - 1
        c =
          c
          |> new_sig(name, fmt, s, false)
          |> assign(name, "#{w}'($signed(#{node.attrs}'(#{x})))")

        {c, {:sig, name}}
    end)
  end

  defp lower_op(:msb, node, c) do
    [x] = node.inputs
    {j0, j1} = node.attrs
    stage = exec_stage(c, node.id)
    fmt = IntSet.bit_width(node.range)
    ref = elem(c.elems[x], 0)

    case ref do
      {:lit, v} ->
        {c, [{:lit, Enum.count(j0..j1, &(v >= 1 <<< &1))}]}

      _ ->
        name = elem_name(node, 0)
        s = if static?(c, ref), do: :static, else: stage
        {c, expr} = priority_encoder(c, name, ref, ref_range(c, ref), j0, j1, stage)
        c = c |> new_sig(name, fmt, s, false) |> assign(name, "#{bits(fmt)}'(#{expr})")
        {c, [{:sig, name}]}
    end
  end

  defp lower_op(:take, node, c) do
    [table_id, _idx_id] = node.inputs
    table = Dataflow.constant_tensor(c.graph, table_id)

    cond do
      mem = c.layout.mem_by_index[param_index(c.graph, table_id)] ->
        memory_read(node, c, mem)

      table && tuple_size(table.shape) == 1 ->
        rom_take(node, c, table)

      tuple_size(c.graph.nodes[table_id].shape) != 1 ->
        unsupported!(c.graph, node, "needs a 1-D table")

      plan = c.fir[{:take, node.id}] ->
        memory_take(node, c, plan)

      size(c.graph.nodes[table_id].shape) > @max_mux and c.planning ->
        # the plan decides; a placeholder value meanwhile
        map_c(0..(size(node.shape) - 1), c, fn e, c ->
          name = elem_name(node, e)

          {new_sig(c, name, IntSet.bit_width(node.range), exec_stage(c, node.id), false),
           {:sig, name}}
        end)

      size(c.graph.nodes[table_id].shape) > @max_mux ->
        unsupported!(
          c.graph,
          node,
          "with a data-dependent index into #{size(c.graph.nodes[table_id].shape)} values " <>
            "is only supported up to #{@max_mux} values (a multiplexer) or as a delay line read"
        )

      true ->
        mux_take(node, c)
    end
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
    in_shape = c.graph.nodes[x].shape
    rank = tuple_size(in_shape)

    axes =
      (node.attrs[:axes] || Enum.to_list(0..(rank - 1)//1)) |> Enum.map(&rem(&1 + rank, rank))

    keep? = node.attrs[:keep_axes] || false
    stage = exec_stage(c, node.id)
    fmt = IntSet.bit_width(node.range)

    # input elements of every output element
    groups =
      indices(in_shape)
      |> Enum.with_index()
      |> Enum.group_by(
        fn {i, _} ->
          out =
            for {k, axis} <- Enum.with_index(i),
                keep? or axis not in axes,
                do: if(axis in axes, do: 0, else: k)

          flat(out, node.shape)
        end,
        fn {_, flat_in} -> elem(c.elems[x], flat_in) end
      )

    0..(size(node.shape) - 1)
    |> map_c(c, fn e, c ->
      terms = groups |> Map.fetch!(e) |> Enum.map(&{&1, ref_range(c, &1)})
      name = elem_name(node, e)

      case c.sched[node.id].cost do
        {:reg, k, _} ->
          adder_tree(c, name, terms, stage, k, fmt)

        _ ->
          {c, expr} = sum_expr(c, Enum.map(terms, &elem(&1, 0)), stage, fmt)
          s = if Enum.all?(terms, &static?(c, elem(&1, 0))), do: :static, else: stage
          {c |> new_sig(name, fmt, s, false) |> assign(name, expr), {:sig, name}}
      end
    end)
  end

  defp rom_take(node, c, table) do
    [_table_id, idx_id] = node.inputs
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

  # A take from a memory parameter: one read port (and memory copy) per
  # index element, the address registered into the RAM in the take's stage,
  # the word `latency` stages later. Every value of the row is a slice.
  defp memory_read(node, c, mem) do
    [_table_id, idx_id] = node.inputs
    stage = exec_stage(c, node.id)
    fmt = IntSet.bit_width(node.range)
    aw = max(1, ceil_log2(mem.depth))
    {_, mb} = mem.fmt
    word = mem.row * mb

    {c, parts} =
      c.elems[idx_id]
      |> Tuple.to_list()
      |> Enum.with_index()
      |> map_c(c, fn {ref, j}, c ->
        copy = Enum.count(c.mem_reads, &(&1.mem == mem.name))
        q = "n#{node.id}_q#{j}"
        {c, a} = raw(c, ref, stage)
        read = %{mem: mem.name, copy: copy, stage: stage, addr: "#{aw}'(#{a})", q: q}
        c = %{c | mem_reads: c.mem_reads ++ [read]}
        c = new_sig(c, q, {:u, word}, stage + 1, true)
        {c, qd} = at(c, q, stage + mem.latency)

        map_c(0..(mem.row - 1), c, fn r, c ->
          name = elem_name(node, j * mem.row + r)
          slice = "#{qd}[#{r * mb} +: #{mb}]"
          slice = if elem(mem.fmt, 0) == :s, do: "$signed(#{slice})", else: slice

          c =
            c
            |> new_sig(name, fmt, stage + mem.latency, true)
            |> assign(name, "#{bits(fmt)}'(#{slice})")

          {c, {:sig, name}}
        end)
      end)

    {c, List.flatten(parts)}
  end

  defp check_memories!(scan) do
    for mem <- scan.memories, id <- mem.takes do
      [_, idx] = scan.graph.nodes[id].inputs
      {lo, hi} = IntSet.bounds(scan.graph.nodes[idx].range)

      if lo < 0 or hi > mem.depth - 1,
        do:
          raise(
            UnsupportedError,
            "scan: the index of #{mem.name} (node #{idx}) is proven in #{lo}..#{hi}, " <>
              "outside the memory's 0..#{mem.depth - 1}; clamp it or declare its range"
          )
    end
  end

  # The memories of the design for `Design.memories`.
  defp memory_ports(c) do
    Enum.map(c.layout.memories, fn m ->
      {kind, mb} = m.fmt

      %{
        name: m.name,
        depth: m.depth,
        row: m.row,
        bits: mb,
        signed: kind == :s,
        banks: m.banks,
        style: m.style,
        latency: m.latency,
        clock: m.clock,
        read_ports: Enum.count(c.mem_reads, &(&1.mem == m.name)),
        addr_bits: max(1, ceil_log2(m.depth)),
        data_bits: m.row * mb
      }
    end)
  end

  defp memory_port_decls(c) do
    Enum.map(memory_ports(c), fn m ->
      [
        if(m.clock == :separate, do: "  input  logic #{m.name}_wclk,\n", else: []),
        "  input  logic [#{m.addr_bits - 1}:0] #{m.name}_waddr,\n",
        "  input  logic [#{m.data_bits - 1}:0] #{m.name}_wdata,\n",
        "  input  logic #{m.name}_we,\n",
        if(m.banks == 2,
          do: "  input  logic #{m.name}_swap,\n  output logic #{m.name}_pending,\n",
          else: []
        )
      ]
    end)
  end

  # Memories: one copy per read port, all written by the write port. With
  # two banks the host writes the inactive one; `<name>_swap` makes it
  # active for the next sample (with channels: n at the next frame start),
  # and `<name>_pending` stays high until no sample reading the old bank
  # is left before its read stage.
  defp memory_logic(c) do
    l = c.layout
    n = c.channels
    cw = max(1, bit_len(n - 1))

    Enum.map(memory_ports(c), fn m ->
      reads = Enum.filter(c.mem_reads, &(&1.mem == m.name))
      last_read = reads |> Enum.map(& &1.stage) |> Enum.max(fn -> 0 end)
      marks = max(1, last_read)
      wclk = if m.clock == :separate, do: "#{m.name}_wclk", else: "clk"
      x = m.name
      depth = if m.banks == 2, do: 2 * pow2(m.depth), else: m.depth
      waddr = if m.banks == 2, do: "{~#{x}_active, #{x}_waddr}", else: "#{x}_waddr"
      style = ram_style(m.style)

      frame_start =
        cond do
          n == 1 -> "1'b1"
          l.tid -> "#{x}_fresh || (vld_0 && s_axis_tid <= #{x}_last)"
          true -> "#{ch(0)} == #{cw}'d0"
        end

      banks =
        if m.banks == 2 do
          [
            "  logic #{x}_active, #{x}_req, #{x}_flip;\n",
            Enum.map(0..last_read, &"  logic #{x}_bank_#{&1};\n"),
            "  logic [#{marks}:1] #{x}_mark;\n",
            if(l.tid and n > 1,
              do: "  logic #{x}_fresh;\n  logic [#{cw - 1}:0] #{x}_last;\n",
              else: []
            ),
            "  assign #{x}_flip = ce && #{x}_req && (#{frame_start});\n",
            "  assign #{x}_bank_0 = #{x}_active ^ #{x}_flip;\n",
            "  assign #{x}_pending = #{x}_req || (#{x}_mark != '0);\n",
            "  always_ff @(posedge clk) begin\n",
            "    if (!rst_n) begin\n",
            "      #{x}_active <= 1'b0;\n",
            "      #{x}_req <= 1'b0;\n",
            "      #{x}_mark <= '0;\n",
            if(l.tid and n > 1,
              do: "      #{x}_fresh <= 1'b1;\n      #{x}_last <= '0;\n",
              else: []
            ),
            "    end else begin\n",
            "      if (#{x}_flip) #{x}_active <= ~#{x}_active;\n",
            "      if (#{x}_flip) #{x}_req <= 1'b0;\n",
            "      else if (#{x}_swap) #{x}_req <= 1'b1;\n",
            "      if (ce) #{x}_mark <= #{if marks == 1, do: "#{x}_flip", else: "{#{x}_mark[#{marks - 1}:1], #{x}_flip}"};\n",
            if(l.tid and n > 1,
              do: [
                "      if (ce && vld_0) begin\n",
                "        #{x}_fresh <= 1'b0;\n",
                "        #{x}_last <= s_axis_tid;\n",
                "      end\n"
              ],
              else: []
            ),
            "    end\n",
            "  end\n",
            if(last_read > 0,
              do: [
                "  always_ff @(posedge clk) begin\n",
                "    if (ce) begin\n",
                Enum.map(1..last_read//1, &"      #{x}_bank_#{&1} <= #{x}_bank_#{&1 - 1};\n"),
                "    end\n",
                "  end\n"
              ],
              else: []
            )
          ]
        else
          []
        end

      copies =
        Enum.map(reads, fn r ->
          mem = "#{x}_c#{r.copy}"
          addr = if m.banks == 2, do: "{#{x}_bank_#{r.stage}, #{r.addr}}", else: r.addr

          [
            "  (* ram_style = \"#{style}\" *) logic [#{m.data_bits - 1}:0] #{mem} [#{depth}];\n",
            "  always_ff @(posedge #{wclk}) begin\n",
            "    if (#{x}_we) #{mem}[#{waddr}] <= #{x}_wdata;\n",
            "  end\n",
            "  always_ff @(posedge clk) begin\n",
            "    if (ce) #{r.q} <= #{mem}[#{addr}];\n",
            "  end\n"
          ]
        end)

      [
        "  // memory #{x}: #{m.depth} x #{m.row} values of #{m.bits} bits, #{m.banks} bank#{if m.banks > 1, do: "s"}, ",
        "#{length(reads)} read port#{if length(reads) != 1, do: "s"} (one copy each), read latency #{m.latency}\n",
        banks,
        copies
      ]
    end)
  end

  # A data-dependent take from computed values: a multiplexer.
  defp mux_take(node, c) do
    [table_id, idx_id] = node.inputs
    table = Tuple.to_list(c.elems[table_id])
    stage = exec_stage(c, node.id)
    fmt = IntSet.bit_width(node.range)
    w = bits(fmt)
    aw = max(1, ceil_log2(length(table)))

    c.elems[idx_id]
    |> Tuple.to_list()
    |> Enum.with_index()
    |> map_c(c, fn
      {{:lit, v}, _e}, c ->
        {c, Enum.at(table, v)}

      {ref, e}, c ->
        name = elem_name(node, e)
        {c, idx} = raw(c, ref, stage)

        {c, cases} =
          table
          |> Enum.with_index()
          |> map_c(c, fn {t, i}, c ->
            {c, x, _} = operand(c, t, stage)
            {c, "      #{aw}'d#{i}: #{name}_m = #{w}'(#{x});\n"}
          end)

        c =
          c
          |> new_sig("#{name}_m", fmt, stage, false)
          |> comb([
            "  always_comb begin\n",
            "    case (#{aw}'(#{idx}))\n",
            cases,
            "      default: #{name}_m = '0;\n",
            "    endcase\n",
            "  end\n"
          ])

        delayed_result(c, name, "#{name}_m", fmt, stage, c.sched[node.id].cost)
    end)
  end

  # Number of j in j0..j1 with x >= 2^j: for x >= 0 the position of the
  # leading one of x[j1:j0] (bits above j1 folded into bit j1) plus one, 0
  # for negative x. A tree over halves: valid = |half, index = which half.
  defp priority_encoder(c, name, ref, range, j0, j1, stage) do
    {c, x} = raw(c, ref, stage)
    {:sig, sname} = ref
    sig = c.sigs[sname]
    w = if sig.signed, do: sig.bits - 1, else: sig.bits
    k = j1 - j0 + 1
    {lo, _} = IntSet.bounds(range)

    bit = fn j -> if j < w, do: "#{x}[#{j}]", else: "1'b0" end

    top =
      if j1 < w - 1,
        do: "(|#{x}[#{w - 1}:#{j1}])",
        else: bit.(j1)

    z = for(i <- 0..(k - 2)//1, do: bit.(j0 + i)) ++ [top]
    leaves = pow2(max(2, k))
    z = z ++ List.duplicate("1'b0", leaves - k)

    {c, {v, i}} = pe_tree(c, "#{name}_pe", Enum.map(z, &{&1, nil}), 0)
    rw = bit_len(k)
    neg = if sig.signed and lo < 0, do: "#{x}[#{sig.bits - 1}] ? #{rw}'d0 : ", else: ""
    {c, "(#{neg}(#{v} ? #{rw}'(#{i}) + #{rw}'d1 : #{rw}'d0))"}
  end

  defp pe_tree(c, _name, [single], _level), do: {c, single}

  defp pe_tree(c, name, nodes, level) do
    {c, next} =
      nodes
      |> Enum.chunk_every(2)
      |> Enum.with_index()
      |> map_c(c, fn {[{vl, il}, {vh, ih}], j}, c ->
        v = "#{name}_v#{level}_#{j}"
        i = "#{name}_i#{level}_#{j}"

        idx =
          if level == 0,
            do: vh,
            else: "#{vh} ? {1'b1, #{ih}} : {1'b0, #{il}}"

        c =
          c
          |> raw_decl("  logic #{v};\n")
          |> raw_decl("  logic [#{level}:0] #{i};\n")
          |> assign(v, "#{vh} | #{vl}")
          |> assign(i, idx)

        {c, {v, i}}
      end)

    pe_tree(c, name, next, level + 1)
  end

  defp delayed_result(c, name, sig, fmt, stage, cost) do
    k =
      case cost do
        {:reg, k, _} -> k
        _ -> 0
      end

    {c, x} = at(c, sig, stage + k)
    c = c |> new_sig(name, fmt, stage + k, k > 0) |> assign(name, x)
    {c, {:sig, name}}
  end

  # A data-dependent take from a delay line (`Fir`): the line's input is
  # written to a memory once per sample, the take reads
  # `base[n - (a + slope * idx)]` from it (asynchronously for small lines,
  # through a read register for block RAM).
  defp memory_take(node, c, plan) do
    [_table_id, idx_id] = node.inputs
    stage = exec_stage(c, node.id)
    fmt = IntSet.bit_width(node.range)
    w = bits(fmt)
    depth = pow2(plan.depth)
    aw = max(1, ceil_log2(depth))
    dw = aw + 1

    c.elems[idx_id]
    |> Tuple.to_list()
    |> Enum.with_index()
    |> map_c(c, fn {ref, e}, c ->
      name = elem_name(node, e)
      mem = "#{name}_mem"
      {c, x, xw} = operand(c, plan.x0, stage)
      {c, idx} = raw(c, ref, stage)
      op = if plan.slope > 0, do: "+", else: "-"

      c =
        c
        |> new_sig("#{name}_wp", {:u, aw}, :mem, true)
        |> new_sig("#{name}_fill", {:u, dw}, :mem, true)
        |> new_sig("#{name}_x", {:s, xw}, stage, false)
        |> assign("#{name}_x", x)
        |> new_sig("#{name}_dl", {:u, dw}, stage, false)
        |> assign("#{name}_dl", "#{dw}'(#{dw}'d#{plan.a} #{op} #{dw}'(#{idx}))")
        |> new_sig("#{name}_ok", {:u, 1}, stage, false)
        |> assign("#{name}_ok", "#{name}_fill >= #{name}_dl")
        |> new_sig("#{name}_z", {:u, 1}, stage, false)
        |> assign("#{name}_z", "#{name}_dl == '0")
        |> raw_decl("  logic signed [#{xw - 1}:0] #{mem} [#{depth}];\n")
        |> comb([
          "  // #{name}: delay line memory, read #{plan.a} #{op} index samples back\n",
          "  always_ff @(posedge clk) begin\n",
          "    if (!rst_n) begin\n",
          "      #{name}_wp <= '0;\n",
          "      #{name}_fill <= '0;\n",
          "    end else if (ce && #{valid(stage)}) begin\n",
          "      #{mem}[#{name}_wp] <= #{name}_x;\n",
          "      #{name}_wp <= #{name}_wp + #{aw}'d1;\n",
          "      if (#{name}_fill != #{dw}'d#{depth}) #{name}_fill <= #{name}_fill + #{dw}'d1;\n",
          "    end\n",
          "  end\n"
        ])

      addr = "#{aw}'(#{name}_wp - #{aw}'(#{name}_dl))"

      case c.sched[node.id].cost do
        {:reg, k, _} ->
          # registered read, then the multiplexer one stage later
          q = "#{name}_q"

          {c, [z, ok, xd]} =
            map_c(["#{name}_z", "#{name}_ok", "#{name}_x"], c, fn s, c -> at(c, s, stage + 1) end)

          c =
            c
            |> new_sig(q, {:s, xw}, stage + 1, true)
            |> ff(q, "#{mem}[#{addr}]")
            |> new_sig("#{name}_r", fmt, stage + 1, false)
            |> assign("#{name}_r", "#{w}'(#{z} ? #{xd} : (#{ok} ? #{q} : '0))")

          delayed_result(c, name, "#{name}_r", fmt, stage + 1, {:reg, k - 1, :bram})

        _ ->
          c =
            c
            |> new_sig(name, fmt, stage, false)
            |> assign(
              name,
              "#{w}'(#{name}_z ? #{name}_x : (#{name}_ok ? #{mem}[#{addr}] : '0))"
            )

          {c, {:sig, name}}
      end
    end)
  end

  # `x0` delayed by `d` samples (constant) in stage `stage`, from a memory
  # written once per sample. The value for the next sample is read ahead,
  # so a block RAM read costs no latency; samples before the first `d`
  # read zero (the delay line starts at zero).
  defp delay_memory(c, name, x0, stage, d) do
    {c, x, xw} = operand(c, x0, stage)
    q = "#{name}_q"

    if d == 1 do
      c =
        c
        |> new_sig(q, {:s, xw}, stage, true)
        |> comb([
          "  always_ff @(posedge clk) begin\n",
          "    if (!rst_n) #{q} <= '0;\n",
          "    else if (ce && #{valid(stage)}) #{q} <= #{x};\n",
          "  end\n"
        ])

      {c, {:sig, q}}
    else
      depth = pow2(d)
      aw = max(1, ceil_log2(depth))
      dw = bit_len(d)
      mem = "#{name}_mem"

      c =
        c
        |> new_sig("#{name}_wp", {:u, aw}, :mem, true)
        |> new_sig("#{name}_fill", {:u, dw}, :mem, true)
        |> new_sig(q, {:s, xw}, :mem, true)
        |> raw_decl("  logic signed [#{xw - 1}:0] #{mem} [#{depth}];\n")
        |> comb([
          "  // #{name}: #{d} samples delay in a memory, read one sample ahead\n",
          "  always_ff @(posedge clk) begin\n",
          "    if (!rst_n) begin\n",
          "      #{name}_wp <= '0;\n",
          "      #{name}_fill <= '0;\n",
          "      #{q} <= '0;\n",
          "    end else if (ce && #{valid(stage)}) begin\n",
          "      #{mem}[#{name}_wp] <= #{x};\n",
          "      #{name}_wp <= #{name}_wp + #{aw}'d1;\n",
          "      #{q} <= #{mem}[#{aw}'(#{name}_wp + #{aw}'d#{band(1 - d, depth - 1)})];\n",
          "      if (#{name}_fill != #{dw}'d#{d}) #{name}_fill <= #{name}_fill + #{dw}'d1;\n",
          "    end\n",
          "  end\n"
        ])
        |> new_sig(name, {:s, xw}, stage, false)
        |> assign(name, "(#{name}_fill == #{dw}'d#{d}) ? #{q} : '0")

      {c, {:sig, name}}
    end
  end

  defp delay_out(c, f, n, plan, latency) do
    {c, ref} = delay_memory(c, "#{n}_dly", plan.x0, latency, plan.d)
    {c, {f, ref}}
  end

  defp comb(c, text), do: %{c | combs: [text | c.combs]}
  defp raw_decl(c, text), do: %{c | raw_decls: [text | c.raw_decls]}

  defp input_elems(c, node, k), do: c.elems[Enum.at(node.inputs, k)] |> Tuple.to_list()

  # -- state -------------------------------------------------------------------------------

  defp state_read(c, node, state) do
    fmt = IntSet.bit_width(node.range)
    s = c.state_stages[state.index]

    map_c(0..(size(node.shape) - 1), c, fn e, c ->
      name = elem_name(node, e)
      c = define(c, name, {:state, state.index, e, Enum.at(state.init, e)})

      cond do
        c.state_mem != :registers ->
          # a field of the group's memory word, read ahead (`state_logic`)
          # (a merged folded memory at its first group's stage; pipeline
          # registers carry the value to stage `s`)
          {g, offset, s0} = state_field(c, node.id, e)
          w = bits(fmt)
          c = c |> new_sig(name, fmt, s0, false) |> assign(name, "st#{g}_q[#{offset} +: #{w}]")
          {c, {:sig, name}}

        c.channels == 1 ->
          {new_sig(c, name, fmt, s, true), {:sig, name}}

        true ->
          c = c |> new_sig(name, fmt, s, false) |> assign(name, "#{name}_mem[#{ch(s)}]")
          {c, {:sig, name}}
      end
    end)
  end

  # Memory, bit offset and read stage of element `e` of state parameter `id`.
  defp state_field(c, id, e) do
    c
    |> state_words()
    |> Enum.find_value(fn {u, gis, fields} ->
      Enum.find_value(fields, fn {fid, fe, offset, _fmt} ->
        if fid == id and fe == e,
          do: {u, offset, gis |> Enum.map(&Enum.at(c.group_stages, &1)) |> Enum.min()}
      end)
    end)
  end

  # State memories: the groups read in the same stage share one memory
  # word (written at the latest of their write stages, which keeps every
  # loop within its bound). `[{unit, group_indices, [{param_id, e, offset, fmt}]}]`,
  # leaves and elements in order.
  defp state_words(c) do
    c.groups
    |> Enum.zip(c.group_stages)
    |> Enum.with_index()
    |> Enum.reject(fn {{g, _s}, _gi} -> g.params == [] end)
    |> Enum.group_by(fn {{_g, s}, _gi} -> s end)
    |> Enum.sort_by(fn {_s, [{_, gi} | _]} -> gi end)
    |> Enum.with_index()
    |> Enum.map(fn {{_s, members}, u} ->
      {fields, _} =
        members
        |> Enum.flat_map(fn {{g, _s}, _gi} -> g.params end)
        |> Enum.flat_map(fn id ->
          node = c.graph.nodes[id]
          fmt = IntSet.bit_width(node.range)
          for e <- 0..(size(node.shape) - 1), do: {id, e, fmt}
        end)
        |> Enum.map_reduce(0, fn {id, e, fmt}, offset ->
          {{id, e, offset, fmt}, offset + bits(fmt)}
        end)

      {u, Enum.map(members, &elem(&1, 1)), fields}
    end)
    |> merge_folded(c)
  end

  # With `state_fold: k` consecutive state memories (by stage) merge into
  # one while a row stays within `state_row_bits` and the merged memory's
  # read-to-write span (estimated from the groups' loop latencies) fits
  # `channels * k` cycles. Later groups' fields then wait in pipeline
  # registers from the first group's stage, and earlier groups' next state
  # until the last write stage: registers for fewer, fuller memories.
  defp merge_folded(units, %{state_fold: 1}), do: units

  defp merge_folded(units, c) do
    k = c.state_fold
    limit = c.layout.state_row_bits
    stage = fn gis -> gis |> Enum.map(&Enum.at(c.group_stages, &1)) |> Enum.min() end

    last = fn gis ->
      gis
      |> Enum.map(&(Enum.at(c.group_stages, &1) + Enum.at(c.groups, &1).loop_latency - 1))
      |> Enum.max()
    end

    fits? = fn gis, fields ->
      span = last.(gis) - stage.(gis) + c.ram_latency + k
      div(word_bits(fields) + k - 1, k) <= limit and span <= c.channels * k
    end

    units
    |> Enum.sort_by(fn {_u, gis, _} -> stage.(gis) end)
    |> Enum.reduce([], fn
      {_u, gis, fields}, [{pgis, pfields} | rest] = acc ->
        if fits?.(pgis ++ gis, pfields ++ fields),
          do: [{pgis ++ gis, pfields ++ fields} | rest],
          else: [{gis, fields} | acc]

      {_u, gis, fields}, [] ->
        [{gis, fields}]
    end)
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn {{gis, fields}, u} ->
      {fields, _} =
        Enum.map_reduce(fields, 0, fn {id, e, _, fmt}, offset ->
          {{id, e, offset, fmt}, offset + bits(fmt)}
        end)

      {u, gis, fields}
    end)
  end

  # Per state group: delays every next-state element to the latest one's
  # stage (the group's write stage). Returns the groups as
  # `%{index:, leaves:, state_stage:, write_stage:, writes: [{name, fmt, init, expr}]}`.
  defp state_writes(c, scan) do
    graph = c.graph
    next_ids = flatten(scan.next_state)

    leaves =
      for {state, next_id} <- Enum.zip(c.layout.states, next_ids),
          param = Enum.find(scan.state_params, &(graph.nodes[&1].attrs == state.index)),
          param != nil,
          into: %{},
          do: {param, {state, graph.nodes[param], next_id}}

    for {_param, {_state, pnode, next_id}} <- leaves,
        not IntSet.subtype?(graph.nodes[next_id].range, pnode.range) do
      raise UnsupportedError,
            "scan: next state (node #{next_id}) can leave the state's range " <>
              "(#{inspect(IntSet.bounds(graph.nodes[next_id].range))} vs #{inspect(IntSet.bounds(pnode.range))})"
    end

    own_w =
      scan.groups
      |> Enum.zip(c.group_stages)
      |> Enum.map(fn {g, s} ->
        for id <- g.params,
            {_, _, next_id} = Map.fetch!(leaves, id),
            ref <- Tuple.to_list(c.elems[next_id]),
            not static?(c, ref),
            reduce: s do
          acc -> max(acc, c.sigs[elem(ref, 1)].stage)
        end
      end)

    # groups sharing a state memory write together
    unit_w =
      if c.state_mem == :registers,
        do: own_w,
        else:
          Enum.reduce(state_words(c), own_w, fn {_u, gis, _}, ws ->
            w = gis |> Enum.map(&Enum.at(ws, &1)) |> Enum.max()
            Enum.reduce(gis, ws, &List.replace_at(&2, &1, w))
          end)

    scan.groups
    |> Enum.zip(c.group_stages)
    |> Enum.with_index()
    |> Enum.map_reduce(c, fn {{g, s}, gi}, c ->
      members = Enum.map(g.params, &Map.fetch!(leaves, &1))
      w = Enum.at(unit_w, gi)

      {writes, c} =
        Enum.flat_map_reduce(members, c, fn {state, pnode, next_id}, c ->
          fmt = IntSet.bit_width(pnode.range)

          c.elems[next_id]
          |> Tuple.to_list()
          |> Enum.with_index()
          |> Enum.map_reduce(c, fn {ref, e}, c ->
            {c, x, _} = operand(c, ref, w)
            init = Enum.at(state.init, e)
            {{elem_name(pnode, e), fmt, init, "#{bits(fmt)}'(#{x})"}, c}
          end)
        end)

      {%{index: gi, leaves: g.leaves, state_stage: s, write_stage: w, writes: writes}, c}
    end)
    |> swap()
  end

  # -- outputs --------------------------------------------------------------------------------

  # Output data per lane (one lane at fixed rate) and the count of valid
  # lanes (nil at fixed rate), all taken in the output stage.
  defp outputs(c, _scan) do
    l = c.layout
    lanes = l.lanes || 1

    lane_refs =
      for j <- 0..(lanes - 1) do
        for f <- l.outputs, e <- 0..(size(f.shape) - 1)//1 do
          {f, elem(c.elems[f.index], j * size(f.shape) + e)}
        end
      end

    count_ref = if l.count_id, do: elem(c.elems[l.count_id], 0)

    # long delays of the input are read from a memory (`Fir`)
    timing_ref = fn
      {:sig, n} = ref ->
        case c.fir do
          %{{:out, ^n} => plan} -> plan.x0
          _ -> ref
        end

      ref ->
        ref
    end

    latency =
      [count_ref | Enum.flat_map(lane_refs, fn refs -> Enum.map(refs, &elem(&1, 1)) end)]
      |> Enum.reject(&(&1 == nil))
      |> Enum.map(timing_ref)
      |> Enum.reject(&static?(c, &1))
      |> Enum.map(fn {:sig, n} ->
        s = c.sigs[n]
        if s.reg, do: s.stage, else: s.stage + 1
      end)
      |> Enum.max(fn -> 1 end)
      |> max(1)

    {c, lane_refs} =
      map_c(lane_refs, c, fn refs, c ->
        map_c(refs, c, fn
          {f, {:sig, n} = ref}, c ->
            case c.fir do
              %{{:out, ^n} => plan} ->
                if Map.has_key?(c.sigs, "#{n}_dly"),
                  do: {c, {f, {:sig, "#{n}_dly"}}},
                  else: delay_out(c, f, n, plan, latency)

              _ ->
                {c, {f, ref}}
            end

          other, c ->
            {c, other}
        end)
      end)

    {c, exprs} =
      map_c(lane_refs, c, fn refs, c ->
        {c, parts} =
          map_c(refs, c, fn {f, ref}, c ->
            case ref do
              {:lit, v} ->
                {c, lit(v, f.bits)}

              _ ->
                {c, x, _} = operand(c, ref, latency)
                {c, "#{f.bits}'(#{x})"}
            end
          end)

        used = Enum.reduce(l.outputs, 0, fn f, acc -> acc + f.bits * size(f.shape) end)
        pad = l.out_width - used
        parts = if pad > 0, do: ["#{pad}'d0" | Enum.reverse(parts)], else: Enum.reverse(parts)
        {c, "{" <> Enum.join(parts, ", ") <> "}"}
      end)

    {c, count} =
      case count_ref do
        nil ->
          {c, nil}

        ref ->
          {c, x} = raw(c, ref, latency)
          {c, x}
      end

    {c, latency, {exprs, count}}
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

      :remainder ->
        # Nx and SystemVerilog both truncate (the sign follows the dividend);
        # a non-negative dividend and a power of two divisor need only a mask
        [x, y] = refs

        if power_of_two?(y) and IntSet.bounds(ref_range(c, x)) |> elem(0) >= 0 do
          {:lit, v} = y
          {c, [a, m], _} = operands(c, [x, {:lit, v - 1}], stage, rsw)
          {c, "#{w}'(#{a} & #{m})"}
        else
          {c, [a, b], _} = operands(c, refs, stage, rsw)
          {c, "#{w}'(#{a} % #{b})"}
        end

      :quotient ->
        # truncating division in both; a power of two divisor of a
        # non-negative dividend is a shift
        [x, y] = refs

        if power_of_two?(y) and IntSet.bounds(ref_range(c, x)) |> elem(0) >= 0 do
          {:lit, v} = y
          {c, [a], _} = operands(c, [x], stage, rsw)
          {c, "#{w}'(#{a} >>> #{ceil_log2(v)})"}
        else
          {c, [a, b], _} = operands(c, refs, stage, rsw)
          {c, "#{w}'(#{a} / #{b})"}
        end

      :negate ->
        {c, [a], _} = operands(c, refs, stage, rsw)
        {c, "#{w}'(-(#{a}))"}

      :abs ->
        {c, [a], e} = operands(c, refs, stage, rsw)
        {c, "#{w}'((#{a} < #{lit(0, e)}) ? -(#{a}) : #{a})"}

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

  # A DSP multiply of k cycles: input registers (k >= 2), the product, then
  # output registers. Products wider than one DSP multiplier are cut into
  # pieces (`Timing.dsp_split/3`), one slice each, whose shifted partial
  # products a registered adder tree sums in the last `levels` cycles.
  # Members of a shared unit (`share_plan/5`) take the unit's result.
  defp product(c, name, [a, b], stage, k, fmt) do
    case c.share do
      %{^name => u} -> shared_product(c, name, u, [a, b], stage, k, fmt)
      _ -> dsp_product(c, name, [a, b], stage, k, fmt)
    end
  end

  defp dsp_product(c, name, [a, b], stage, k, fmt) do
    wa = operand_width(c, a)
    wb = operand_width(c, b)
    split = Timing.dsp_split(c.timing, wa, wb)
    c = %{c | dsp: c.dsp + split.count}

    if split.count == 1 do
      {c, {pa, wa}} = mul_input(c, "#{name}_a", a, stage, k)
      {c, {pb, wb}} = mul_input(c, "#{name}_b", b, stage, k)
      mul_stage = if k >= 2, do: stage + 1, else: stage
      p = "#{name}_p"
      c = c |> new_sig(p, {:s, wa + wb}, mul_stage, false) |> assign(p, "#{pa} * #{pb}")
      {c, pd} = at(c, p, stage + k)
      c = c |> new_sig(name, fmt, stage + k, true) |> assign(name, "#{bits(fmt)}'(#{pd})")
      {c, {:sig, name}}
    else
      if k < split.levels + 1,
        do:
          raise(
            UnsupportedError,
            "scan: a #{wa} x #{wb} bit product needs #{split.levels + 1} cycles, the schedule gives #{k}"
          )

      dl = k - split.levels
      {c, ea} = split_input(c, "#{name}_a", a, stage, dl, split.a)
      {c, eb} = split_input(c, "#{name}_b", b, stage, dl, split.b)
      mul_stage = if dl >= 2, do: stage + 1, else: stage

      {c, terms} =
        for({xa, sa, ra} <- ea, {xb, sb, rb} <- eb, do: {xa, sa, ra, xb, sb, rb})
        |> Enum.with_index()
        |> map_c(c, fn {{xa, sa, ra, xb, sb, rb}, i}, c ->
          range = IntSet.multiply(ra, rb)
          pw = signed_bits(IntSet.bit_width(range))
          pp = "#{name}_pp#{i}"
          # the assignment context extends both signed operands to pw bits
          c = c |> new_sig(pp, {:s, pw}, mul_stage, false) |> assign(pp, "#{xa} * #{xb}")
          {c, ppd} = at(c, pp, stage + dl)
          shifted = IntSet.multiply(range, IntSet.singleton(1 <<< (sa + sb)))
          sw = signed_bits(IntSet.bit_width(shifted))
          sh = "#{name}_sh#{i}"

          c =
            c
            |> new_sig(sh, {:s, sw}, stage + dl, false)
            |> assign(sh, "#{sw}'(#{sw}'(#{ppd}) <<< #{sa + sb})")

          {c, {{:sig, sh}, shifted}}
        end)

      adder_tree(c, name, terms, stage + dl, split.levels, fmt)
    end
  end

  defp operand_width(_c, {:lit, v}), do: lit_bits(v)

  defp operand_width(c, {:sig, name}) do
    s = c.sigs[name]
    if s.signed, do: s.bits, else: s.bits + 1
  end

  # The pieces of one operand: `[{expr, shift, range}]`, from a named
  # (registered for k >= 2) copy of the operand.
  defp split_input(c, _reg, {:lit, v}, _stage, _k, pieces) do
    {c,
     Enum.map(pieces, fn {lsb, n, signed?} ->
       x = if signed?, do: v >>> lsb, else: band(v >>> lsb, (1 <<< n) - 1)
       {lit(x, lit_bits(x)), lsb, IntSet.singleton(x)}
     end)}
  end

  defp split_input(c, reg, ref, stage, k, pieces) do
    {c, x, sw} = operand(c, ref, stage)

    {c, x} =
      cond do
        k >= 2 and not static?(c, ref) ->
          {c |> new_sig(reg, {:s, sw}, stage + 1, true) |> ff(reg, x), reg}

        true ->
          s = if static?(c, ref), do: :static, else: stage
          {c |> new_sig(reg, {:s, sw}, s, false) |> assign(reg, x), reg}
      end

    {c,
     Enum.map(pieces, fn {lsb, n, signed?} ->
       hi = min(lsb + n, sw) - 1

       if signed?,
         do: {"$signed(#{x}[#{sw - 1}:#{lsb}])", lsb, IntSet.of_type({:s, sw - lsb})},
         else:
           {"$signed({1'b0, #{x}[#{hi}:#{lsb}]})", lsb,
            IntSet.range(0, (1 <<< (hi - lsb + 1)) - 1)}
     end)}
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
    levels =
      pairs
      |> Enum.reject(fn {a, b} -> static?(c, a) and static?(c, b) end)
      |> Enum.reject(fn {a, b} -> power_of_two?(a) or power_of_two?(b) end)
      |> Enum.map(fn {a, b} ->
        Timing.dsp_split(c.timing, operand_width(c, a), operand_width(c, b)).levels
      end)
      |> Enum.max(fn -> 0 end)

    dl = min(c.timing.dsp_latency + levels, k)

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
  # Equal taps: `acc[n] = acc[n - 1] + h * (x[n] - x[n - L])`, exact, with
  # x[n - L] from a delay memory.
  defp fir_chain(c, name, %{fold: :sum} = g, stage) do
    h = hd(g.taps)
    len = length(g.taps)
    x_range = ref_range(c, g.x0)
    {c, xd} = delay_memory(c, "#{name}_dl", g.x0, stage, len)
    {c, [x, y], _} = operands(c, [g.x0, xd], stage, 1)
    diff_range = IntSet.subtract(x_range, x_range)
    dw = signed_bits(IntSet.bit_width(diff_range))
    diff = "#{name}_df"

    # len values of x_range (an interval) times h
    range = IntSet.multiply(x_range, IntSet.singleton(h * len))

    w = signed_bits(IntSet.bit_width(range))
    acc = "#{name}_acc"

    c =
      %{c | dsp: c.dsp + 1}
      |> new_sig(diff, {:s, dw}, stage + 1, true)
      |> ff(diff, "#{dw}'(#{dw}'(#{x}) - #{dw}'(#{y}))")
      |> new_sig(acc, {:s, w}, stage + 2, true)
      |> sample_ff(stage + 1, acc, "#{w}'(#{acc}) + #{w}'(#{diff} * #{lit(h, lit_bits(h))})")

    {c, {{:sig, acc}, range}}
  end

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
              c = %{c | dsp: c.dsp + 1}
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
    n = scan.channels
    cw = max(1, bit_len(n - 1))
    busy = scan.state_mem != :registers and l.state_init == :clear and d.groups != []
    chan? = l.chan_params != []

    params =
      Enum.map(l.params, fn p ->
        "  input  logic [#{p.bits * size(p.shape) - 1}:0] #{p.port},\n"
      end) ++ if(l.params == [], do: [], else: ["  input  logic p_load,\n"])

    pc_ports =
      if chan? do
        [
          if(l.pc_clock == :separate, do: "  input  logic pc_clk,\n", else: []),
          "  input  logic [#{cw - 1}:0] pc_addr,\n",
          "  input  logic [#{l.pc_width - 1}:0] pc_data,\n",
          "  input  logic pc_we,\n",
          "  input  logic pc_swap,\n",
          "  output logic pc_pending,\n"
        ]
      else
        []
      end

    in_side =
      [
        if(l.tid, do: "  input  logic [#{cw - 1}:0] s_axis_tid,\n", else: []),
        if(l.tuser > 0, do: "  input  logic [#{l.tuser - 1}:0] s_axis_tuser,\n", else: []),
        if(l.frame, do: "  input  logic s_axis_tlast,\n", else: [])
      ]

    out_side =
      [
        if(n > 1, do: "  output logic [#{cw - 1}:0] m_axis_tid,\n", else: []),
        if(l.tuser > 0, do: "  output logic [#{l.tuser - 1}:0] m_axis_tuser,\n", else: []),
        if(l.frame, do: "  output logic m_axis_tlast,\n", else: [])
      ]

    state_regs =
      for g <- d.groups, {name, _, _, _} <- g.writes, into: MapSet.new(), do: name

    decls =
      c.decls
      |> Enum.reverse()
      |> Enum.reject(
        &(n == 1 and scan.state_mem == :registers and MapSet.member?(state_regs, &1))
      )
      |> Enum.map(fn name ->
        sig = c.sigs[name]
        "  #{decl_type({if(sig.signed, do: :s, else: :u), sig.bits})} #{name};\n"
      end)

    shift =
      if depth == 1,
        do: "vld_0",
        else: "{vld[#{depth - 1}:1], vld_0}"

    holds =
      [if(l.params == [], do: nil, else: "!p_pending"), if(busy, do: "!st_clr")]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(&" && #{&1}")

    control = [
      "  // control: one clock enable for the whole pipeline, from registers\n",
      "  // only (the output buffer's free space), so no ready path is combinational\n",
      "  logic ce;\n",
      "  logic issue_ok;\n",
      "  logic gap_ok;\n",
      "  logic vld_0;\n",
      "  logic [#{depth}:1] vld;  // vld[k]: stage k holds a sample\n",
      "  logic ob_room;\n",
      if(l.params == [], do: [], else: "  logic p_pending;\n"),
      if(busy, do: "  logic st_clr;\n", else: []),
      "  assign ce = ob_room;\n",
      "  assign issue_ok = gap_ok#{holds};\n",
      "  assign s_axis_tready = ce && issue_ok;\n",
      "  assign vld_0 = s_axis_tvalid && issue_ok;\n",
      "  always_ff @(posedge clk) begin\n",
      "    if (!rst_n) vld <= '0;\n",
      "    else if (ce) vld <= #{shift};\n",
      "  end\n"
    ]

    gap = if n > 1, do: scan.state_fold, else: scan.ii

    throttle =
      if gap == 1 do
        "  assign gap_ok = 1'b1;\n"
      else
        gw = max(1, bit_len(gap - 1))
        last = "#{gw}'d#{gap - 1}"

        [
          "  // one sample every #{gap} enabled cycles\n",
          "  logic [#{gw - 1}:0] gap;\n",
          "  assign gap_ok = (gap == #{last});\n",
          "  always_ff @(posedge clk) begin\n",
          "    if (!rst_n) gap <= #{last};\n",
          "    else if (ce) gap <= vld_0 ? #{gw}'d0 : (gap_ok ? gap : gap + #{gw}'d1);\n",
          "  end\n"
        ]
      end

    channel =
      if n > 1 do
        regs = Enum.map(0..depth, &"  logic [#{cw - 1}:0] #{ch(&1)};\n")
        pipe = Enum.map(1..depth//1, &"      #{ch(&1)} <= #{ch(&1 - 1)};\n")

        first =
          if l.tid do
            [
              "  // channel of the sample in each stage, from s_axis_tid\n",
              regs,
              "  assign #{ch(0)} = s_axis_tid;\n"
            ]
          else
            [
              "  // channel of the sample in each stage, round robin in arrival order\n",
              regs,
              "  always_ff @(posedge clk) begin\n",
              "    if (!rst_n) #{ch(0)} <= '0;\n",
              "    else if (ce && vld_0) #{ch(0)} <= (#{ch(0)} == #{cw}'d#{n - 1}) ? '0 : #{ch(0)} + #{cw}'d1;\n",
              "  end\n"
            ]
          end

        [
          first,
          "  always_ff @(posedge clk) begin\n",
          "    if (ce) begin\n",
          pipe,
          "    end\n",
          "  end\n"
        ]
      else
        []
      end

    user =
      if l.tuser > 0 do
        regs = Enum.map(1..d.latency, &"  logic [#{l.tuser - 1}:0] user_#{&1};\n")

        pipe =
          Enum.map(1..d.latency, fn k ->
            "      user_#{k} <= #{if k == 1, do: "s_axis_tuser", else: "user_#{k - 1}"};\n"
          end)

        [
          "  // tuser travels with the sample\n",
          regs,
          "  always_ff @(posedge clk) begin\n",
          "    if (ce) begin\n",
          pipe,
          "    end\n",
          "  end\n"
        ]
      else
        []
      end

    frame =
      if l.frame do
        regs = Enum.map(1..d.latency, &"  logic last_#{&1};\n")

        pipe =
          Enum.map(1..d.latency, fn k ->
            "      last_#{k} <= #{if k == 1, do: "s_axis_tlast", else: "last_#{k - 1}"};\n"
          end)

        [
          "  // frame sideband: first and last of each frame from tlast\n",
          "  logic fr_first;\n",
          regs,
          "  always_ff @(posedge clk) begin\n",
          "    if (!rst_n) fr_first <= 1'b1;\n",
          "    else if (ce && vld_0) fr_first <= s_axis_tlast;\n",
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

    {state_decls, state_logic} = state_logic(c, d.groups, n, busy)
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

    # tlast on the last item a sample pushes
    lanes = length(elem(d.out_expr, 0))

    last_of = fn j ->
      cond do
        lanes == 1 -> "last_#{d.latency}"
        true -> "(last_#{d.latency} && ob_n == #{bit_len(lanes)}'d#{j + 1})"
      end
    end

    side =
      [
        if(l.frame, do: {last_of, "m_axis_tlast", 1}),
        if(l.tuser > 0, do: {"user_#{d.latency}", "m_axis_tuser", l.tuser}),
        if(n > 1, do: {ch(d.latency), "m_axis_tid", cw})
      ]
      |> Enum.reject(&is_nil/1)

    IO.iodata_to_binary([
      "// Generated by ExHdl from a stream kernel. Do not edit.\n",
      "// #{d.name}: latency #{d.latency + 1}, ii #{scan.ii}, channels #{n}",
      if(scan.state_mem == :registers, do: "", else: ", state in #{scan.state_mem} RAM"),
      if(scan.state_fold > 1, do: " folded over #{scan.state_fold} rows", else: ""),
      "\n",
      "// s_axis_tdata: #{describe_fields(l.inputs)}\n",
      "// m_axis_tdata: #{describe_fields(l.outputs)}\n",
      if(chan?, do: "// pc_data: #{describe_fields(l.chan_params)}\n", else: []),
      "/* verilator lint_off UNUSEDSIGNAL */\n",
      "module #{d.name} (\n",
      "  input  logic clk,\n",
      "  input  logic rst_n,\n",
      params,
      pc_ports,
      memory_port_decls(c),
      if(busy, do: "  output logic busy,\n", else: []),
      "  input  logic [#{l.in_width - 1}:0] s_axis_tdata,\n",
      in_side,
      "  input  logic s_axis_tvalid,\n",
      "  output logic s_axis_tready,\n",
      "  output logic [#{l.out_width - 1}:0] m_axis_tdata,\n",
      out_side,
      "  output logic m_axis_tvalid,\n",
      "  input  logic m_axis_tready\n",
      ");\n\n",
      control,
      throttle,
      channel,
      user,
      frame,
      param_logic(l.params),
      channel_param_logic(c, cw),
      "\n",
      Enum.reverse(c.blocks),
      state_decls,
      "  // datapath\n",
      decls,
      Enum.reverse(c.raw_decls),
      Enum.reverse(c.assigns),
      ffs,
      Enum.reverse(c.combs),
      "\n",
      memory_logic(c),
      state_logic,
      sample_logic,
      "\n",
      out_buffer(d.out_expr, l.out_width, valid(d.latency), side),
      "endmodule\n",
      "/* verilator lint_on UNUSEDSIGNAL */\n"
    ])
  end

  # Output buffer: the pipeline pushes its result (up to `lanes` items, the
  # valid ones first) with the clock enable, the stream pops one item per
  # beat; the pipeline runs while the buffer has room for a full push.
  # `side` are sideband fields `{expr, port, bits}` stored with every item.
  defp out_buffer({lanes, count}, width, valid, side) do
    n = length(lanes)
    depth = pow2(max(2, 2 * n))
    aw = ceil_log2(depth)
    cw = bit_len(n)
    word = width + (side |> Enum.map(&elem(&1, 2)) |> Enum.sum())
    side_exprs = side |> Enum.map(&elem(&1, 0)) |> Enum.reverse()

    pack = fn x, j ->
      exprs = Enum.map(side_exprs, fn e -> if is_function(e), do: e.(j), else: e end)
      "{" <> Enum.join(exprs ++ [x], ", ") <> "}"
    end

    ports = (side |> Enum.map(&elem(&1, 1)) |> Enum.reverse()) ++ ["m_axis_tdata"]

    writes =
      lanes
      |> Enum.with_index()
      |> Enum.map(fn {x, j} ->
        guard = if count, do: "if (ob_n > #{cw}'d#{j}) ", else: ""

        "        #{guard}ob_mem[#{aw}'(ob_wp + #{aw}'d#{j})] <= #{if side == [], do: x, else: pack.(x, j)};\n"
      end)

    [
      "  // output buffer#{if count, do: " (#{n} lanes, count of valid ones)", else: ""}\n",
      "  logic [#{word - 1}:0] ob_mem [#{depth}];\n",
      "  logic [#{aw - 1}:0] ob_wp, ob_rp;\n",
      "  logic [#{aw}:0] ob_count;\n",
      "  logic [#{cw - 1}:0] ob_n;\n",
      "  logic ob_push, ob_pop;\n",
      "  assign ob_room = ob_count <= #{aw + 1}'d#{depth - n};\n",
      "  assign ob_push = ce && #{valid};\n",
      "  assign ob_pop = m_axis_tvalid && m_axis_tready;\n",
      "  assign ob_n = #{if count, do: "#{cw}'(#{count})", else: "#{cw}'d1"};\n",
      "  always_ff @(posedge clk) begin\n",
      "    if (!rst_n) begin\n",
      "      ob_wp <= '0;\n",
      "      ob_rp <= '0;\n",
      "      ob_count <= '0;\n",
      "    end else begin\n",
      "      if (ob_push) begin\n",
      writes,
      "        ob_wp <= ob_wp + #{aw}'(ob_n);\n",
      "      end\n",
      "      if (ob_pop) ob_rp <= ob_rp + #{aw}'d1;\n",
      "      ob_count <= ob_count + (ob_push ? #{aw + 1}'(ob_n) : #{aw + 1}'d0) - #{aw + 1}'(ob_pop);\n",
      "    end\n",
      "  end\n",
      "  assign m_axis_tvalid = ob_count != '0;\n",
      if(side == [],
        do: "  assign m_axis_tdata = ob_mem[ob_rp];\n",
        else: "  assign {#{Enum.join(ports, ", ")}} = ob_mem[ob_rp];\n"
      )
    ]
  end

  defp pow2(n), do: 1 <<< ceil_log2(n)

  # Parameter ports are captured on `p_load` and applied once the samples
  # accepted until then have left the pipeline; no sample is accepted in
  # between. Reset loads the ports directly.
  defp param_logic([]), do: []

  defp param_logic(params) do
    decl = fn p, suffix -> "  logic [#{p.bits * size(p.shape) - 1}:0] #{p.port}#{suffix};\n" end

    [
      "  // parameters: p_load captures the ports, they apply between samples\n",
      Enum.map(params, &decl.(&1, "_q")),
      Enum.map(params, &decl.(&1, "_s")),
      "  always_ff @(posedge clk) begin\n",
      "    if (!rst_n) begin\n",
      Enum.map(params, &"      #{&1.port}_q <= #{&1.port};\n"),
      "      p_pending <= 1'b0;\n",
      "    end else if (p_load) begin\n",
      Enum.map(params, &"      #{&1.port}_s <= #{&1.port};\n"),
      "      p_pending <= 1'b1;\n",
      "    end else if (p_pending && vld == '0) begin\n",
      Enum.map(params, &"      #{&1.port}_q <= #{&1.port}_s;\n"),
      "      p_pending <= 1'b0;\n",
      "    end\n",
      "  end\n"
    ]
  end

  # Per-channel parameters: one memory per leaf with two banks of a word per
  # channel, addressed `{bank, channel}`. The bank of a sample is fixed when
  # it is accepted and travels with it; the read is issued `pc_latency`
  # stages before the leaf's first use.
  defp channel_param_logic(%{layout: %{chan_params: []}}, _cw), do: []

  defp channel_param_logic(c, cw) do
    l = c.layout
    pl = l.pc_latency
    wclk = if l.pc_clock == :separate, do: "pc_clk", else: "clk"
    depth = 1 <<< (cw + 1)

    leaves =
      for {p, k} <- Enum.with_index(l.chan_params),
          id = Enum.find(c.graph.order, &(param_index(c.graph, &1) == p.index)),
          id != nil do
        fmt = IntSet.bit_width(c.graph.nodes[id].range)
        {p, k, bits(fmt), c.pc_stages[p.index]}
      end

    # last stage that issues a read: old-bank samples are gone once the
    # swap marker has passed it
    last_read = leaves |> Enum.map(fn {_, _, _, r} -> r - pl end) |> Enum.max(fn -> 0 end)
    marks = max(1, last_read)

    frame_start =
      if l.tid,
        do: "pc_fresh || (vld_0 && s_axis_tid <= pc_last)",
        else: "#{ch(0)} == #{cw}'d0"

    banks = Enum.map(1..last_read//1, &"  logic bank_#{&1};\n")
    bank_pipe = Enum.map(1..last_read//1, &"      bank_#{&1} <= bank_#{&1 - 1};\n")

    mems =
      Enum.map(leaves, fn {p, k, w, r} ->
        mw = w * size(p.shape)
        a = r - pl
        regs = Enum.map(1..pl, &"  logic [#{mw - 1}:0] pc#{k}_r#{&1};\n")

        reads =
          Enum.map(1..pl, fn j ->
            src = if j == 1, do: "pc#{k}_mem[{bank_#{a}, #{ch(a)}}]", else: "pc#{k}_r#{j - 1}"
            "      pc#{k}_r#{j} <= #{src};\n"
          end)

        data =
          (size(p.shape) - 1)..0//-1
          |> Enum.map_join(", ", &"pc_data[#{p.offset + &1 * p.bits} +: #{w}]")

        [
          "  // #{p.name}: read in stage #{a} for stage #{r}\n",
          "  (* ram_style = \"#{ram_style(l.param_mem)}\" *) logic [#{mw - 1}:0] pc#{k}_mem [#{depth}];\n",
          regs,
          "  logic [#{mw - 1}:0] pc#{k}_q;\n",
          "  assign pc#{k}_q = pc#{k}_r#{pl};\n",
          "  always_ff @(posedge #{wclk}) begin\n",
          "    if (pc_we) pc#{k}_mem[{~pc_active, pc_addr}] <= {#{data}};\n",
          "  end\n",
          "  always_ff @(posedge clk) begin\n",
          "    if (ce) begin\n",
          reads,
          "    end\n",
          "  end\n"
        ]
      end)

    [
      "  // per-channel parameters: two banks, the host writes the inactive one;\n",
      "  // pc_swap makes it active at the next frame boundary\n",
      "  logic pc_active, pc_req, pc_flip, pc_frame_start;\n",
      "  logic bank_0;\n",
      banks,
      "  logic [#{marks}:1] pc_mark;\n",
      if(l.tid, do: "  logic pc_fresh;\n  logic [#{cw - 1}:0] pc_last;\n", else: []),
      "  assign pc_frame_start = #{frame_start};\n",
      "  assign pc_flip = ce && pc_req && pc_frame_start;\n",
      "  assign bank_0 = pc_active ^ pc_flip;\n",
      "  assign pc_pending = pc_req || (pc_mark != '0);\n",
      "  always_ff @(posedge clk) begin\n",
      "    if (!rst_n) begin\n",
      "      pc_active <= 1'b0;\n",
      "      pc_req <= 1'b0;\n",
      "      pc_mark <= '0;\n",
      if(l.tid, do: "      pc_fresh <= 1'b1;\n      pc_last <= '0;\n", else: []),
      "    end else begin\n",
      "      if (pc_flip) pc_active <= ~pc_active;\n",
      "      if (pc_flip) pc_req <= 1'b0;\n",
      "      else if (pc_swap) pc_req <= 1'b1;\n",
      "      if (ce) pc_mark <= #{if marks == 1, do: "pc_flip", else: "{pc_mark[#{marks - 1}:1], pc_flip}"};\n",
      if(l.tid,
        do: [
          "      if (ce && vld_0) begin\n",
          "        pc_fresh <= 1'b0;\n",
          "        pc_last <= s_axis_tid;\n",
          "      end\n"
        ],
        else: []
      ),
      "    end\n",
      "  end\n",
      if(last_read > 0,
        do: [
          "  always_ff @(posedge clk) begin\n",
          "    if (ce) begin\n",
          bank_pipe,
          "    end\n",
          "  end\n"
        ],
        else: []
      ),
      mems
    ]
  end

  # A folded memory is read from `k + ram_latency - 1` stages before its
  # first group's state stage to the end of its last write, which must not
  # reach the next sample of the channel (`ii` cycles later).
  defp check_folded!(%{state_fold: 1}, _groups, _scan), do: :ok

  defp check_folded!(c, groups, scan) do
    for {u, gis, _} <- state_words(c) do
      members = Enum.map(gis, &Enum.at(groups, &1))
      s = members |> Enum.map(& &1.state_stage) |> Enum.min()
      w = members |> Enum.map(& &1.write_stage) |> Enum.max()
      loop = w - s + scan.ram_latency + scan.state_fold

      if loop > scan.ii do
        raise UnsupportedError,
              "scan: state memory #{u} (groups #{Enum.join(gis, ", ")}) needs #{loop} cycles from its " <>
                "first read to its last write, more than channels * state_fold = #{scan.ii}; " <>
                "use more channels or a smaller state_row_bits: (fewer memories merged)"
      end
    end

    :ok
  end

  defp ram_style(:ultra), do: "ultra"
  defp ram_style(:block), do: "block"
  defp ram_style(:distributed), do: "distributed"

  # State per group: registers (one channel), register arrays indexed by
  # the channel, or a memory with a word per channel.
  defp state_logic(c, groups, n, busy) do
    k = c.state_fold

    units =
      if c.state_mem == :registers,
        do: [],
        else:
          Enum.map(state_words(c), fn {u, gis, fields} ->
            members = Enum.map(gis, &Enum.at(groups, &1))
            {u, members, fields, unit_init(members, fields)}
          end)

    # rows of a folded word whose initial values differ need the row count
    by_row =
      Enum.any?(units, fn {_, _, fields, init} ->
        length(Enum.uniq(fold_rows(init, fields, k))) > 1
      end)

    parts =
      if c.state_mem == :registers do
        Enum.map(groups, &group_state(c, &1, n))
      else
        Enum.map(units, fn {u, members, fields, init} ->
          if k == 1,
            do: memory_state(c, u, members, fields, init, n),
            else: folded_state(c, u, members, fields, init, n, by_row)
        end)
      end

    clear =
      if busy do
        rows = n * k
        aw = max(1, bit_len(rows - 1))
        rw = max(1, bit_len(k - 1))

        row =
          if by_row,
            do: [
              "  logic [#{rw - 1}:0] st_clr_row;\n",
              "  always_ff @(posedge clk) begin\n",
              "    if (!rst_n || st_clr_row == #{rw}'d#{k - 1}) st_clr_row <= '0;\n",
              "    else if (st_clr) st_clr_row <= st_clr_row + #{rw}'d1;\n",
              "  end\n"
            ],
            else: []

        [
          "  // state clear after reset: one word per cycle, busy until done\n",
          "  logic [#{aw - 1}:0] st_clr_addr;\n",
          "  assign busy = st_clr;\n",
          "  always_ff @(posedge clk) begin\n",
          "    if (!rst_n) begin\n",
          "      st_clr <= 1'b1;\n",
          "      st_clr_addr <= '0;\n",
          "    end else if (st_clr) begin\n",
          "      st_clr_addr <= st_clr_addr + #{aw}'d1;\n",
          "      if (st_clr_addr == #{aw}'d#{rows - 1}) st_clr <= 1'b0;\n",
          "    end\n",
          "  end\n",
          row
        ]
      else
        []
      end

    {[clear | Enum.map(parts, &elem(&1, 0))], Enum.map(parts, &elem(&1, 1))}
  end

  defp group_state(_c, %{writes: []}, _n), do: {[], []}

  defp group_state(%{state_mem: :registers}, g, n) do
    s = g.state_stage
    w = g.write_stage

    {decls, resets, updates, what} =
      if n == 1 do
        {
          Enum.map(g.writes, fn {name, fmt, _, _} -> "  #{decl_type(fmt)} #{name};\n" end),
          Enum.map(g.writes, fn {name, fmt, init, _} ->
            "      #{name} <= #{lit(init, bits(fmt))};\n"
          end),
          Enum.map(g.writes, fn {name, _, _, x} -> "      #{name} <= #{x};\n" end),
          "state"
        }
      else
        {
          Enum.map(g.writes, fn {name, fmt, _, _} ->
            "  #{decl_type(fmt)} #{name}_mem [#{n}];\n"
          end),
          Enum.map(g.writes, fn {name, fmt, init, _} ->
            "      for (int i = 0; i < #{n}; i++) #{name}_mem[i] <= #{lit(init, bits(fmt))};\n"
          end),
          Enum.map(g.writes, fn {name, _, _, x} -> "      #{name}_mem[#{ch(w)}] <= #{x};\n" end),
          "state of #{n} channels"
        }
      end

    {
      [
        "  // #{what} (group #{g.index}): read in stage #{s}, written at the end of stage #{w}\n",
        decls,
        "\n"
      ],
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

  # The initial state word of a state memory (`fields` of `state_words/1`).
  defp unit_init(groups, fields) do
    groups
    |> Enum.flat_map(& &1.writes)
    |> Enum.zip(fields)
    |> Enum.reduce(0, fn {{_, fmt, v, _}, {_, _, offset, _}}, acc ->
      acc ||| band(v, (1 <<< bits(fmt)) - 1) <<< offset
    end)
  end

  defp word_bits(fields), do: fields |> Enum.map(fn {_, _, _, fmt} -> bits(fmt) end) |> Enum.sum()

  # `word` cut into `k` rows of `ceil(bits / k)` bits, row 0 the LSBs.
  defp fold_rows(word, fields, k) do
    rw = div(word_bits(fields) + k - 1, k)
    for r <- 0..(k - 1), do: word >>> (r * rw) &&& (1 <<< rw) - 1
  end

  defp state_memories(%{state_mem: :registers}), do: []

  defp state_memories(c) do
    k = c.state_fold

    Enum.map(state_words(c), fn {_u, _gis, fields} ->
      b = word_bits(fields)
      %{bits: b, width: div(b + k - 1, k), depth: c.channels * k}
    end)
  end

  defp memory_state(c, u, groups, fields, init, n) do
    g = hd(groups)
    writes = Enum.flat_map(groups, & &1.writes)
    s = g.state_stage
    w = g.write_stage
    rl = c.ram_latency
    ww = word_bits(fields)
    aw = max(1, bit_len(n - 1))
    m = "st#{u}"

    what =
      "group#{if length(groups) > 1, do: "s"} " <> Enum.map_join(groups, ", ", &"#{&1.index}")

    init_lit = "#{ww}'h#{Integer.to_string(init, 16)}"
    data = writes |> Enum.reverse() |> Enum.map_join(", ", fn {_, _, _, x} -> x end)
    clear = c.layout.state_init == :clear

    regs = Enum.map(1..rl, &"  logic [#{ww - 1}:0] #{m}_r#{&1};\n")

    reads =
      Enum.map(1..rl, fn j ->
        src = if j == 1, do: "#{m}_mem[#{ch(s - rl)}]", else: "#{m}_r#{j - 1}"
        "      #{m}_r#{j} <= #{src};\n"
      end)

    {
      [
        "  // state of #{n} channels (#{what}) in #{c.state_mem} RAM: read in stage #{s - rl} ",
        "for stage #{s}, written at the end of stage #{w}\n",
        "  (* ram_style = \"#{ram_style(c.state_mem)}\" *) logic [#{ww - 1}:0] #{m}_mem [#{n}];\n",
        regs,
        "  logic [#{ww - 1}:0] #{m}_q;\n",
        "  logic #{m}_we;\n",
        "  logic [#{aw - 1}:0] #{m}_wa;\n",
        "  logic [#{ww - 1}:0] #{m}_wd;\n",
        "  assign #{m}_q = #{m}_r#{rl};\n",
        if(clear,
          do: [],
          else: [
            "  initial begin\n",
            "    for (int i = 0; i < #{n}; i++) #{m}_mem[i] = #{init_lit};\n",
            "  end\n"
          ]
        ),
        "\n"
      ],
      [
        if(clear,
          do: [
            "  assign #{m}_we = st_clr || (ce && #{valid(w)});\n",
            "  assign #{m}_wa = st_clr ? st_clr_addr : #{ch(w)};\n",
            "  assign #{m}_wd = st_clr ? #{init_lit} : {#{data}};\n"
          ],
          else: [
            "  assign #{m}_we = ce && #{valid(w)};\n",
            "  assign #{m}_wa = #{ch(w)};\n",
            "  assign #{m}_wd = {#{data}};\n"
          ]
        ),
        "  always_ff @(posedge clk) begin\n",
        "    if (#{m}_we) #{m}_mem[#{m}_wa] <= #{m}_wd;\n",
        "  end\n",
        "  always_ff @(posedge clk) begin\n",
        "    if (ce) begin\n",
        reads,
        "    end\n",
        "  end\n"
      ]
    }
  end

  # A state memory folded over `k` rows per channel: row `r` of channel
  # `ch` is at `ch * k + r`. The kernel accepts one sample every `k` enabled
  # cycles, so at most one sample is in any `k` consecutive stages and one
  # port serves all rows: row `r` is read in stage `s - rl - k + 1 + r`
  # (rows 0 to k - 2 collect in a shift register, row k - 1 completes the
  # word in stage `s`), written in stage `w + r` (rows 1 to k - 1 from a
  # copy of the next state taken in stage `w`).
  defp folded_state(c, u, groups, fields, init, n, by_row) do
    writes = Enum.flat_map(groups, & &1.writes)
    s = groups |> Enum.map(& &1.state_stage) |> Enum.min()
    w = groups |> Enum.map(& &1.write_stage) |> Enum.max()
    rl = c.ram_latency
    k = c.state_fold
    ww = word_bits(fields)
    rw = div(ww + k - 1, k)
    pad = rw * k - ww
    rows = n * k
    aw = max(1, bit_len(rows - 1))
    m = "st#{u}"

    what =
      "group#{if length(groups) > 1, do: "s"} " <> Enum.map_join(groups, ", ", &"#{&1.index}")

    row_lits = init |> fold_rows(fields, k) |> Enum.map(&"#{rw}'h#{Integer.to_string(&1, 16)}")
    data = writes |> Enum.reverse() |> Enum.map_join(", ", fn {_, _, _, x} -> x end)
    data = if pad > 0, do: "#{pad}'d0, #{data}", else: data
    clear = c.layout.state_init == :clear

    pow2 = band(k, k - 1) == 0

    addr = fn stage, r ->
      if pow2,
        do: "{#{ch(stage)}, #{bit_len(k - 1)}'d#{r}}",
        else: "(#{aw}'(#{ch(stage)}) * #{aw}'d#{k} + #{aw}'d#{r})"
    end

    # a priority mux over the `k` stages of a window: `{stage, value}` pairs
    pick = fn pairs ->
      {init_pairs, [{_, last}]} = Enum.split(pairs, -1)
      Enum.map_join(init_pairs, "", fn {st, v} -> "#{valid(st)} ? #{v} : " end) <> last
    end

    first = s - rl - k + 1
    ra = pick.(for r <- 0..(k - 1), do: {first + r, addr.(first + r, r)})
    wa = pick.(for r <- 0..(k - 1), do: {w + r, addr.(w + r, r)})

    wd =
      pick.(
        for r <- 0..(k - 1),
            do:
              {w + r,
               if(r == 0, do: "#{m}_nw[#{rw - 1}:0]", else: "#{m}_hold[#{(r - 1) * rw} +: #{rw}]")}
      )

    any_w = Enum.map_join(0..(k - 1), " || ", &valid(w + &1))

    clr_wd =
      if by_row do
        Enum.with_index(row_lits)
        |> Enum.map(fn {l, r} -> {r, l} end)
        |> then(fn pairs ->
          {init_pairs, [{_, last}]} = Enum.split(pairs, -1)

          Enum.map_join(init_pairs, "", fn {r, l} ->
            "st_clr_row == #{max(1, bit_len(k - 1))}'d#{r} ? #{l} : "
          end) <> last
        end)
        |> then(&"(#{&1})")
      else
        hd(row_lits)
      end

    regs = Enum.map(1..rl, &"  logic [#{rw - 1}:0] #{m}_r#{&1};\n")

    reads =
      Enum.map(1..rl, fn j ->
        src = if j == 1, do: "#{m}_mem[#{m}_ra]", else: "#{m}_r#{j - 1}"
        "      #{m}_r#{j} <= #{src};\n"
      end)

    hw = (k - 1) * rw
    acc_next = if k == 2, do: "#{m}_r#{rl}", else: "{#{m}_r#{rl}, #{m}_acc[#{hw - 1}:#{rw}]}"

    initial =
      Enum.map(Enum.with_index(row_lits), fn {l, r} ->
        "    for (int i = 0; i < #{n}; i++) #{m}_mem[i * #{k} + #{r}] = #{l};\n"
      end)

    {
      [
        "  // state of #{n} channels (#{what}) in #{c.state_mem} RAM, #{k} rows of #{rw} bits per ",
        "channel: read in stages #{first}-#{s - rl} for stage #{s}, written in stages #{w}-#{w + k - 1}\n",
        "  (* ram_style = \"#{ram_style(c.state_mem)}\" *) logic [#{rw - 1}:0] #{m}_mem [#{rows}];\n",
        regs,
        "  logic [#{aw - 1}:0] #{m}_ra;\n",
        "  logic [#{hw - 1}:0] #{m}_acc;\n",
        "  logic [#{k * rw - 1}:0] #{m}_word;\n",
        "  logic [#{ww - 1}:0] #{m}_q;\n",
        "  logic [#{k * rw - 1}:0] #{m}_nw;\n",
        "  logic [#{hw - 1}:0] #{m}_hold;\n",
        "  logic #{m}_we;\n",
        "  logic [#{aw - 1}:0] #{m}_wa;\n",
        "  logic [#{rw - 1}:0] #{m}_wd;\n",
        "  assign #{m}_word = {#{m}_r#{rl}, #{m}_acc};\n",
        "  assign #{m}_q = #{m}_word[#{ww - 1}:0];\n",
        if(clear, do: [], else: ["  initial begin\n", initial, "  end\n"]),
        "\n"
      ],
      [
        "  assign #{m}_ra = #{ra};\n",
        "  assign #{m}_nw = {#{data}};\n",
        if(clear,
          do: [
            "  assign #{m}_we = st_clr || (ce && (#{any_w}));\n",
            "  assign #{m}_wa = st_clr ? st_clr_addr : #{wa};\n",
            "  assign #{m}_wd = st_clr ? #{clr_wd} : #{wd};\n"
          ],
          else: [
            "  assign #{m}_we = ce && (#{any_w});\n",
            "  assign #{m}_wa = #{wa};\n",
            "  assign #{m}_wd = #{wd};\n"
          ]
        ),
        "  always_ff @(posedge clk) begin\n",
        "    if (#{m}_we) #{m}_mem[#{m}_wa] <= #{m}_wd;\n",
        "  end\n",
        "  always_ff @(posedge clk) begin\n",
        "    if (ce) begin\n",
        reads,
        "      #{m}_acc <= #{acc_next};\n",
        "      if (#{valid(w)}) #{m}_hold <= #{m}_nw[#{k * rw - 1}:#{rw}];\n",
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
