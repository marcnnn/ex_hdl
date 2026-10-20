defmodule ExHdl.RTL.Builder do
  @moduledoc false
  # Elaboration state of the module being built, kept in the process
  # dictionary while the body of ExHdl.RTL.module/3 runs (a stack, so
  # generators may build other modules while building one).

  alias ExHdl.RTL.{Check, Domain, ElaborationError, Expr, FSM, Memory}

  @key {__MODULE__, :stack}

  # IEEE 1800-2017 Annex B
  @sv_keywords ~w(accept_on alias always always_comb always_ff always_latch and assert assign
    assume automatic before begin bind bins binsof bit break buf bufif0 bufif1 byte case casex
    casez cell chandle checker class clocking cmos config const constraint context continue cover
    covergroup coverpoint cross deassign default defparam design disable dist do edge else end
    endcase endchecker endclass endclocking endconfig endfunction endgenerate endgroup
    endinterface endmodule endpackage endprimitive endprogram endproperty endsequence endspecify
    endtable endtask enum event eventually expect export extends extern final first_match for
    force foreach forever fork forkjoin function generate genvar global highz0 highz1 if iff
    ifnone ignore_bins illegal_bins implements implies import incdir include initial inout input
    inside instance int integer interconnect interface intersect join join_any join_none large
    let liblist library local localparam logic longint macromodule matches medium modport module
    nand negedge nettype new nexttime nmos nor noshowcancelled not notif0 notif1 null or output
    package packed parameter pmos posedge primitive priority program property protected pull0
    pull1 pulldown pullup pulsestyle_ondetect pulsestyle_onevent pure rand randc randcase
    randsequence rcmos real realtime ref reg reject_on release repeat restrict return rnmos rpmos
    rtran rtranif0 rtranif1 s_always s_eventually s_nexttime s_until s_until_with scalared
    sequence shortint shortreal showcancelled signed small soft solve specify specparam static
    string strong strong0 strong1 struct super supply0 supply1 sync_accept_on sync_reject_on
    table tagged task this throughout time timeprecision timeunit tran tranif0 tranif1 tri tri0
    tri1 triand trior trireg type typedef union unique unique0 unsigned until until_with untyped
    use uwire var vectored virtual void wait wait_order wand weak weak0 weak1 while wildcard wire
    with within wor xnor xor)

  @doc false
  def sv_keyword?(name), do: to_string(name) in @sv_keywords

  # -- lifecycle -------------------------------------------------------------------------

  def build(kind, name, opts, fun) do
    name = module_name!(name)

    b = %{
      kind: kind,
      name: name,
      owner: make_ref(),
      opts: opts,
      ports: [],
      signals: %{},
      decls: [],
      domains: [],
      blocks: [],
      frames: [],
      instances: [],
      memories: [],
      bundles: [],
      fsms: [],
      fsm_stack: [],
      fsm_forwards: %{},
      clock_outputs: []
    }

    stack = Process.get(@key, [])
    Process.put(@key, [b | stack])

    try do
      fun.()
      [b | _] = Process.get(@key)
      forwards_resolved!(b)
      Check.finalize(b)
    after
      Process.put(@key, stack)
    end
  end

  def current! do
    case Process.get(@key, []) do
      [b | _] ->
        b

      [] ->
        raise ElaborationError, "hardware declarations are only valid inside ExHdl.RTL.module/3"
    end
  end

  def put(b) do
    [_ | rest] = Process.get(@key)
    Process.put(@key, [b | rest])
    b
  end

  def update(f), do: put(f.(current!()))

  defp module_name!(name) when is_atom(name), do: module_name!(Atom.to_string(name))

  defp module_name!(name) when is_binary(name) do
    unless name =~ ~r/^[A-Za-z][A-Za-z0-9_]*$/ and name not in @sv_keywords,
      do: raise(ElaborationError, "invalid module name #{inspect(name)}")

    name
  end

  def name!(name) when is_atom(name) do
    s = Atom.to_string(name)

    unless s =~ ~r/^[A-Za-z][A-Za-z0-9_]*$/ and s not in @sv_keywords,
      do:
        raise(
          ElaborationError,
          "invalid signal name #{inspect(name)}: needs a letter first, then letters, digits, _ " <>
            "and must not be a SystemVerilog keyword"
        )

    name
  end

  def name!(other), do: raise(ElaborationError, "signal names are atoms, got #{inspect(other)}")

  # -- signals ---------------------------------------------------------------------------

  def handle(b, name), do: %Expr{op: :sig, args: [name, b.owner], type: b.signals[name].type}

  defp add_signal(name, type, kind, extra) do
    name = name!(name)
    type = Expr.type!(type)
    b = current!()

    if Map.has_key?(b.signals, name) or Enum.any?(b.memories, &(&1.name == name)),
      do:
        raise(
          ElaborationError,
          "#{b.name}: #{name} is declared twice" <> twice_hint(b, name, extra)
        )

    sig =
      Map.merge(
        %{name: name, type: type, kind: kind, domain: nil, reset: nil, attrs: [], port: nil},
        extra
      )

    b = put(%{b | signals: Map.put(b.signals, name, sig), decls: b.decls ++ [name]})
    handle(b, name)
  end

  # Instance port wires are `<inst>_<port>`; say which instance a clash comes from.
  defp twice_hint(b, name, extra) do
    inst_hint = fn {i, p} ->
      "; #{name} is the wire of port #{p} of instance #{i} (instance ports are " <>
        "<instance>_<port>), rename the instance (e.g. u_#{i}) or the signal"
    end

    case {b.signals[name], extra} do
      {%{inst: inst}, _} -> inst_hint.(inst)
      {_, %{inst: inst}} -> inst_hint.(inst)
      _ -> ""
    end
  end

  defp add_port(name, dir, type, role, opts) do
    port = %{
      name: name,
      dir: dir,
      type: Expr.type!(type),
      domain: opts[:domain],
      role: role,
      comb_from: Keyword.get(opts, :comb_from, :all)
    }

    update(fn b ->
      if Keyword.get(opts, :first, false),
        do: %{b | ports: [port | b.ports]},
        else: %{b | ports: b.ports ++ [port]}
    end)
  end

  @domain_values [:async, :static, nil]

  defp check_domain_opt!(opts) do
    d = opts[:domain]

    unless is_atom(d),
      do:
        raise(
          ElaborationError,
          "domain: must be a domain name, :async or :static, got #{inspect(d)}"
        )

    d
  end

  def input(name, type, opts) do
    check_domain_opt!(opts)
    e = add_signal(name, type, :input, %{domain: opts[:domain], port: :input})
    add_port(name, :input, type, :data, opts)
    e
  end

  def output(name, type, opts) do
    check_domain_opt!(opts)
    if Keyword.get(opts, :clock, false), do: clock_output!(name, type)

    if Keyword.get(opts, :reg, false) or Keyword.has_key?(opts, :reset) do
      dom = reg_domain(opts)
      reset = reg_reset!(name, type, dom, opts)

      e =
        add_signal(name, type, :reg, %{
          domain: dom,
          reset: reset,
          attrs: reg_attrs(opts),
          port: :output
        })

      add_port(name, :output, type, :data, Keyword.put(opts, :domain, dom))
      e
    else
      e = add_signal(name, type, :output, %{domain: opts[:domain], port: :output})
      add_port(name, :output, type, :data, opts)
      e
    end
  end

  defp clock_output!(name, type) do
    b = current!()

    unless b.kind == :black_box,
      do:
        raise(
          ElaborationError,
          "#{b.name}: output #{name}: clock: true marks black-box outputs (BUFG O, MMCM " <>
            "CLKOUT); a module drives an internal clock with domain(..., clock_port: false)"
        )

    unless Expr.type!(type) == {:u, 1},
      do: raise(ElaborationError, "#{b.name}: clock output #{name} must be 1 bit")

    update(&%{&1 | clock_outputs: &1.clock_outputs ++ [name]})
  end

  @doc false
  # Bidirectional port: no logic may read or drive it; it connects to inout
  # ports of instances (an IOBUF black box, a child passing it through).
  def inout(name, type, opts) do
    for k <- Keyword.keys(opts) -- [:domain],
        do: raise(ElaborationError, "inout #{name}: unknown option #{inspect(k)}")

    d = Keyword.get(opts, :domain)

    unless d in [nil, :async],
      do: raise(ElaborationError, "inout #{name}: an inout belongs to no domain (domain: :async)")

    e = add_signal(name, type, :inout, %{port: :inout})
    add_port(name, :inout, type, :data, domain: nil)
    e
  end

  def reg(name, type, opts) do
    dom = reg_domain(opts)
    reset = reg_reset!(name, type, dom, opts)
    add_signal(name, type, :reg, %{domain: dom, reset: reset, attrs: reg_attrs(opts)})
  end

  # Default reset 0 in domains with a reset; none otherwise.
  defp reg_reset!(name, type, dom, opts) do
    has_reset = domain!(current!(), dom).reset != nil

    case Keyword.fetch(opts, :reset) do
      :error when has_reset ->
        0

      :error ->
        nil

      {:ok, nil} ->
        nil

      {:ok, v} when has_reset ->
        reset_value!(name, type, v)

      {:ok, _} ->
        raise ElaborationError, "register #{name}: domain #{dom} has no reset; use reset: nil"
    end
  end

  defp reg_attrs(opts) do
    for k <- [:async_reg, :cdc],
        Keyword.get(opts, k, false) not in [true, false],
        do: raise(ElaborationError, "#{k}: must be a boolean")

    async_reg = Keyword.get(opts, :async_reg, false)

    [async_reg: async_reg, cdc: async_reg or Keyword.get(opts, :cdc, false)] ++
      Keyword.get(opts, :attrs, [])
  end

  defp reset_value!(_name, _type, nil), do: nil

  defp reset_value!(name, type, v) do
    t = Expr.type!(type)
    v = if is_boolean(v), do: if(v, do: 1, else: 0), else: v

    unless is_integer(v) and v in Expr.range(t),
      do:
        raise(
          ExHdl.RTL.WidthError,
          "reset value #{inspect(v)} of #{name} does not fit #{Expr.fmt(t)}"
        )

    v
  end

  defp reg_domain(opts) do
    case opts[:domain] do
      nil ->
        ensure_domain()

      d when d in @domain_values ->
        raise ElaborationError, "registers need a clock domain, not #{inspect(d)}"

      d ->
        domain!(current!(), d).name
    end
  end

  def wire(name, %Expr{} = e, opts) do
    w = add_signal(name, e.type, :wire, %{domain: opts[:domain], attrs: wire_attrs(name, opts)})
    assign(w, e)
    w
  end

  def wire(name, type, opts),
    do: add_signal(name, type, :wire, %{domain: opts[:domain], attrs: wire_attrs(name, opts)})

  # `rom_style:` for a wire defined by a `mux(sel, list)` table.
  defp wire_attrs(name, opts) do
    style =
      case Keyword.get(opts, :rom_style) do
        nil ->
          []

        s when s in [:distributed, :block] ->
          [rom_style: Atom.to_string(s)]

        other ->
          raise ElaborationError,
                "wire #{name}: rom_style must be :distributed or :block, got #{inspect(other)}"
      end

    style ++ Keyword.get(opts, :attrs, [])
  end

  def signal(name) do
    b = current!()

    if Map.has_key?(b.signals, name),
      do: handle(b, name),
      else: raise(ElaborationError, "#{b.name}: no signal named #{inspect(name)}")
  end

  # -- domains ---------------------------------------------------------------------------

  def domain(name, opts) do
    name = name!(name)
    b = current!()

    if Enum.any?(b.domains, &(&1.name == name)),
      do: raise(ElaborationError, "#{b.name}: domain #{name} declared twice")

    if name in [:async, :static],
      do: raise(ElaborationError, "#{name} is reserved, not a domain name")

    clock = Keyword.get(opts, :clock, if(name == :sys, do: :clk, else: :"clk_#{name}"))
    reset = Keyword.get(opts, :reset, if(name == :sys, do: :rst_n, else: :"rst_#{name}_n"))
    kind = Keyword.get(opts, :reset_kind, :sync)
    active = Keyword.get(opts, :reset_active, :low)
    clock_port = Keyword.get(opts, :clock_port, true)
    reset_port = Keyword.get(opts, :reset_port, true)
    first = Keyword.get(opts, :first, false)

    unless kind in [:sync, :async],
      do: raise(ElaborationError, "reset_kind must be :sync or :async")

    unless active in [:low, :high],
      do: raise(ElaborationError, "reset_active must be :low or :high")

    # with first: ports are prepended, so declare the reset first to get clk, rst
    reset_e = first && reset && reset_signal(reset, reset_port, first)
    clock_e = clock_signal(clock, clock_port, first)
    reset_e = reset_e || (reset && reset_signal(reset, reset_port, first))

    d = %Domain{
      name: name,
      clock: clock_e,
      reset: reset_e,
      reset_kind: kind,
      reset_active: active,
      clock_port: clock_port,
      reset_port: reset_port
    }

    update(fn b ->
      if first, do: %{b | domains: [d | b.domains]}, else: %{b | domains: b.domains ++ [d]}
    end)

    d
  end

  defp clock_signal(name, port?, first) do
    b = current!()

    case b.signals[name] do
      %{kind: k} when k in [:clock, :clock_int] ->
        handle(b, name)

      nil ->
        if port? do
          e = add_signal(name, 1, :clock, %{port: :input})
          add_port(name, :input, 1, :clock, first: first)
          e
        else
          add_signal(name, 1, :clock_int, %{})
        end

      _ ->
        raise ElaborationError, "#{b.name}: clock #{name} is already a non-clock signal"
    end
  end

  defp reset_signal(name, port?, first) do
    b = current!()

    case b.signals[name] do
      %{kind: k} when k in [:reset, :reset_int] ->
        handle(b, name)

      nil ->
        if port? do
          e = add_signal(name, 1, :reset, %{port: :input})
          add_port(name, :input, 1, :reset, first: first)
          e
        else
          add_signal(name, 1, :reset_int, %{})
        end

      _ ->
        raise ElaborationError, "#{b.name}: reset #{name} is already a non-reset signal"
    end
  end

  # The module's default domain, creating `:sys` (clk, rst_n) on first use.
  def ensure_domain do
    case current!().domains do
      [d | _] ->
        d.name

      [] ->
        # the ports of the implicit domain go first
        domain(:sys, first: true, clock: :clk, reset: :rst_n)
        :sys
    end
  end

  def domain!(b, name) do
    Enum.find(b.domains, &(&1.name == name)) ||
      raise ElaborationError,
            "#{b.name}: unknown domain #{inspect(name)}; declared: #{inspect(Enum.map(b.domains, & &1.name))}"
  end

  def resolve_domain(nil) do
    name = ensure_domain()
    domain!(current!(), name)
  end

  def resolve_domain(name), do: domain!(current!(), name)

  # -- blocks and statements -------------------------------------------------------------

  def comb(fun), do: block(:comb, fun)

  def sync(domain, fun) do
    d = resolve_domain(domain)
    block({:sync, d.name}, fun)
  end

  defp block(kind, fun) do
    b = current!()

    if b.frames != [],
      do: raise(ElaborationError, "comb/sync blocks cannot be nested")

    if b.kind == :black_box, do: raise(ElaborationError, "black boxes have no logic")

    put(%{b | frames: [{kind, []}]})
    fun.()
    b = current!()
    [{^kind, stmts}] = b.frames

    block =
      case kind do
        :comb -> {:comb, Enum.reverse(stmts)}
        {:sync, d} -> {:sync, d, Enum.reverse(stmts)}
      end

    put(%{b | frames: [], blocks: b.blocks ++ [block]})
    nil
  end

  defp emit(stmt) do
    update(fn %{frames: [{k, stmts} | rest]} = b ->
      %{b | frames: [{k, [stmt | stmts]} | rest]}
    end)
  end

  defp capture(fun) do
    update(fn %{frames: [{k, _} | _] = fs} = b -> %{b | frames: [{k, []} | fs]} end)
    fun.()
    b = current!()
    [{_, stmts} | rest] = b.frames
    put(%{b | frames: rest})
    Enum.reverse(stmts)
  end

  defp frame_kind(b) do
    case b.frames do
      [] -> :top
      [{k, _} | _] -> k
    end
  end

  def assign(%Expr{op: :sig, args: [name, owner]}, value) do
    b = current!()

    if owner != b.owner,
      do: raise(ElaborationError, "#{b.name}: #{name} belongs to another module")

    sig = b.signals[name]
    what = "assignment to #{name}"
    expr = Expr.coerce!(value, sig.type, what)

    case {frame_kind(b), sig.kind} do
      {:top, k} when k in [:output, :wire, :inst_in, :clock_int, :reset_int] ->
        put(%{b | blocks: b.blocks ++ [{:comb, [{:assign, name, expr}]}]})

      {:comb, k} when k in [:output, :wire, :inst_in, :clock_int, :reset_int] ->
        emit({:assign, name, expr})

      {{:sync, d}, :reg} ->
        if sig.domain != d,
          do:
            raise(
              ElaborationError,
              "#{b.name}: register #{name} belongs to domain #{sig.domain}, assigned in sync(#{inspect(d)})"
            )

        emit({:assign, name, expr})

      {{:sync, _}, k} ->
        raise ElaborationError,
              "#{b.name}: #{name} (#{kind_name(k)}) assigned in a sync block; only registers can be"

      {_, :reg} ->
        raise ElaborationError, "#{b.name}: register #{name} can only be assigned in sync blocks"

      {_, k} ->
        raise ElaborationError, "#{b.name}: #{name} is #{kind_name(k)} and cannot be assigned"
    end

    %ExHdl.RTL.Assigned{target: name}
  end

  def assign(%{__bundle__: _}, _),
    do: raise(ElaborationError, "use connect(source, sink) to connect bundles")

  def assign(target, _),
    do: raise(ElaborationError, "cannot assign to #{inspect(target)}; targets are signals")

  defp kind_name(:inout), do: "an inout port (inouts only connect to inout ports of instances)"

  defp kind_name(:input), do: "an input"
  defp kind_name(:inst_out), do: "an instance output"
  defp kind_name(:mem_data), do: "a memory read port"
  defp kind_name(:mem_async), do: "a memory read port"
  defp kind_name(:clock), do: "a clock input"
  defp kind_name(:reset), do: "a reset input"
  defp kind_name(k), do: "a #{k}"

  @if_hint "inside module/3 and rtl/1, `if` on a hardware value is a hardware conditional; " <>
             "for a decision at elaboration time on a generator value (an accumulator that " <>
             "may be nil, an option) use case, is_nil/1 or Kernel.if/2"

  def if_(%Expr{} = c, then, other) do
    unless match?(%Expr{type: {:u, 1}}, c),
      do:
        raise(
          ExHdl.RTL.WidthError,
          "if condition: needs a 1-bit unsigned value, got #{Expr.fmt(c.type)}; " <>
            "compare with != 0. Note: " <> @if_hint
        )

    b = current!()

    if frame_kind(b) == :top,
      do:
        raise(
          ElaborationError,
          "#{b.name}: hardware if outside a comb or sync block; " <> @if_hint
        )

    t = capture(then)
    e = capture(other)
    emit({:if, c, t, e})
    nil
  end

  def if_(c, then, other) do
    if c not in [nil, false], do: then.(), else: other.()
  end

  # clauses: [{:default, body_fun} | {values_fun, body_fun}]
  def switch(%FSM{state: s, states: states}, clauses), do: hw_switch(s, Map.new(states), clauses)
  def switch(%Expr{} = subj, clauses), do: hw_switch(subj, %{}, clauses)

  def switch(value, clauses) do
    found =
      Enum.find(clauses, fn
        {:default, _} -> true
        {vf, _} -> value in List.wrap(vf.())
      end)

    case found do
      {_, body} -> body.()
      nil -> raise CaseClauseError, term: value
    end
  end

  defp hw_switch(subj, labels, clauses) do
    b = current!()

    if frame_kind(b) == :top,
      do: raise(ElaborationError, "#{b.name}: switch outside a comb or sync block")

    {cases, default} =
      Enum.reduce(clauses, {[], nil}, fn
        {:default, body}, {cases, nil} ->
          {cases, capture(body)}

        {:default, _}, _ ->
          raise ElaborationError, "switch has two default clauses"

        {vf, body}, {cases, d} ->
          values = vf.() |> List.wrap() |> Enum.map(&case_value(&1, subj, labels))
          {cases ++ [{values, capture(body)}], d}
      end)

    seen = cases |> Enum.flat_map(&elem(&1, 0)) |> Enum.map(&hd(&1.args))
    dup = seen -- Enum.uniq(seen)

    if dup != [],
      do: raise(ElaborationError, "switch: duplicate case value(s) #{inspect(Enum.uniq(dup))}")

    emit({:switch, subj, cases, default})
    nil
  end

  defp case_value(atom, subj, labels) when is_atom(atom) do
    case labels do
      %{^atom => code} -> label_for(subj, atom, code)
      _ -> raise ElaborationError, "switch: unknown state #{inspect(atom)}"
    end
  end

  defp case_value(v, subj, _) when is_integer(v), do: Expr.const(v, subj.type)
  defp case_value(%Expr{op: :const} = c, subj, _), do: Expr.coerce!(c, subj.type, "switch case")

  defp case_value(v, _, _),
    do: raise(ElaborationError, "switch case values are constants, got #{inspect(v)}")

  def label_for(%Expr{type: t, args: [state | _]}, atom, code) do
    b = current!()
    fsm = Enum.find(b.fsms, &(&1.state.args |> hd() == state))
    Expr.label(code, t, label_name(fsm.name, atom))
  end

  def label_name(fsm, state), do: String.upcase("#{fsm}_#{state}")

  # -- hierarchy -------------------------------------------------------------------------

  def instance(name, %ExHdl.RTL.Module{} = mod, opts) do
    name = name!(name)
    b = current!()

    if b.kind == :black_box, do: raise(ElaborationError, "black boxes cannot contain instances")

    params = Keyword.get(opts, :params, [])

    for {k, _} <- params,
        not Keyword.has_key?(mod.params, k),
        do: raise(ElaborationError, "instance #{name}: #{mod.name} has no parameter #{k}")

    params = Keyword.merge(mod.params, params)
    dmap = domain_map(b, name, mod, Keyword.get(opts, :domains, []))
    {inout_ports, other_ports} = Enum.split_with(mod.ports, &(&1.dir == :inout))

    conns =
      Enum.map(other_ports, fn p ->
        case p.role do
          :clock ->
            cd = Enum.find(mod.domains, &(&1.clock_port and port_name(&1.clock) == p.name))
            {p.name, {:clock, Map.fetch!(dmap, cd.name)}}

          :reset ->
            cd =
              Enum.find(
                mod.domains,
                &((&1.reset && &1.reset_port) and port_name(&1.reset) == p.name)
              )

            pd = domain!(current!(), Map.fetch!(dmap, cd.name))

            if pd.reset == nil,
              do:
                raise(
                  ElaborationError,
                  "instance #{name}: #{mod.name} domain #{cd.name} needs a reset, parent domain #{pd.name} has none"
                )

            {p.name, {:reset, pd.name, pd.reset_active != cd.reset_active}}

          :data ->
            kind = if p.dir == :input, do: :inst_in, else: :inst_out
            dom = map_port_domain(p.domain, dmap)
            wire = :"#{name}_#{p.name}"
            add_signal(wire, p.type, kind, %{domain: dom, inst: {name, p.name}})
            {p.name, {:wire, wire}}
        end
      end)

    inout_types = Map.new(inout_ports, &{&1.name, &1.type})
    {inout_conns, connect} = Keyword.split(Keyword.get(opts, :connect, []), Map.keys(inout_types))

    inouts =
      Enum.map(inout_ports, fn p ->
        {p.name, inout_conn(b, name, p, Keyword.get(inout_conns, p.name))}
      end)

    inst = %{
      name: name,
      module: mod,
      params: params,
      conns: conns,
      domains: dmap,
      inouts: inouts
    }

    b = update(&%{&1 | instances: &1.instances ++ [inst]})

    handles =
      for {port, {:wire, w}} <- conns, into: %{__instance__: name}, do: {port, handle(b, w)}

    for {port, v} <- connect do
      case handles do
        %{^port => h} -> assign(h, v)
        _ -> raise ElaborationError, "instance #{name}: #{mod.name} has no data port #{port}"
      end
    end

    Enum.reduce(mod.bundles, handles, fn bundle, acc ->
      fields = Map.new(bundle.iface.fields, fn {f, _, _} -> {f, acc[:"#{bundle.name}_#{f}"]} end)
      Map.put(acc, bundle.name, Map.put(fields, :__bundle__, bundle.iface))
    end)
  end

  def instance(_name, other, _opts),
    do: raise(ElaborationError, "instance expects an ExHdl.RTL.Module, got #{inspect(other)}")

  defp inout_conn(_b, _inst, _p, nil), do: nil

  defp inout_conn(b, inst, p, %Expr{op: :sig, args: [n, owner]}) when owner == b.owner do
    case b.signals[n] do
      %{kind: :inout, type: t} when t == p.type ->
        n

      %{kind: :inout, type: t} ->
        raise ElaborationError,
              "instance #{inst}: inout #{p.name} is #{Expr.fmt(p.type)}, #{n} is #{Expr.fmt(t)}"

      _ ->
        raise ElaborationError,
              "instance #{inst}: inout #{p.name} connects to an inout port of #{b.name}, " <>
                "#{n} is not one"
    end
  end

  defp inout_conn(b, inst, p, other),
    do:
      raise(
        ElaborationError,
        "instance #{inst}: inout #{p.name} connects to an inout port of #{b.name}, " <>
          "got #{inspect(other)}"
      )

  defp port_name(%Expr{args: [n | _]}), do: n

  defp map_port_domain(d, _dmap) when d in [:async, :static, nil], do: d
  defp map_port_domain(d, dmap), do: Map.fetch!(dmap, d)

  defp domain_map(b, inst, mod, explicit) do
    Map.new(mod.domains, fn cd ->
      pd =
        cond do
          Keyword.has_key?(explicit, cd.name) ->
            Keyword.fetch!(explicit, cd.name)

          Enum.any?(b.domains, &(&1.name == cd.name)) ->
            cd.name

          length(mod.domains) == 1 ->
            ensure_domain()

          true ->
            raise ElaborationError,
                  "instance #{inst}: map domain #{cd.name} of #{mod.name} with domains: [#{cd.name}: parent_domain]"
        end

      domain!(current!(), pd)
      {cd.name, pd}
    end)
  end

  # -- memories --------------------------------------------------------------------------

  def memory(name, opts) do
    name = name!(name)
    b = current!()
    width = Keyword.fetch!(opts, :width)
    depth = Keyword.fetch!(opts, :depth)
    style = Keyword.get(opts, :style, :auto)
    byte = Keyword.get(opts, :byte, 8)

    unless is_integer(width) and width >= 1,
      do: raise(ElaborationError, "memory #{name}: width must be a positive integer")

    unless is_integer(depth) and depth >= 2,
      do: raise(ElaborationError, "memory #{name}: depth must be at least 2")

    unless style in [:auto, :block, :ultra, :distributed, :registers],
      do:
        raise(
          ElaborationError,
          "memory #{name}: style must be :auto, :block, :ultra, :distributed or :registers"
        )

    if Map.has_key?(b.signals, name) or Enum.any?(b.memories, &(&1.name == name)),
      do: raise(ElaborationError, "#{b.name}: #{name} is declared twice")

    init = init!(name, Keyword.get(opts, :init), width, depth)

    mem = %Memory{
      name: name,
      width: width,
      depth: depth,
      addr_width: max(ceil_log2(depth), 1),
      init: init,
      style: style,
      byte: byte
    }

    put(%{b | memories: b.memories ++ [mem]})
    mem
  end

  defp init!(_, nil, _, _), do: nil

  defp init!(name, init, width, depth) do
    map =
      cond do
        is_list(init) -> init |> Enum.with_index() |> Map.new(fn {v, i} -> {i, v} end)
        is_map(init) -> init
        true -> raise ElaborationError, "memory #{name}: init must be a list or %{addr => value}"
      end

    for {a, v} <- map do
      unless is_integer(a) and a in 0..(depth - 1),
        do: raise(ElaborationError, "memory #{name}: init address #{inspect(a)} out of range")

      unless is_integer(v) and v in Expr.range({:u, width}),
        do:
          raise(
            ElaborationError,
            "memory #{name}: init value #{inspect(v)} does not fit u#{width}"
          )
    end

    map
  end

  def ceil_log2(n) when n <= 1, do: 0
  def ceil_log2(n), do: length(Integer.digits(n - 1, 2))

  defp mem!(%Memory{name: name}) do
    b = current!()

    Enum.find(b.memories, &(&1.name == name)) ||
      raise(ElaborationError, "memory #{name} belongs to another module")
  end

  defp put_mem(mem),
    do:
      update(fn b ->
        %{b | memories: Enum.map(b.memories, &if(&1.name == mem.name, do: mem, else: &1))}
      end)

  def read_port(%Memory{} = m, opts) do
    m = mem!(m)
    i = length(m.read_ports)
    kind = Keyword.get(opts, :kind, :sync)
    addr = Expr.coerce!(Keyword.fetch!(opts, :addr), {:u, m.addr_width}, "#{m.name} read address")
    data = Keyword.get(opts, :name, :"#{m.name}_rd#{i}")

    case kind do
      :sync ->
        dom = resolve_domain(opts[:domain]).name
        en = Expr.coerce!(Keyword.get(opts, :en, 1), {:u, 1}, "#{m.name} read enable")
        e = add_signal(data, m.width, :mem_data, %{domain: dom})

        put_mem(%{
          m
          | read_ports:
              m.read_ports ++ [%{kind: :sync, domain: dom, addr: addr, en: en, data: data}]
        })

        e

      :async ->
        e = add_signal(data, m.width, :mem_async, %{})
        read = %Expr{op: :mem_read, args: [m.name, addr], type: {:u, m.width}}
        update(&%{&1 | blocks: &1.blocks ++ [{:comb, [{:assign, data, read}]}]})
        put_mem(%{m | read_ports: m.read_ports ++ [%{kind: :async, addr: addr, data: data}]})
        e

      other ->
        raise ElaborationError,
              "memory #{m.name}: read port kind must be :sync or :async, got #{inspect(other)}"
    end
  end

  def write_port(%Memory{} = m, opts) do
    m = mem!(m)
    dom = resolve_domain(opts[:domain]).name

    addr =
      Expr.coerce!(Keyword.fetch!(opts, :addr), {:u, m.addr_width}, "#{m.name} write address")

    data = Expr.coerce!(Keyword.fetch!(opts, :data), {:u, m.width}, "#{m.name} write data")
    en = Expr.coerce!(Keyword.get(opts, :en, 1), {:u, 1}, "#{m.name} write enable")

    be =
      case Keyword.get(opts, :be) do
        nil ->
          nil

        be ->
          if rem(m.width, m.byte) != 0,
            do:
              raise(
                ElaborationError,
                "memory #{m.name}: width #{m.width} is not a multiple of byte: #{m.byte}"
              )

          Expr.coerce!(be, {:u, div(m.width, m.byte)}, "#{m.name} byte enable")
      end

    put_mem(%{
      m
      | write_ports: m.write_ports ++ [%{domain: dom, addr: addr, data: data, en: en, be: be}]
    })

    nil
  end

  # -- bundles and FSMs ------------------------------------------------------------------

  def add_bundle(bundle), do: update(&%{&1 | bundles: &1.bundles ++ [bundle]})

  def add_fsm(fsm), do: update(&%{&1 | fsms: &1.fsms ++ [fsm]})

  def push_fsm(f), do: update(&%{&1 | fsm_stack: [f | &1.fsm_stack]})
  def pop_fsm, do: update(fn %{fsm_stack: [_ | r]} = b -> %{b | fsm_stack: r} end)

  def current_fsm do
    case current!().fsm_stack do
      [f | _] -> f
      [] -> raise ElaborationError, "goto/1 and state/3 are only valid inside fsm/3"
    end
  end

  def update_fsm(f), do: update(fn %{fsm_stack: [_ | r]} = b -> %{b | fsm_stack: [f | r]} end)

  # `in_state(:fsm, :state)` before `fsm :fsm` exists: a 1-bit wire that the
  # FSM drives once it is declared.
  def fsm_forward(fsm, state) do
    b = current!()

    case b.fsm_forwards do
      %{{^fsm, ^state} => name} ->
        handle(b, name)

      _ ->
        name = name!(:"#{fsm}_in_#{state}")
        w = wire(name, 1, [])
        update(&%{&1 | fsm_forwards: Map.put(&1.fsm_forwards, {fsm, state}, name)})
        w
    end
  end

  def take_fsm_forwards(fsm) do
    b = current!()
    {mine, rest} = Enum.split_with(b.fsm_forwards, fn {{f, _}, _} -> f == fsm end)
    put(%{b | fsm_forwards: Map.new(rest)})
    for {{_, state}, name} <- mine, do: {state, handle(b, name)}
  end

  defp forwards_resolved!(b) do
    case Enum.sort(Map.keys(b.fsm_forwards)) do
      [] ->
        :ok

      [{fsm, state} | _] ->
        raise ElaborationError,
              "#{b.name}: in_state(#{inspect(fsm)}, #{inspect(state)}) refers to an fsm " <>
                "#{fsm} that is never declared"
    end
  end
end
