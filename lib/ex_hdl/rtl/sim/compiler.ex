defmodule ExHdl.RTL.Sim.Compiler do
  @moduledoc false
  # Compiled engine of ExHdl.RTL.Sim: generates a BEAM module from the
  # flattened design (ExHdl.RTL.Sim.Flat) and loads it.
  #
  # State is a tuple of groups:
  #   {inputs_and_constants, clock_group_1, ..., clock_group_k, memories, models}
  # Every register and synchronous read port belongs to the group of its
  # clock; memories are maps addr => word; models hold their states.
  # Combinational values are a tuple of chunk tuples, computed by
  # settle/1; each chunk is one generated function over at most a few
  # thousand operations, so the Erlang compiler stays fast.
  #
  # Expressions become integer code with widths folded into constant
  # masks, comparisons stay booleans where they are used as conditions,
  # muxes and switches only evaluate the selected operand, and
  # sub-expressions used more than once in a function are computed once
  # (designs built by generator code share sub-trees heavily).
  #
  # Generated modules are named by a hash of their code and kept loaded,
  # so building a simulator for the same design twice compiles once.

  import Bitwise

  alias ExHdl.RTL.{Expr, Stmt}
  alias ExHdl.RTL.Sim.{Flat, Runtime}

  defstruct [:mod, :home, :clock_bit, :async_resets, :init, :mem_slot, :ngroups]

  @l 1
  @chunk_weight 300
  @chunk_nodes 120
  @sync_part 12
  @funs_per_module 4

  # -- engine API ----------------------------------------------------------------------------

  def build(%Flat{} = flat) do
    {virt, units} = share(flat)
    layout = layout(flat, virt, units)
    mod = flat |> forms(layout) |> load()

    async =
      for r <- flat.async_resets do
        %{
          reset: Map.fetch!(layout.home, r.reset),
          level: r.level,
          regs: for({id, v} <- r.regs, do: {Map.fetch!(layout.home, id), v})
        }
      end

    %__MODULE__{
      mod: mod,
      home: layout.home,
      clock_bit: layout.clock_bit,
      async_resets: async,
      init: layout.init,
      mem_slot: layout.mem_slot,
      ngroups: layout.ngroups
    }
  end

  def init(%__MODULE__{init: s}), do: {s, nil}

  def settle(%__MODULE__{} = p, {s, _}) do
    c = p.mod.settle(s)
    if p.async_resets == [], do: {s, c}, else: async_resets(p, s, c, 10)
  end

  defp async_resets(_p, _s, _c, 0), do: raise(ArgumentError, "asynchronous resets do not settle")

  defp async_resets(p, s, c, budget) do
    forced =
      Enum.reduce(p.async_resets, s, fn r, s2 ->
        if read(r.reset, s, c) == r.level,
          do: Enum.reduce(r.regs, s2, fn {h, v}, s3 -> write(h, s3, v) end),
          else: s2
      end)

    if forced == s, do: {s, c}, else: async_resets(p, forced, p.mod.settle(forced), budget - 1)
  end

  def get(%__MODULE__{home: home}, {s, c}, id), do: read(Map.fetch!(home, id), s, c)

  def has?(%__MODULE__{home: home}, _st, id), do: Map.has_key?(home, id)

  def put(%__MODULE__{home: home}, {s, _}, id, v), do: {write(Map.fetch!(home, id), s, v), nil}

  def mem_get(%__MODULE__{mem_slot: slots, ngroups: g}, {s, _}, key, addr) do
    s |> elem(g) |> elem(Map.fetch!(slots, key)) |> Map.get(addr, 0)
  end

  def edge(%__MODULE__{} = p, {s, c}, fire) do
    mask = Enum.reduce(fire, 0, fn cid, m -> m ||| Map.get(p.clock_bit, cid, 0) end)
    {p.mod.edge(s, c, mask), nil}
  end

  defp read({:s, g, i}, s, _c), do: s |> elem(g) |> elem(i)
  defp read({:c, k, i}, _s, c), do: c |> elem(k) |> elem(i)

  defp write({:s, g, i}, s, v), do: put_elem(s, g, put_elem(elem(s, g), i, v))

  # -- layout --------------------------------------------------------------------------------

  # -- sharing -------------------------------------------------------------------------------

  # Every sub-expression used more than once anywhere in the design becomes
  # a virtual combinational signal {:v, n}, computed once per settle.
  # Returns the map {prefix, expr} => vid and all combinational units
  # (Flat nodes and virtual nodes) in evaluation order.
  defp share(flat) do
    roots =
      Enum.flat_map(flat.nodes, fn
        %{ir: {:comb, _, stmts, p}} -> Enum.map(Stmt.exprs(stmts), &{&1, p})
        _ -> []
      end) ++
        Enum.flat_map(flat.sync, fn g -> Enum.map(Stmt.exprs(g.stmts), &{&1, g.prefix}) end) ++
        Enum.flat_map(flat.mem_reads, fn r -> [{r.addr, r.prefix}, {r.en, r.prefix}] end) ++
        Enum.flat_map(flat.mem_writes, fn w ->
          [{w.addr, w.prefix}, {w.data, w.prefix}, {w.en, w.prefix}] ++
            if(w.be, do: [{w.be, w.prefix}], else: [])
        end)

    refs = Enum.reduce(roots, %{}, fn {e, p}, acc -> count(e, p, acc) end)

    virt =
      refs
      |> Enum.filter(fn {_, n} -> n >= 2 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.with_index()
      |> Map.new(fn {k, i} -> {k, {:v, i}} end)

    vnodes =
      for {{p, e} = k, vid} <- virt do
        deps = e.args |> sub_exprs() |> Enum.reduce([], &inline_refs(&1, p, virt, &2))
        %{outs: [vid], deps: deps, ir: {:virtual, vid, e, p}, key: k}
      end

    nodes =
      Enum.map(flat.nodes, fn
        %{ir: {:comb, _, stmts, p}} = n ->
          vids =
            stmts
            |> Stmt.exprs()
            |> Enum.reduce([], &inline_refs(&1, p, virt, &2))
            |> Enum.filter(&match?({:v, _}, &1))

          %{n | deps: n.deps ++ vids}

        n ->
          n
      end)

    {virt, topo(nodes ++ vnodes)}
  end

  defp count(%Expr{op: op}, _p, acc) when op in [:sig, :const], do: acc

  defp count(%Expr{args: args} = e, p, acc) do
    k = {p, e}

    case acc do
      %{^k => n} -> Map.put(acc, k, n + 1)
      _ -> Enum.reduce(sub_exprs(args), Map.put(acc, k, 1), &count(&1, p, &2))
    end
  end

  # signals and virtual signals read by the inline code of e
  defp inline_refs(%Expr{op: :sig, args: [n | _]}, p, _virt, acc), do: [Flat.id(p, n) | acc]
  defp inline_refs(%Expr{op: :const}, _p, _virt, acc), do: acc

  defp inline_refs(%Expr{args: args} = e, p, virt, acc) do
    case virt do
      %{{^p, ^e} => vid} -> [vid | acc]
      _ -> args |> sub_exprs() |> Enum.reduce(acc, &inline_refs(&1, p, virt, &2))
    end
  end

  # operations in the inline code of e (up to shared sub-expressions)
  defp inline_weight(%Expr{op: op}, _p, _virt, acc) when op in [:sig, :const], do: acc

  defp inline_weight(%Expr{args: args} = e, p, virt, acc) do
    if Map.has_key?(virt, {p, e}),
      do: acc + 1,
      else: args |> sub_exprs() |> Enum.reduce(acc + 1, &inline_weight(&1, p, virt, &2))
  end

  defp topo(nodes) do
    indexed = nodes |> Enum.with_index() |> Map.new(fn {n, i} -> {i, n} end)
    producer = for {i, n} <- indexed, o <- n.outs, into: %{}, do: {o, i}

    deps =
      Map.new(indexed, fn {i, n} ->
        {i, n.deps |> Enum.flat_map(&List.wrap(producer[&1])) |> Enum.uniq() |> List.delete(i)}
      end)

    {order, _} =
      Enum.reduce(0..(map_size(indexed) - 1)//1, {[], %{}}, fn i, acc -> visit(i, deps, acc) end)

    order |> Enum.reverse() |> Enum.map(&indexed[&1])
  end

  defp visit(i, deps, {order, marks}) do
    case marks do
      %{^i => :done} ->
        {order, marks}

      %{^i => :active} ->
        raise "ExHdl.RTL.Sim: combinational cycle in the compiled schedule"

      _ ->
        {order, marks} =
          Enum.reduce(deps[i], {order, Map.put(marks, i, :active)}, &visit(&1, deps, &2))

        {[i | order], Map.put(marks, i, :done)}
    end
  end

  # -- layout --------------------------------------------------------------------------------

  defp layout(flat, virt, units) do
    comb_ids = for n <- flat.nodes, o <- n.outs, into: MapSet.new(), do: o

    # clock of every register and sync read data
    reg_clock =
      Enum.reduce(flat.sync, %{}, fn g, acc ->
        ids =
          Enum.map(Stmt.targets(g.stmts), &Flat.id(g.prefix, &1)) ++
            Enum.map(g.resets, &elem(&1, 0))

        Enum.reduce(ids, acc, &Map.put(&2, &1, g.clock))
      end)

    reg_clock = Enum.reduce(flat.mem_reads, reg_clock, &Map.put(&2, &1.data, &1.clock))

    used_clocks =
      Enum.map(flat.sync, & &1.clock) ++
        Enum.map(flat.mem_reads, & &1.clock) ++
        Enum.map(flat.mem_writes, & &1.clock) ++
        Enum.flat_map(flat.models, fn m -> Enum.map(m.clocks, &elem(&1, 0)) end)

    clocks = Enum.uniq(flat.clocks ++ Enum.sort(Enum.uniq(used_clocks) -- flat.clocks))
    clock_bit = clocks |> Enum.with_index() |> Map.new(fn {c, i} -> {c, 1 <<< i} end)
    clock_group = clocks |> Enum.with_index(1) |> Map.new()
    ngroups = length(clocks) + 1

    # state slots: group 0 inputs, constants and undriven signals; one group per clock
    ids = flat.sigs |> Map.keys() |> Enum.sort()

    {slots, _} =
      Enum.reduce(ids, {%{}, %{}}, fn id, {slots, next} ->
        cond do
          MapSet.member?(comb_ids, id) ->
            {slots, next}

          true ->
            g = if c = reg_clock[id], do: clock_group[c], else: 0
            i = Map.get(next, g, 0)
            {Map.put(slots, id, {:s, g, i}), Map.put(next, g, i + 1)}
        end
      end)

    group_ids =
      Enum.reduce(slots, %{}, fn {id, {:s, g, i}}, acc ->
        Map.update(acc, g, [{i, id}], &[{i, id} | &1])
      end)
      |> Map.new(fn {g, l} -> {g, l |> Enum.sort() |> Enum.map(&elem(&1, 1))} end)

    mems = flat.mems |> Map.values() |> Enum.sort_by(& &1.key)
    mem_slot = mems |> Enum.with_index() |> Map.new(fn {m, i} -> {m.key, i} end)
    model_slot = flat.models |> Enum.with_index() |> Map.new(fn {m, i} -> {m.key, i} end)

    chunks = chunk(units, virt)

    comb_home =
      for {nodes, k} <- Enum.with_index(chunks),
          {o, i} <- nodes |> Enum.flat_map(& &1.outs) |> Enum.with_index(),
          into: %{},
          do: {o, {:c, k, i}}

    init_groups =
      for g <- 0..(ngroups - 1) do
        group_ids |> Map.get(g, []) |> Enum.map(fn _ -> 0 end) |> List.to_tuple()
      end

    init =
      List.to_tuple(
        init_groups ++
          [
            mems |> Enum.map(& &1.init) |> List.to_tuple(),
            flat.models |> Enum.map(& &1.init) |> List.to_tuple()
          ]
      )

    %{
      home: Map.merge(slots, comb_home),
      clock_bit: clock_bit,
      clock_group: clock_group,
      clocks: clocks,
      group_ids: group_ids,
      ngroups: ngroups,
      mem_slot: mem_slot,
      model_slot: model_slot,
      chunks: chunks,
      virt: virt,
      init: init
    }
  end

  # Splits the ordered units into chunks of bounded size.
  defp chunk(units, virt) do
    {chunks, cur, _} =
      Enum.reduce(units, {[], [], 0}, fn n, {chunks, cur, w} ->
        nw = unit_weight(n, virt)

        if cur != [] and (w + nw > @chunk_weight or length(cur) >= @chunk_nodes),
          do: {[Enum.reverse(cur) | chunks], [n], nw},
          else: {chunks, [n | cur], w + nw}
      end)

    chunks = if cur == [], do: chunks, else: [Enum.reverse(cur) | chunks]
    Enum.reverse(chunks)
  end

  defp unit_weight(%{ir: {:comb, _, stmts, p}}, virt),
    do: stmts |> Stmt.exprs() |> Enum.reduce(1, &inline_weight(&1, p, virt, &2))

  defp unit_weight(%{ir: {:virtual, _, e, p}}, virt),
    do: e.args |> sub_exprs() |> Enum.reduce(1, &inline_weight(&1, p, virt, &2))

  defp unit_weight(%{ir: {:model, _, _, ins, outs}}, _), do: length(ins) + length(outs) + 4
  defp unit_weight(_, _), do: 1

  defp sub_exprs(args) do
    Enum.flat_map(args, fn
      %Expr{} = e -> [e]
      l when is_list(l) -> sub_exprs(l)
      _ -> []
    end)
  end

  # -- loading -------------------------------------------------------------------------------

  # The generated functions are spread over several modules compiled in
  # parallel; settle/1 and edge/3 live in the main module, which is loaded
  # last (its presence means the design is loaded).
  defp load([{:attribute, _, :export, exports} | funs]) do
    hash =
      funs
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    name = :"Elixir.ExHdl.RTL.Sim.Compiled.M#{hash}"

    unless :erlang.module_loaded(name) do
      :global.trans({__MODULE__, name}, fn ->
        unless :erlang.module_loaded(name), do: compile_and_load(name, exports, funs)
      end)
    end

    name
  end

  defp compile_and_load(name, exports, funs) do
    {main, rest} = Enum.split_with(funs, fn {:function, _, f, a, _} -> {f, a} in exports end)

    nparts =
      rest |> length() |> div(@funs_per_module) |> max(1) |> min(System.schedulers_online())

    parts =
      rest
      |> Enum.sort_by(fn f -> -:erlang.external_size(f) end)
      |> Enum.with_index()
      |> Enum.group_by(fn {_, i} -> rem(i, nparts) end, &elem(&1, 0))
      |> Enum.map(fn {i, fs} -> {:"#{name}.P#{i}", fs} end)

    home = for {m, fs} <- parts, {:function, _, f, a, _} <- fs, into: %{}, do: {{f, a}, m}

    modules =
      [{name, exports, main} | Enum.map(parts, fn {m, fs} -> {m, Enum.map(fs, &fa/1), fs} end)]
      |> Enum.map(fn {m, exp, fs} ->
        {m,
         [
           {:attribute, @l, :module, m},
           {:attribute, @l, :export, exp} | remote_calls(fs, home, m)
         ]}
      end)

    binaries =
      modules
      |> Task.async_stream(
        fn {m, forms} ->
          case :compile.forms(forms, [:binary, :return_errors, :no_line_info]) do
            {:ok, ^m, bin} ->
              {m, bin}

            {:error, errors, _} ->
              raise "ExHdl.RTL.Sim: generated code does not compile: #{inspect(errors, limit: 20)}"
          end
        end,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.map(fn {:ok, r} -> r end)

    # parts first, the main module last
    for {m, bin} <- Enum.reverse(binaries),
        do: {:module, ^m} = :code.load_binary(m, ~c"ex_hdl_sim", bin)
  end

  defp fa({:function, _, f, a, _}), do: {f, a}

  # local calls to functions in other modules become remote calls
  defp remote_calls({:call, l, {:atom, la, f}, args} = c, home, self) do
    args = remote_calls(args, home, self)
    n = length(args)

    case home do
      %{{^f, ^n} => m} when m != self ->
        {:call, l, {:remote, l, {:atom, la, m}, {:atom, la, f}}, args}

      _ ->
        put_elem(c, 3, args)
    end
  end

  defp remote_calls(t, home, self) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.map(&remote_calls(&1, home, self)) |> List.to_tuple()

  defp remote_calls(l, home, self) when is_list(l), do: Enum.map(l, &remote_calls(&1, home, self))
  defp remote_calls(x, _home, _self), do: x

  # -- code generation -----------------------------------------------------------------------

  defp forms(flat, lay) do
    nchunks = length(lay.chunks)

    {chunk_funs, chunk_args} =
      lay.chunks
      |> Enum.with_index()
      |> Enum.map(fn {nodes, k} -> chunk_fun(nodes, k, lay) end)
      |> Enum.unzip()

    settle_body =
      Enum.map(Enum.with_index(chunk_args), fn {used, k} ->
        match(cvar(k), lcall(:"c#{k}", [var(:S) | Enum.map(used, &cvar/1)]))
      end) ++ [tuple(Enum.map(0..(nchunks - 1)//1, &cvar/1))]

    settle = fun(:settle, [var(:S)], settle_body)

    {edge, edge_funs} = edge_funs(flat, lay)

    exports = [{:settle, 1}, {:edge, 3}]
    funs = [settle, edge] ++ chunk_funs ++ edge_funs
    [{:attribute, @l, :export, exports} | funs]
  end

  defp fun(name, args, body),
    do: {:function, @l, name, length(args), [{:clause, @l, args, [], body}]}

  # One chunk of combinational nodes: c<k>(S, C<j>...) -> {outs...}
  defp chunk_fun(nodes, k, lay) do
    ctx = new_ctx(lay, {:chunk, k})

    ctx =
      Enum.reduce(nodes, ctx, fn n, ctx -> comb_node(n.ir, ctx) end)

    outs = Enum.flat_map(nodes, & &1.outs)
    ret = tuple(Enum.map(outs, &Map.fetch!(ctx.local, &1)))
    used = ctx.chunks_used |> MapSet.to_list() |> Enum.sort()
    body = group_binds(ctx) ++ Enum.reverse(ctx.binds) ++ [ret]
    {fun(:"c#{k}", [var(:S) | Enum.map(used, &cvar/1)], body), used}
  end

  defp comb_node({:comb, tid, [{:assign, tid, e}], p}, ctx) do
    {a, ctx} = ex(e, p, ctx)
    bind_local(ctx, tid, a)
  end

  defp comb_node({:comb, tid, stmts, p}, ctx) do
    {exprs, env, ctx} = stmts(stmts, p, %{}, :comb, ctx)
    ctx = %{ctx | binds: Enum.reverse(exprs) ++ ctx.binds}
    bind_local(ctx, tid, Map.get(env, tid, int(0)))
  end

  defp comb_node({:virtual, vid, e, p}, ctx) do
    {a, ctx} = gen(e, p, natural(e), ctx)
    bind_local(ctx, vid, a)
  end

  defp comb_node({:alias, src, dst, invert}, ctx) do
    {a, ctx} = read_sig(src, ctx)
    bind_local(ctx, dst, if(invert, do: op(:-, int(1), a), else: a))
  end

  defp comb_node({:model, key, model, inputs, outputs}, ctx) do
    {st, ctx} = model_state(key, ctx)

    # outputs depend only on their comb_from inputs; inputs computed later in
    # the settle order read 0 here
    {fields, ctx} =
      Enum.map_reduce(inputs, ctx, fn {port, id}, ctx ->
        {a, ctx} = if available?(id, ctx), do: read_sig(id, ctx), else: {int(0), ctx}
        {{:map_field_assoc, @l, atom(port), a}, ctx}
      end)

    {t, ctx} = fresh(ctx)

    call =
      rcall(Runtime, :model_outputs, [
        atom(model),
        st,
        {:map, @l, fields},
        :erl_parse.abstract(outputs)
      ])

    ctx = emit(ctx, match(t, call))

    outputs
    |> Enum.with_index(1)
    |> Enum.reduce(ctx, fn {{_, id, _}, i}, ctx ->
      bind_local(ctx, id, call(:element, [int(i), t]))
    end)
  end

  defp available?(id, ctx) do
    case {Map.fetch!(ctx.lay.home, id), ctx.scope} do
      {{:s, _, _}, _} -> true
      {{:c, k, _}, {:chunk, j}} -> k < j or Map.has_key?(ctx.local, id)
    end
  end

  defp bind_local(ctx, id, a) do
    {v, ctx} = fresh(ctx)
    ctx = emit(ctx, match(v, a))
    %{ctx | local: Map.put(ctx.local, id, v)}
  end

  # edge(S, C, Mask) -> S' and the per-clock next-state, write and model functions
  defp edge_funs(flat, lay) do
    s = var(:S)
    c = var(:C)
    mask = var(:Mask)

    per_clock =
      for {cid, g} <- Enum.sort_by(lay.clock_group, &elem(&1, 1)) do
        groups = Enum.filter(flat.sync, &(&1.clock == cid))
        reads = Enum.filter(flat.mem_reads, &(&1.clock == cid))
        writes = Enum.filter(flat.mem_writes, &(&1.clock == cid))
        models = for m <- flat.models, {^cid, d} <- m.clocks, do: {m, d}
        {cid, g, groups, reads, writes, models}
      end

    fire = fn cid -> op(:"=/=", op(:band, mask, int(lay.clock_bit[cid])), int(0)) end
    mem_pos = lay.ngroups
    model_pos = lay.ngroups + 1

    {body, funs} =
      Enum.reduce(per_clock, {[], []}, fn {cid, g, groups, reads, writes, models}, {body, funs} ->
        ids = Map.get(lay.group_ids, g, [])

        {body, funs} =
          if ids == [] do
            {body, funs}
          else
            fs = next_funs(g, groups, reads, ids, lay)
            gv = var(:"G#{g}")

            stmt =
              match(
                gv,
                case_(fire.(cid), [
                  clause([atom(true)], [], [lcall(:"n#{g}", [s, c])]),
                  clause([atom(false)], [], [call(:element, [int(g + 1), s])])
                ])
              )

            {[stmt | body], Enum.reverse(fs) ++ funs}
          end

        {body, funs} =
          if writes == [] do
            {body, funs}
          else
            f = writes_fun(:"w#{g}", writes, lay)
            {[{:w, g, cid} | body], [f | funs]}
          end

        if models == [] do
          {body, funs}
        else
          f = models_fun(:"m#{g}", models, lay)
          {[{:m, g, cid} | body], [f | funs]}
        end
      end)

    body = Enum.reverse(body)
    group_stmts = Enum.filter(body, &match?({:match, _, _, _}, &1))

    seq = fn tag, pos, v0 ->
      steps = for {^tag, g, cid} <- body, do: {g, cid}

      {stmts, last} =
        Enum.reduce(steps, {[], v0}, fn {g, cid}, {stmts, prev} ->
          nv = var(:"#{String.upcase(to_string(tag))}X#{g}")

          st =
            match(
              nv,
              case_(fire.(cid), [
                clause([atom(true)], [], [lcall(:"#{tag}#{g}", [s, c, prev])]),
                clause([atom(false)], [], [prev])
              ])
            )

          {[st | stmts], nv}
        end)

      {[match(v0, call(:element, [int(pos + 1), s])) | Enum.reverse(stmts)], last}
    end

    {mem_stmts, mem_last} = seq.(:w, mem_pos, var(:M0))
    {model_stmts, model_last} = seq.(:m, model_pos, var(:D0))

    groups =
      for g <- 0..(lay.ngroups - 1) do
        gname = :"G#{g}"

        if Enum.any?(group_stmts, &match?({:match, _, {:var, _, ^gname}, _}, &1)),
          do: var(:"G#{g}"),
          else: call(:element, [int(g + 1), s])
      end

    ret = tuple(groups ++ [mem_last, model_last])
    edge = fun(:edge, [s, c, mask], group_stmts ++ mem_stmts ++ model_stmts ++ [ret])
    {edge, Enum.reverse(funs)}
  end

  # n<g>(S, C) -> new tuple of clock group g, from part functions n<g>_<j>
  # that each compute a few registers (slices of the sync statements) or
  # synchronous read ports
  defp next_funs(g, groups, reads, ids, lay) do
    parts =
      Enum.flat_map(groups, fn grp ->
        names = Stmt.targets(grp.stmts)

        reset_only =
          for {id, _} <- grp.resets,
              not Enum.any?(names, &(Flat.id(grp.prefix, &1) == id)),
              do: id

        sliced =
          names
          |> Enum.chunk_every(@sync_part)
          |> Enum.map(fn chunk ->
            keep = MapSet.new(chunk)
            {:regs, grp, Stmt.slice(grp.stmts, keep), Enum.map(chunk, &Flat.id(grp.prefix, &1))}
          end)

        held = if reset_only == [], do: [], else: [{:regs, grp, [], reset_only}]
        sliced ++ held
      end) ++ Enum.map(Enum.chunk_every(reads, @sync_part), &{:reads, &1})

    {funs, produced} =
      parts
      |> Enum.with_index()
      |> Enum.map(fn {part, j} ->
        name = :"n#{g}_#{j}"
        {f, outs} = part_fun(name, part, lay)
        {f, Enum.map(Enum.with_index(outs, 1), fn {id, i} -> {id, {j, i}} end)}
      end)
      |> Enum.unzip()

    produced = produced |> List.flatten() |> Map.new()

    calls =
      for j <- 0..(length(parts) - 1)//1,
          do: match(var(:"T#{j}"), lcall(:"n#{g}_#{j}", [var(:S), var(:C)]))

    elems =
      ids
      |> Enum.with_index(1)
      |> Enum.map(fn {id, i} ->
        case produced do
          %{^id => {j, k}} -> call(:element, [int(k), var(:"T#{j}")])
          _ -> call(:element, [int(i), group_var(g)])
        end
      end)

    body = [match(group_var(g), call(:element, [int(g + 1), var(:S)])) | calls] ++ [tuple(elems)]
    [fun(:"n#{g}", [var(:S), var(:C)], body) | funs]
  end

  defp part_fun(name, {:regs, grp, stmts, ids}, lay) do
    ctx = new_ctx(lay, :edge)
    {exprs, env, ctx} = stmts(stmts, grp.prefix, %{}, :sync, ctx)
    ctx = %{ctx | binds: Enum.reverse(exprs) ++ ctx.binds}

    {vals, ctx} = Enum.map_reduce(ids, ctx, fn id, ctx -> env_get(env, id, :sync, ctx) end)
    resets = Map.new(grp.resets)

    {vals, ctx} =
      case grp.reset do
        {rst, level} ->
          if Enum.any?(ids, &Map.has_key?(resets, &1)) do
            {r, ctx} = read_sig(rst, ctx)
            {rv, ctx} = fresh(ctx)
            ctx = emit(ctx, match(rv, op(:"=:=", r, int(level))))

            vals =
              ids
              |> Enum.zip(vals)
              |> Enum.map(fn {id, cur} ->
                case resets do
                  %{^id => v} ->
                    case_(rv, [
                      clause([atom(true)], [], [int(v)]),
                      clause([atom(false)], [], [cur])
                    ])

                  _ ->
                    cur
                end
              end)

            {vals, ctx}
          else
            {vals, ctx}
          end

        nil ->
          {vals, ctx}
      end

    body = group_binds(ctx) ++ Enum.reverse(ctx.binds) ++ [tuple(vals)]
    {fun(name, [var(:S), var(:C)], body), ids}
  end

  defp part_fun(name, {:reads, reads}, lay) do
    ctx = new_ctx(lay, :edge)

    {vals, ctx} =
      Enum.map_reduce(reads, ctx, fn r, ctx ->
        {en, ctx} = bx(r.en, r.prefix, ctx)
        {addr, ctx} = ex(r.addr, r.prefix, ctx)
        {mem, ctx} = mem_words(r.key, ctx)
        {old, ctx} = read_sig(r.data, ctx)

        a =
          case_(en, [
            clause([atom(true)], [], [rcall(:maps, :get, [addr, mem, int(0)])]),
            clause([atom(false)], [], [old])
          ])

        {a, ctx}
      end)

    body = group_binds(ctx) ++ Enum.reverse(ctx.binds) ++ [tuple(vals)]
    {fun(name, [var(:S), var(:C)], body), Enum.map(reads, & &1.data)}
  end

  # w<g>(S, C, M) -> M with the writes of clock group g applied
  defp writes_fun(name, writes, lay) do
    ctx = new_ctx(lay, :edge)

    {last, ctx} =
      Enum.reduce(writes, {var(:M), ctx}, fn w, {m, ctx} ->
        slot = Map.fetch!(lay.mem_slot, w.key) + 1
        {en, ctx} = bx(w.en, w.prefix, ctx)
        {addr, ctx} = ex(w.addr, w.prefix, ctx)
        {data, ctx} = ex(w.data, w.prefix, ctx)

        {mask, ctx} =
          case w.be do
            nil ->
              {int((1 <<< w.width) - 1), ctx}

            be ->
              {b, ctx} = ex(be, w.prefix, ctx)
              {rcall(Runtime, :byte_mask, [b, int(div(w.width, w.byte)), int(w.byte)]), ctx}
          end

        write =
          call(:setelement, [
            int(slot),
            m,
            rcall(Runtime, :mem_write, [
              call(:element, [int(slot), m]),
              addr,
              data,
              mask,
              int(w.depth)
            ])
          ])

        {nm, ctx} = fresh(ctx)

        ctx =
          emit(
            ctx,
            match(
              nm,
              case_(en, [clause([atom(true)], [], [write]), clause([atom(false)], [], [m])])
            )
          )

        {nm, ctx}
      end)

    body = group_binds(ctx) ++ Enum.reverse(ctx.binds) ++ [last]
    fun(name, [var(:S), var(:C), var(:M)], body)
  end

  # m<g>(S, C, D) -> D with the models of clock group g clocked
  defp models_fun(name, models, lay) do
    ctx = new_ctx(lay, :edge)

    {last, ctx} =
      Enum.reduce(models, {var(:D), ctx}, fn {m, dom}, {d, ctx} ->
        slot = Map.fetch!(lay.model_slot, m.key) + 1

        {fields, ctx} =
          Enum.map_reduce(m.inputs, ctx, fn {port, id}, ctx ->
            {a, ctx} = read_sig(id, ctx)
            {{:map_field_assoc, @l, atom(port), a}, ctx}
          end)

        clocked =
          {:call, @l, {:remote, @l, atom(m.model), atom(:clock)},
           [atom(dom), call(:element, [int(slot), d]), {:map, @l, fields}]}

        {nd, ctx} = fresh(ctx)
        ctx = emit(ctx, match(nd, call(:setelement, [int(slot), d, clocked])))
        {nd, ctx}
      end)

    body = group_binds(ctx) ++ Enum.reverse(ctx.binds) ++ [last]
    fun(name, [var(:S), var(:C), var(:D)], body)
  end

  # -- statements ----------------------------------------------------------------------------

  # Returns {exprs (in order), env, ctx}; env maps target ids to value ASTs.
  defp stmts(list, p, env, mode, ctx) do
    {rev, env, ctx} =
      Enum.reduce(list, {[], env, ctx}, fn s, {acc, env, ctx} ->
        {exprs, env, ctx} = stmt(s, p, env, mode, ctx)
        {Enum.reverse(exprs) ++ acc, env, ctx}
      end)

    {Enum.reverse(rev), env, ctx}
  end

  defp stmt({:assign, t, e}, p, env, _mode, ctx) do
    {a, ctx} = ex(e, p, ctx)
    {v, ctx} = fresh(ctx)
    {[match(v, a)], Map.put(env, Flat.id(p, t), v), ctx}
  end

  defp stmt({:if, c, a, b}, p, env, mode, ctx) do
    targets = Enum.map(Stmt.targets(a ++ b), &Flat.id(p, &1))

    if targets == [] do
      {[], env, ctx}
    else
      {cond, ctx} = bx(c, p, ctx)
      {ca, ctx} = branch(a, p, env, targets, mode, ctx)
      {cb, ctx} = branch(b, p, env, targets, mode, ctx)

      join(
        case_(cond, [clause([atom(true)], [], ca), clause([atom(false)], [], cb)]),
        targets,
        env,
        ctx
      )
    end
  end

  defp stmt({:switch, subj, cases, default}, p, env, mode, ctx) do
    all = Enum.flat_map(cases, &elem(&1, 1)) ++ (default || [])
    targets = Enum.map(Stmt.targets(all), &Flat.id(p, &1))

    if targets == [] do
      {[], env, ctx}
    else
      {s, ctx} = ex(subj, p, ctx)
      {sv, ctx} = fresh(ctx)

      {clauses, ctx} =
        Enum.map_reduce(cases, ctx, fn {values, body}, ctx ->
          {cb, ctx} = branch(body, p, env, targets, mode, ctx)
          ints = Enum.map(values, &hd(&1.args))

          clause =
            case ints do
              [v] ->
                clause([int(v)], [], cb)

              vs ->
                clause([sv], Enum.map(vs, &[op(:"=:=", sv, int(&1))]), cb)
            end

          {clause, ctx}
        end)

      {cd, ctx} = branch(default || [], p, env, targets, mode, ctx)
      clauses = clauses ++ [clause([{:var, @l, :_}], [], cd)]
      join(case_(s, clauses), targets, env, ctx)
    end
  end

  defp branch(stmts, p, env, targets, mode, ctx) do
    {exprs, env2, ctx} = stmts(stmts, p, env, mode, ctx)

    {vals, ctx} =
      Enum.map_reduce(targets, ctx, fn t, ctx -> env_get(env2, t, mode, ctx) end)

    ret =
      case vals do
        [v] -> v
        vs -> tuple(vs)
      end

    {exprs ++ [ret], ctx}
  end

  defp join(case_expr, targets, env, ctx) do
    {vars, ctx} = Enum.map_reduce(targets, ctx, fn _, ctx -> fresh(ctx) end)

    pat =
      case vars do
        [v] -> v
        vs -> tuple(vs)
      end

    env = targets |> Enum.zip(vars) |> Enum.reduce(env, fn {t, v}, env -> Map.put(env, t, v) end)
    {[match(pat, case_expr)], env, ctx}
  end

  # value of a target before any assignment: registers hold, comb targets are
  # assigned on every path (0 is never used)
  defp env_get(env, id, mode, ctx) do
    case env do
      %{^id => v} -> {v, ctx}
      _ when mode == :sync -> read_sig(id, ctx)
      _ -> {int(0), ctx}
    end
  end

  # -- expressions ---------------------------------------------------------------------------

  defp new_ctx(lay, scope) do
    %{
      n: 0,
      binds: [],
      local: %{},
      lay: lay,
      scope: scope,
      chunks_used: MapSet.new(),
      groups_used: MapSet.new(),
      reads: %{}
    }
  end

  defp fresh(ctx), do: {var(:"V#{ctx.n}"), %{ctx | n: ctx.n + 1}}
  defp emit(ctx, e), do: %{ctx | binds: [e | ctx.binds]}

  defp group_var(g), do: var(:"S#{g}")
  defp use_group(ctx, g), do: %{ctx | groups_used: MapSet.put(ctx.groups_used, g)}

  defp group_binds(ctx) do
    for g <- ctx.groups_used |> MapSet.to_list() |> Enum.sort(),
        do: match(group_var(g), call(:element, [int(g + 1), var(:S)]))
  end

  # Signal read, bound once per function.
  defp read_sig(id, ctx) do
    case ctx do
      %{local: %{^id => v}} ->
        {v, ctx}

      %{reads: %{^id => v}} ->
        {v, ctx}

      _ ->
        {a, ctx} =
          case Map.fetch!(ctx.lay.home, id) do
            {:s, g, i} ->
              {call(:element, [int(i + 1), group_var(g)]), use_group(ctx, g)}

            {:c, k, i} ->
              case ctx.scope do
                {:chunk, ^k} ->
                  raise "ExHdl.RTL.Sim: #{inspect(id)} read before it is computed"

                {:chunk, _} ->
                  {call(:element, [int(i + 1), cvar(k)]),
                   %{ctx | chunks_used: MapSet.put(ctx.chunks_used, k)}}

                :edge ->
                  {call(:element, [int(i + 1), call(:element, [int(k + 1), var(:C)])]), ctx}
              end
          end

        {v, ctx} = fresh(ctx)
        ctx = emit(ctx, match(v, a))
        {v, %{ctx | reads: Map.put(ctx.reads, id, v)}}
    end
  end

  defp mem_words(key, ctx) do
    rk = {:mem, key}

    case ctx.reads do
      %{^rk => v} ->
        {v, ctx}

      _ ->
        slot = Map.fetch!(ctx.lay.mem_slot, key)
        g = ctx.lay.ngroups
        {v, ctx} = fresh(ctx)
        ctx = emit(ctx, match(v, call(:element, [int(slot + 1), group_var(g)])))
        {v, %{use_group(ctx, g) | reads: Map.put(ctx.reads, rk, v)}}
    end
  end

  defp model_state(key, ctx) do
    slot = Map.fetch!(ctx.lay.model_slot, key)
    g = ctx.lay.ngroups + 1
    {call(:element, [int(slot + 1), group_var(g)]), use_group(ctx, g)}
  end

  @bool_ops [:eq, :ne, :lt, :le, :gt, :ge, :land, :lor, :lnot, :reduce_and, :reduce_or]

  defp natural(%Expr{op: op}) when op in @bool_ops, do: :bool
  defp natural(_), do: :int

  # integer-valued code
  defp ex(%Expr{op: :sig, args: [n | _]}, p, ctx), do: read_sig(Flat.id(p, n), ctx)
  defp ex(%Expr{op: :const, args: [v | _]}, _p, ctx), do: {int(v), ctx}
  defp ex(e, p, ctx), do: shared(e, p, :int, ctx)

  # boolean-valued code for u1 expressions
  defp bx(%Expr{op: :const, args: [v | _]}, _p, ctx), do: {atom(v == 1), ctx}

  defp bx(%Expr{op: :sig} = e, p, ctx) do
    {a, ctx} = ex(e, p, ctx)
    {op(:"=:=", a, int(1)), ctx}
  end

  defp bx(e, p, ctx), do: shared(e, p, :bool, ctx)

  defp shared(e, p, mode, ctx) do
    case ctx.lay.virt do
      %{{^p, ^e} => vid} ->
        {v, ctx} = read_sig(vid, ctx)
        {convert(v, natural(e), mode), ctx}

      _ ->
        gen(e, p, mode, ctx)
    end
  end

  defp convert(a, same, same), do: a
  defp convert(a, :bool, :int), do: b2i(a)
  defp convert(a, :int, :bool), do: op(:"=:=", a, int(1))

  defp b2i(b),
    do: case_(b, [clause([atom(true)], [], [int(1)]), clause([atom(false)], [], [int(0)])])

  # gen(e, p, mode, ctx): code for e in `mode`
  defp gen(%Expr{op: op, args: [a, b]}, p, mode, ctx)
       when op in [:eq, :ne, :lt, :le, :gt, :ge] do
    {x, ctx} = ex(a, p, ctx)
    {y, ctx} = ex(b, p, ctx)

    eop =
      case op do
        :eq -> :"=:="
        :ne -> :"=/="
        :lt -> :<
        :le -> :"=<"
        :gt -> :>
        :ge -> :>=
      end

    finish(op(eop, x, y), :bool, mode, ctx)
  end

  defp gen(%Expr{op: :land, args: [a, b]}, p, :bool, ctx) do
    {x, ctx} = bx(a, p, ctx)
    {y, ctx} = bx(b, p, ctx)
    {op(:andalso, x, y), ctx}
  end

  defp gen(%Expr{op: :lor, args: [a, b]}, p, :bool, ctx) do
    {x, ctx} = bx(a, p, ctx)
    {y, ctx} = bx(b, p, ctx)
    {op(:orelse, x, y), ctx}
  end

  defp gen(%Expr{op: o, args: [a, b]}, p, :int, ctx) when o in [:land, :lor] do
    {x, ctx} = ex(a, p, ctx)
    {y, ctx} = ex(b, p, ctx)
    {op(if(o == :land, do: :band, else: :bor), x, y), ctx}
  end

  defp gen(%Expr{op: :lnot, args: [a]}, p, :bool, ctx) do
    {x, ctx} = bx(a, p, ctx)
    {{:op, @l, :not, x}, ctx}
  end

  defp gen(%Expr{op: :lnot, args: [a]}, p, :int, ctx) do
    {x, ctx} = ex(a, p, ctx)
    {op(:bxor, x, int(1)), ctx}
  end

  defp gen(%Expr{op: :reduce_and, args: [a]}, p, mode, ctx) do
    {x, ctx} = ex(a, p, ctx)
    all = if elem(a.type, 0) == :s, do: -1, else: mask(Expr.width(a))
    finish(op(:"=:=", x, int(all)), :bool, mode, ctx)
  end

  defp gen(%Expr{op: :reduce_or, args: [a]}, p, mode, ctx) do
    {x, ctx} = ex(a, p, ctx)
    finish(op(:"=/=", x, int(0)), :bool, mode, ctx)
  end

  defp gen(%Expr{op: :mux, args: [c, a, b]}, p, mode, ctx) do
    {cc, ctx} = bx(c, p, ctx)
    {x, ctx} = val(a, p, mode, ctx)
    {y, ctx} = val(b, p, mode, ctx)
    {case_(cc, [clause([atom(true)], [], [x]), clause([atom(false)], [], [y])]), ctx}
  end

  defp gen(%Expr{op: :muxn, args: [sel, items, d]}, p, mode, ctx) do
    {s, ctx} = ex(sel, p, ctx)

    if Enum.all?([d | items], &match?(%Expr{op: :const}, &1)) and mode == :int do
      table = tuple(Enum.map(items, &int(hd(&1.args))))
      {sv, ctx} = fresh(ctx)
      n = length(items)

      code =
        {:block, @l,
         [
           match(sv, s),
           case_(op(:<, sv, int(n)), [
             clause([atom(true)], [], [call(:element, [op(:+, sv, int(1)), table])]),
             clause([atom(false)], [], [int(hd(d.args))])
           ])
         ]}

      {code, ctx}
    else
      {clauses, ctx} =
        items
        |> Enum.with_index()
        |> Enum.map_reduce(ctx, fn {it, i}, ctx ->
          {x, ctx} = val(it, p, mode, ctx)
          {clause([int(i)], [], [x]), ctx}
        end)

      {y, ctx} = val(d, p, mode, ctx)
      {case_(s, clauses ++ [clause([{:var, @l, :_}], [], [y])]), ctx}
    end
  end

  defp gen(e, p, :bool, ctx) do
    {a, ctx} = gen(e, p, :int, ctx)
    {op(:"=:=", a, int(1)), ctx}
  end

  defp gen(%Expr{op: op, args: [a, b], type: t}, p, :int, ctx) when op in [:add, :sub, :mul] do
    {x, ctx} = ex(a, p, ctx)
    {y, ctx} = ex(b, p, ctx)
    eop = %{add: :+, sub: :-, mul: :*}[op]
    code = op(eop, x, y)
    {if(exact?(op, a, b, t), do: code, else: wrap(code, t)), ctx}
  end

  defp gen(%Expr{op: :neg, args: [a], type: t}, p, :int, ctx) do
    {x, ctx} = ex(a, p, ctx)
    code = {:op, @l, :-, x}
    exact = elem(t, 0) == :s and Expr.width(t) > Expr.width(a)
    {if(exact, do: code, else: wrap(code, t)), ctx}
  end

  defp gen(%Expr{op: op, args: [a, b], type: t}, p, :int, ctx) when op in [:and, :or, :xor] do
    {x, ctx} = ex(a, p, ctx)
    {y, ctx} = ex(b, p, ctx)
    code = op(%{and: :band, or: :bor, xor: :bxor}[op], x, y)
    {if(fits?([a, b], t), do: code, else: wrap(code, t)), ctx}
  end

  defp gen(%Expr{op: :not, args: [a], type: {:u, w} = t}, p, :int, ctx) do
    {x, ctx} = ex(a, p, ctx)
    {if(fits?([a], t), do: op(:bxor, x, int(mask(w))), else: wrap({:op, @l, :bnot, x}, t)), ctx}
  end

  defp gen(%Expr{op: :not, args: [a], type: t}, p, :int, ctx) do
    {x, ctx} = ex(a, p, ctx)
    code = {:op, @l, :bnot, x}
    {if(fits?([a], t), do: code, else: wrap(code, t)), ctx}
  end

  defp gen(%Expr{op: :reduce_xor, args: [a]}, p, :int, ctx) do
    {x, ctx} = ex(a, p, ctx)
    {rcall(Runtime, :parity, [raw(x, a.type)]), ctx}
  end

  defp gen(%Expr{op: :shl, args: [a, n], type: t}, p, :int, ctx) do
    {x, ctx} = ex(a, p, ctx)
    code = if n == 0, do: x, else: op(:bsl, x, int(n))
    exact = elem(t, 0) == elem(a.type, 0) and Expr.width(t) >= Expr.width(a) + n
    {if(exact, do: code, else: wrap(code, t)), ctx}
  end

  defp gen(%Expr{op: :shr, args: [a, n], type: t}, p, :int, ctx) do
    {x, ctx} = ex(a, p, ctx)
    code = if n == 0, do: x, else: op(:bsr, x, int(n))
    {if(fits?([a], t), do: code, else: wrap(code, t)), ctx}
  end

  defp gen(%Expr{op: :shl_dyn, args: [a, b], type: t}, p, :int, ctx) do
    {x, ctx} = ex(a, p, ctx)
    {y, ctx} = ex(b, p, ctx)
    code = op(:bsl, x, y)

    exact =
      elem(t, 0) == elem(a.type, 0) and elem(b.type, 0) == :u and
        Expr.width(t) >= Expr.width(a) + (1 <<< Expr.width(b)) - 1

    {if(exact, do: code, else: wrap(code, t)), ctx}
  end

  defp gen(%Expr{op: :shr_dyn, args: [a, b], type: t}, p, :int, ctx) do
    {x, ctx} = ex(a, p, ctx)
    {y, ctx} = ex(b, p, ctx)
    code = op(:bsr, x, y)
    {if(fits?([a], t) and elem(b.type, 0) == :u, do: code, else: wrap(code, t)), ctx}
  end

  defp gen(%Expr{op: :cat, args: [items]}, p, :int, ctx) do
    {parts, _, ctx} =
      items
      |> Enum.reverse()
      |> Enum.reduce({[], 0, ctx}, fn it, {parts, off, ctx} ->
        w = Expr.width(it)

        case it do
          %Expr{op: :const, args: [v | _]} ->
            r = Expr.raw(v, it.type) <<< off
            {if(r == 0, do: parts, else: [int(r) | parts]), off + w, ctx}

          _ ->
            {x, ctx} = ex(it, p, ctx)
            x = raw(x, it.type)
            {[if(off == 0, do: x, else: op(:bsl, x, int(off))) | parts], off + w, ctx}
        end
      end)

    code =
      case parts do
        [] -> int(0)
        [x | rest] -> Enum.reduce(rest, x, &op(:bor, &2, &1))
      end

    {code, ctx}
  end

  defp gen(%Expr{op: :rep, args: [a, n]}, p, :int, ctx) do
    {x, ctx} = ex(a, p, ctx)
    w = Expr.width(a)
    k = Enum.reduce(0..(n - 1)//1, 0, fn i, acc -> acc ||| 1 <<< (i * w) end)
    {op(:*, raw(x, a.type), int(k)), ctx}
  end

  defp gen(%Expr{op: :slice, args: [a, lo, w]}, p, :int, ctx) do
    {x, ctx} = ex(a, p, ctx)
    shifted = if lo == 0, do: x, else: op(:bsr, x, int(lo))
    top = lo + w == Expr.width(a) and elem(a.type, 0) == :u
    {if(top, do: shifted, else: op(:band, shifted, int(mask(w)))), ctx}
  end

  defp gen(%Expr{op: :index, args: [a, i]}, p, :int, ctx) do
    {x, ctx} = ex(a, p, ctx)
    {y, ctx} = ex(i, p, ctx)
    {iv, ctx} = fresh(ctx)

    code =
      {:block, @l,
       [
         match(iv, y),
         case_(op(:<, iv, int(Expr.width(a))), [
           clause([atom(true)], [], [op(:band, op(:bsr, x, iv), int(1))]),
           clause([atom(false)], [], [int(0)])
         ])
       ]}

    {code, ctx}
  end

  defp gen(%Expr{op: :resize, args: [a], type: t}, p, :int, ctx) do
    {x, ctx} = ex(a, p, ctx)
    {if(fits?([a], t), do: x, else: wrap(x, t)), ctx}
  end

  defp gen(%Expr{op: :cast, args: [a], type: t}, p, :int, ctx) do
    {x, ctx} = ex(a, p, ctx)

    code =
      case {a.type, t} do
        {{s, wa}, {s, wt}} when wt >= wa -> x
        {_, {:u, wt}} -> op(:band, x, int(mask(wt)))
        {{:u, wa}, {:s, wt}} when wt >= wa + 1 -> x
        {at, _} -> wrap(raw(x, at), t)
      end

    {code, ctx}
  end

  defp gen(%Expr{op: :mem_read, args: [mem, addr]}, p, :int, ctx) do
    {a, ctx} = ex(addr, p, ctx)
    {m, ctx} = mem_words({:mem, Flat.id(p, mem)}, ctx)
    {rcall(:maps, :get, [a, m, int(0)]), ctx}
  end

  # anything else through the reference evaluator
  defp gen(%Expr{args: args} = e, p, :int, ctx) do
    {vals, ctx} = Enum.map_reduce(sub_exprs(args), ctx, &ex(&1, p, &2))
    {rcall(Runtime, :eval, [:erl_parse.abstract(e), list(vals)]), ctx}
  end

  defp finish(code, nat, mode, ctx), do: {convert(code, nat, mode), ctx}

  defp val(e, p, :int, ctx), do: ex(e, p, ctx)
  defp val(e, p, :bool, ctx), do: bx(e, p, ctx)

  defp exact?(:add, a, b, {_, w}), do: w > max(Expr.width(a), Expr.width(b))
  defp exact?(:sub, a, b, {s, w}), do: s == :s and w > max(Expr.width(a), Expr.width(b))
  defp exact?(:mul, a, b, {_, w}), do: w >= Expr.width(a) + Expr.width(b)

  # operands of t's signedness and not wider: the result is in range
  defp fits?(args, {s, w}),
    do: Enum.all?(args, fn %Expr{type: {sa, wa}} -> sa == s and wa <= w end)

  defp mask(w), do: (1 <<< w) - 1

  defp raw(x, {:u, _}), do: x
  defp raw(x, {:s, w}), do: op(:band, x, int(mask(w)))

  defp wrap(x, {:u, w}), do: op(:band, x, int(mask(w)))

  defp wrap(x, {:s, w}) do
    half = 1 <<< (w - 1)
    op(:-, op(:band, op(:+, x, int(half)), int(mask(w))), int(half))
  end

  # -- abstract format helpers ---------------------------------------------------------------

  defp var(n), do: {:var, @l, n}
  defp cvar(k), do: var(:"C#{k}")
  defp int(n), do: :erl_parse.abstract(n)
  defp atom(a), do: {:atom, @l, a}
  defp tuple(es), do: {:tuple, @l, es}
  defp match(p, e), do: {:match, @l, p, e}
  defp op(o, a, b), do: {:op, @l, o, a, b}
  defp case_(e, clauses), do: {:case, @l, e, clauses}
  defp clause(pats, guards, body), do: {:clause, @l, pats, guards, body}
  defp call(f, args), do: rcall(:erlang, f, args)
  defp lcall(f, args), do: {:call, @l, atom(f), args}
  defp rcall(m, f, args), do: {:call, @l, {:remote, @l, atom(m), atom(f)}, args}

  defp list(items),
    do: List.foldr(items, {nil, @l}, fn x, acc -> {:cons, @l, x, acc} end)
end
