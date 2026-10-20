defmodule ExHdl.RTL.Wrap.ScanModel do
  @moduledoc """
  Cycle-accurate BEAM model of a stream kernel wrapped with
  `ExHdl.RTL.Wrap.scan/2` (option `model:`), for `ExHdl.RTL.Sim`.

  The sample values come from the Nx kernel itself (compiled once with
  `NxFixed.Compiler`, then stepped once per accepted sample); the timing
  follows the control logic of `ExHdl.Backends.SystemVerilog.Scan`:

    * one clock enable `ce` for the pipeline, high while the output buffer
      (2 entries, `2 * lanes` for variable rate, rounded up to a power of
      two) has room for a full push;
    * `s_axis_tready = ce and issue_ok`, `issue_ok` false between two
      samples of an `ii: n` kernel (one sample every `n` enabled cycles),
      while new parameters are pending, and during the state clear after
      reset (`busy`);
    * an accepted sample's outputs enter the output buffer `latency - 1`
      enabled cycles later; `m_axis_tvalid` is "buffer not empty";
    * `p_load` captures the parameter ports, which apply once the
      pipeline is empty; reset loads them directly;
    * channels round robin in arrival order, or from `s_axis_tid`;
      `m_axis_tid` and `m_axis_tuser` travel with the sample.

  Per-channel parameters (`channel_params:`) are not modelled.
  """

  @behaviour ExHdl.RTL.Model

  import Bitwise

  alias ExHdl.Backends.SystemVerilog.Scan.Design

  @impl true
  def init(_params), do: raise(ArgumentError, "use Wrap.scan(design, model: [...])")

  @impl true
  def init(_params, {%Design{} = d, opts}) do
    if d.channel_params != [],
      do: raise(ArgumentError, "Wrap.scan model: per-channel parameters are not modelled")

    fun = Keyword.fetch!(opts, :fun)
    args = Keyword.fetch!(opts, :args)
    state_index = Keyword.get(opts, :state, 1)
    {kernel_args, _kopts} = Enum.split_with(args, &(not is_list(&1)))
    sample_t = Enum.at(kernel_args, 0)
    state_t = Enum.at(kernel_args, state_index)
    param_ts = kernel_args |> List.delete_at(state_index) |> tl()

    step = Nx.Defn.compile(fun, args, compiler: NxFixed.Compiler)

    init_state =
      case Keyword.fetch(opts, :init) do
        {:ok, v} ->
          v

        :error ->
          Nx.Defn.Composite.traverse(
            state_t,
            &Nx.broadcast(Nx.tensor(0, type: &1.type), &1.shape)
          )
      end

    nl = d.lanes || 1
    ob_depth = pow2(max(2, 2 * nl))
    l = d.latency - 1

    cfg = %{
      d: d,
      step: step,
      state_index: state_index,
      sample_t: sample_t,
      param_ts: param_ts,
      init: init_state,
      l: l,
      depth: max(max(l, d.write_stage || 0), 1),
      ob_depth: ob_depth,
      nl: nl,
      gap: d.channels == 1 and d.ii > 1,
      clear_on_reset: d.state_mem == :registers or d.busy,
      out_type: Keyword.get(opts, :out_type, {:u, d.out_width})
    }

    # before the first reset every register is 0, as in Verilator; a state
    # memory without the clear sweep starts with :init (its initial contents)
    zero_state =
      Nx.Defn.Composite.traverse(state_t, &Nx.broadcast(Nx.tensor(0, type: &1.type), &1.shape))

    cfg = Map.put(cfg, :zero_state, zero_state)
    power_on = if cfg.clear_on_reset, do: zero_state, else: init_state
    empty = %{data: 0, user: 0, tid: 0}

    %{
      cfg: cfg,
      pipe: List.duplicate(nil, cfg.depth),
      gap: 0,
      ch: 0,
      p_q: params(cfg, %{}),
      p_s: params(cfg, %{}),
      p_pending: false,
      st_clr: false,
      st_clr_addr: 0,
      ob: List.to_tuple(List.duplicate(empty, ob_depth)),
      wp: 0,
      rp: 0,
      ob_count: 0,
      states: List.to_tuple(List.duplicate(power_on, d.channels))
    }
  end

  # synchronous reset: the registers the generated module resets
  defp reset(cfg, st, inputs) do
    states =
      if cfg.clear_on_reset,
        do: List.to_tuple(List.duplicate(cfg.init, cfg.d.channels)),
        else: st.states

    %{
      st
      | pipe: List.duplicate(nil, cfg.depth),
        gap: cfg.d.ii - 1,
        ch: 0,
        p_q: params(cfg, inputs),
        p_pending: false,
        st_clr: cfg.d.busy,
        st_clr_addr: 0,
        wp: 0,
        rp: 0,
        ob_count: 0,
        states: states
    }
  end

  @impl true
  def outputs(st, _inputs) do
    cfg = st.cfg
    ce = st.ob_count <= cfg.ob_depth - cfg.nl

    head = elem(st.ob, st.rp)

    base = %{
      s_axis_tready: b(ce and issue_ok?(st)),
      m_axis_tvalid: b(st.ob_count != 0),
      m_axis_tdata: ExHdl.RTL.Expr.wrap(head.data, cfg.out_type)
    }

    base
    |> put_if(cfg.d.channels > 1, :m_axis_tid, head.tid)
    |> put_if(cfg.d.tuser > 0, :m_axis_tuser, head.user)
    |> put_if(cfg.d.busy, :busy, b(st.st_clr))
  end

  defp put_if(map, true, k, v), do: Map.put(map, k, v)
  defp put_if(map, false, _k, _v), do: map

  defp issue_ok?(st) do
    gap_ok = not st.cfg.gap or st.gap == st.cfg.d.ii - 1
    gap_ok and not st.p_pending and not st.st_clr
  end

  @impl true
  def clock(:sys, st, %{rst_n: 0} = inputs), do: reset(st.cfg, st, inputs)

  def clock(:sys, st, inputs) do
    cfg = st.cfg
    ce = st.ob_count <= cfg.ob_depth - cfg.nl
    issue_ok = issue_ok?(st)
    vld_0 = inputs.s_axis_tvalid == 1 and issue_ok
    accept = ce and vld_0

    # the sample entering stage 0, computed when accepted
    {entry, st} = if accept, do: sample(st, inputs), else: {nil, st}

    # stage L pushes into the output buffer
    pushed =
      if ce do
        item = if cfg.l == 0, do: entry, else: Enum.at(st.pipe, cfg.l - 1)
        item || []
      else
        []
      end

    pop = st.ob_count != 0 and inputs.m_axis_tready == 1
    n = cfg.ob_depth

    ob =
      pushed
      |> Enum.with_index()
      |> Enum.reduce(st.ob, fn {item, j}, ob -> put_elem(ob, rem(st.wp + j, n), item) end)

    pipe = if ce, do: [entry | Enum.drop(st.pipe, -1)], else: st.pipe

    gap =
      cond do
        not ce -> st.gap
        vld_0 -> 0
        st.gap == cfg.d.ii - 1 -> st.gap
        true -> st.gap + 1
      end

    ch =
      if ce and vld_0 and not cfg.d.tid,
        do: if(st.ch == cfg.d.channels - 1, do: 0, else: st.ch + 1),
        else: st.ch

    empty = Enum.all?(st.pipe, &is_nil/1)

    {p_q, p_s, p_pending} =
      cond do
        Map.get(inputs, :p_load, 0) == 1 -> {st.p_q, params(cfg, inputs), true}
        st.p_pending and empty -> {st.p_s, nil, false}
        true -> {st.p_q, st.p_s, st.p_pending}
      end

    {st_clr, addr} =
      cond do
        not st.st_clr -> {false, 0}
        st.st_clr_addr == cfg.d.channels - 1 -> {false, st.st_clr_addr + 1}
        true -> {true, st.st_clr_addr + 1}
      end

    %{
      st
      | pipe: pipe,
        ob: ob,
        wp: rem(st.wp + length(pushed), n),
        rp: if(pop, do: rem(st.rp + 1, n), else: st.rp),
        ob_count: st.ob_count + length(pushed) - if(pop, do: 1, else: 0),
        gap: gap,
        ch: ch,
        p_q: p_q,
        p_s: p_s,
        p_pending: p_pending,
        st_clr: st_clr,
        st_clr_addr: addr
    }
  end

  # Runs the kernel on the accepted sample; returns the output items.
  defp sample(st, inputs) do
    cfg = st.cfg
    d = cfg.d
    c = if d.tid, do: Map.get(inputs, :s_axis_tid, 0), else: st.ch
    user = Map.get(inputs, :s_axis_tuser, 0)
    sample = unpack(cfg.sample_t, d.inputs, raw(inputs.s_axis_tdata, d.in_width))
    state = elem(st.states, c)

    args =
      [sample | st.p_q]
      |> List.insert_at(cfg.state_index, state)

    {out, next} = apply(cfg.step, args)
    items = items(cfg, out) |> Enum.map(&%{data: &1, user: user, tid: c})
    {items, %{st | states: put_elem(st.states, c, next)}}
  end

  defp items(%{d: %Design{lanes: nil} = d}, out) do
    leaves = flat(out)
    [pack(d.outputs, Enum.map(leaves, &Nx.to_flat_list/1))]
  end

  defp items(%{d: d}, {values, count}) do
    n = Nx.to_number(count)
    leaves = flat(values)

    for j <- 0..(n - 1)//1 do
      pack(d.outputs, Enum.map(leaves, &(&1[j] |> Nx.to_flat_list())))
    end
  end

  defp flat(container), do: Nx.Defn.Composite.flatten_list([container])

  defp pack(fields, values) do
    fields
    |> Enum.zip(values)
    |> Enum.reduce(0, fn {f, vs}, acc ->
      vs
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {v, e}, acc ->
        acc ||| (v &&& (1 <<< f.bits) - 1) <<< (f.offset + e * f.bits)
      end)
    end)
  end

  # parameter ports -> parameter containers (as the kernel takes them)
  defp params(cfg, inputs) do
    leaves =
      Enum.map(cfg.d.params, fn p ->
        word = raw(Map.get(inputs, String.to_atom(p.port), 0), p.bits * size(p.shape))
        tensor(word, 0, p)
      end)

    {containers, []} =
      Enum.map_reduce(cfg.param_ts, leaves, fn t, leaves -> refill(t, leaves) end)

    containers
  end

  defp unpack(template, fields, word) do
    leaves = Enum.map(fields, &tensor(word, &1.offset, &1))
    {c, []} = refill(template, leaves)
    c
  end

  defp refill(template, leaves) do
    Nx.Defn.Composite.traverse(template, leaves, fn _t, [l | rest] -> {l, rest} end)
  end

  defp tensor(word, offset, f) do
    n = size(f.shape)
    mask = (1 <<< f.bits) - 1

    elems =
      for e <- 0..(n - 1)//1 do
        v = word >>> (offset + e * f.bits) &&& mask
        if elem(f.type, 0) == :s and v >= 1 <<< (f.bits - 1), do: v - (1 <<< f.bits), else: v
      end

    elems |> Nx.tensor(type: f.type) |> Nx.reshape(f.shape)
  end

  defp raw(v, w), do: v &&& (1 <<< w) - 1
  defp size(shape), do: shape |> Tuple.to_list() |> Enum.product()
  defp b(true), do: 1
  defp b(false), do: 0
  defp pow2(n), do: if(n <= 1, do: 1, else: 2 * pow2(div(n + 1, 2)))
end
