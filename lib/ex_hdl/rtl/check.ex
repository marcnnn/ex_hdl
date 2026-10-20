defmodule ExHdl.RTL.Check do
  @moduledoc false
  # Turns builder state into a checked ExHdl.RTL.Module: drivers, latches,
  # combinational loops, clock domains, combinational port paths.

  alias ExHdl.RTL.{DomainError, ElaborationError, Expr, Module, Stmt}

  @comb_kinds [:output, :wire, :inst_in, :clock_int, :reset_int, :mem_async]

  def finalize(b) do
    check_owners!(b)
    b = strip_owners(b)
    clock_of = Map.new(b.domains, &{&1.name, clock_key(&1)})
    b = resolve_port_domains(b, clock_of)

    if b.kind == :black_box, do: black_box(b), else: rtl_module(b, clock_of)
  end

  defp clock_key(d), do: {:clk, hd(d.clock.args)}

  # -- ownership -------------------------------------------------------------------------

  defp all_exprs(b) do
    block_exprs =
      Enum.flat_map(b.blocks, fn
        {:comb, s} -> Stmt.exprs(s)
        {:sync, _, s} -> Stmt.exprs(s)
      end)

    mem_exprs =
      Enum.flat_map(b.memories, fn m ->
        Enum.flat_map(m.read_ports ++ m.write_ports, fn p ->
          [p[:addr], p[:en], p[:data], p[:be]] |> Enum.filter(&match?(%Expr{}, &1))
        end)
      end)

    block_exprs ++ mem_exprs
  end

  defp check_owners!(b) do
    for e <- all_exprs(b), {name, owner} <- Expr.owners(e), owner != b.owner do
      raise ElaborationError,
            "#{b.name}: signal #{name} of another module is used here; " <>
              "connect modules through instance ports"
    end
  end

  defp strip_owners(b) do
    f = &strip/1

    blocks =
      Enum.map(b.blocks, fn
        {:comb, s} -> {:comb, Stmt.map_exprs(s, f)}
        {:sync, d, s} -> {:sync, d, Stmt.map_exprs(s, f)}
      end)

    mems =
      Enum.map(b.memories, fn m ->
        sp = fn p -> Map.new(p, fn {k, v} -> {k, strip_any(v)} end) end
        %{m | read_ports: Enum.map(m.read_ports, sp), write_ports: Enum.map(m.write_ports, sp)}
      end)

    domains =
      Enum.map(b.domains, fn d ->
        %{d | clock: strip(d.clock), reset: d.reset && strip(d.reset)}
      end)

    fsms = Enum.map(b.fsms, fn f -> %{f | state: strip(f.state)} end)
    %{b | blocks: blocks, memories: mems, domains: domains, fsms: fsms}
  end

  defp strip_any(%Expr{} = e), do: strip(e)
  defp strip_any(v), do: v

  @doc false
  def strip(%Expr{op: :sig, args: [n, _]} = e), do: %{e | args: [n, nil]}
  def strip(%Expr{args: args} = e), do: %{e | args: Enum.map(args, &strip_arg/1)}

  defp strip_arg(%Expr{} = e), do: strip(e)
  defp strip_arg(l) when is_list(l), do: Enum.map(l, &strip_arg/1)
  defp strip_arg(v), do: v

  # -- port domains ----------------------------------------------------------------------

  defp resolve_port_domains(b, clock_of) do
    groups = clock_of |> Map.values() |> Enum.uniq()

    default =
      case groups do
        [] -> nil
        [_] -> hd(b.domains).name
        _ -> :ambiguous
      end

    signals =
      Map.new(b.signals, fn
        {n, %{kind: :input, domain: nil} = s} ->
          if default == :ambiguous,
            do:
              raise(
                DomainError,
                "#{b.name}: input #{n} needs domain: (#{Enum.map_join(b.domains, ", ", & &1.name)}, :async or :static)"
              )

          {n, %{s | domain: default}}

        {n, %{kind: k, domain: d} = s}
        when k in [:input, :output] and d not in [nil, :async, :static] ->
          unless Map.has_key?(clock_of, d),
            do: raise(DomainError, "#{b.name}: #{n} declares unknown domain #{inspect(d)}")

          {n, s}

        other ->
          other
      end)

    %{b | signals: signals}
  end

  # -- black boxes -----------------------------------------------------------------------

  defp black_box(b) do
    ports = Enum.map(b.ports, fn p -> %{p | domain: b.signals[p.name].domain} end)
    inputs = for p <- ports, p.dir == :input, p.role == :data, do: p.name

    comb_paths =
      for p <- ports, p.dir == :output, into: %{} do
        case p.comb_from do
          :all -> {p.name, inputs}
          :none -> {p.name, []}
          list when is_list(list) -> {p.name, list}
        end
      end

    %Module{
      name: b.name,
      kind: :black_box,
      ports: Enum.map(ports, &Map.delete(&1, :comb_from)),
      signals: b.signals,
      decls: b.decls,
      domains: b.domains,
      default_domain: default_domain(b),
      params: Keyword.get(b.opts, :params, []),
      sources: Keyword.get(b.opts, :sources, %{}),
      sim_sources: Keyword.get(b.opts, :sim_sources, %{}),
      clock_outputs: b.clock_outputs,
      model: Keyword.get(b.opts, :model),
      comb_paths: comb_paths,
      bundles: b.bundles
    }
  end

  defp default_domain(b), do: (hd(b.domains ++ [nil]) || %{name: nil}).name

  # -- modules ---------------------------------------------------------------------------

  defp rtl_module(b, clock_of) do
    comb_blocks = for {:comb, s} <- b.blocks, do: s
    sync_blocks = for {:sync, d, s} <- b.blocks, do: {d, s}

    procs = comb_procs!(b, comb_blocks)
    sync_targets = sync_blocks |> Enum.flat_map(fn {_, s} -> Stmt.targets(s) end) |> MapSet.new()
    check_reads!(b, comb_blocks ++ Enum.map(sync_blocks, &elem(&1, 1)))
    undriven!(b, procs, sync_targets)

    inst_of = Map.new(b.instances, &{&1.name, &1})
    order = topo!(b, procs, inst_of)
    proc_map = Map.new(procs)

    {doms, paths} = analyze(b, order, proc_map, inst_of, clock_of)
    check_sync_domains!(b, sync_blocks, doms, clock_of)
    check_memories!(b, doms, clock_of)
    check_instances!(b, doms, inst_of, clock_of)

    ports =
      Enum.map(b.ports, fn p ->
        p = Map.delete(p, :comb_from)

        if p.dir == :output,
          do: %{p | domain: output_domain!(b, p, doms, clock_of)},
          else: %{p | domain: b.signals[p.name].domain}
      end)

    signals =
      Enum.reduce(ports, b.signals, fn p, acc ->
        Map.update!(acc, p.name, &%{&1 | domain: p.domain})
      end)

    comb_paths =
      for p <- ports, p.dir == :output, into: %{} do
        {p.name, paths |> Map.get(p.name, MapSet.new()) |> Enum.sort()}
      end

    sync =
      sync_blocks
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> then(fn g ->
        b.domains
        |> Enum.filter(&Map.has_key?(g, &1.name))
        |> Enum.map(&{&1.name, Enum.concat(g[&1.name])})
      end)

    %Module{
      name: b.name,
      kind: :module,
      ports: ports,
      signals: signals,
      decls: b.decls,
      domains: b.domains,
      default_domain: default_domain(b),
      comb: Enum.flat_map(order, fn n -> if p = proc_map[n], do: [{n, p}], else: [] end),
      sync: sync,
      instances: b.instances,
      memories: b.memories,
      bundles: b.bundles,
      fsms: b.fsms,
      comb_paths: comb_paths,
      attrs: Keyword.get(b.opts, :attrs, [])
    }
  end

  defp comb_procs!(b, blocks) do
    {procs, _} =
      Enum.reduce(blocks, {[], %{}}, fn stmts, {procs, seen} ->
        Enum.reduce(Stmt.targets(stmts), {procs, seen}, fn t, {procs, seen} ->
          if Map.has_key?(seen, t),
            do:
              raise(
                ElaborationError,
                "#{b.name}: #{t} is driven from more than one comb block or assignment"
              )

          slice = Stmt.slice(stmts, MapSet.new([t]))

          unless Stmt.covers?(slice, t),
            do:
              raise(
                ElaborationError,
                "#{b.name}: #{t} is not assigned on every path of its comb block (latch); " <>
                  "assign a default value first"
              )

          if t in Stmt.reads(slice),
            do: raise(ElaborationError, "#{b.name}: combinational loop, #{t} depends on itself")

          {[{t, slice} | procs], Map.put(seen, t, true)}
        end)
      end)

    Enum.reverse(procs)
  end

  defp check_reads!(b, stmt_lists) do
    for stmts <- stmt_lists, n <- Stmt.reads(stmts), b.signals[n].kind in [:clock, :clock_int] do
      raise ElaborationError, "#{b.name}: clock #{n} used as data"
    end

    for e <- all_exprs(b), n <- Expr.reads(e), b.signals[n].kind == :inout do
      raise ElaborationError,
            "#{b.name}: inout #{n} is read by logic; inouts only connect to inout ports of " <>
              "instances (drive and sample the pad through an IOBUF black box)"
    end

    :ok
  end

  defp undriven!(b, procs, sync_targets) do
    driven = MapSet.new(procs, &elem(&1, 0))

    for n <- b.decls, s = b.signals[n] do
      cond do
        s.kind in @comb_kinds and not MapSet.member?(driven, n) ->
          what =
            case s.kind do
              :inst_in ->
                "input #{elem(s.inst, 1)} of instance #{elem(s.inst, 0)} is not connected"

              :output ->
                "output #{n} is never driven"

              :clock_int ->
                "internal clock #{n} is never driven"

              :reset_int ->
                "internal reset #{n} is never driven"

              _ ->
                "wire #{n} is never driven"
            end

          raise ElaborationError, "#{b.name}: #{what}"

        s.kind == :reg and s.reset == nil and not MapSet.member?(sync_targets, n) ->
          raise ElaborationError, "#{b.name}: register #{n} has no reset and is never assigned"

        true ->
          :ok
      end
    end
  end

  # Topological order of comb targets and instance outputs.
  defp topo!(b, procs, inst_of) do
    proc_map = Map.new(procs)

    inst_out =
      for {n, %{kind: :inst_out, inst: {i, port}}} <- b.signals, into: %{} do
        inst = inst_of[i]
        ins = Map.get(inst.module.comb_paths, port, [])
        {n, Enum.map(ins, &:"#{i}_#{&1}")}
      end

    nodes = Map.keys(proc_map) ++ Map.keys(inst_out)
    node_set = MapSet.new(nodes)

    deps =
      Map.new(nodes, fn n ->
        ds = if p = proc_map[n], do: Stmt.reads(p), else: inst_out[n]
        {n, Enum.filter(ds, &MapSet.member?(node_set, &1))}
      end)

    kahn(b, deps, Enum.filter(b.decls, &MapSet.member?(node_set, &1)))
  end

  defp kahn(b, deps, decl_order) do
    {order, _} =
      Enum.reduce_while(Stream.cycle([:x]), {[], MapSet.new()}, fn _, {order, done} ->
        ready =
          Enum.filter(
            decl_order,
            &(not MapSet.member?(done, &1) and
                Enum.all?(deps[&1], fn d -> MapSet.member?(done, d) end))
          )

        cond do
          ready == [] and MapSet.size(done) == length(decl_order) ->
            {:halt, {Enum.reverse(order), done}}

          ready == [] ->
            left = Enum.reject(decl_order, &MapSet.member?(done, &1))

            raise ElaborationError,
                  "#{b.name}: combinational loop through #{Enum.join(cycle(deps, left), " -> ")}"

          true ->
            {:cont, {Enum.reverse(ready) ++ order, Enum.into(ready, done)}}
        end
      end)

    order
  end

  defp cycle(deps, [start | _] = left) do
    left = MapSet.new(left)
    walk(deps, start, left, [start])
  end

  defp walk(deps, n, left, path) do
    next = Enum.find(deps[n], &MapSet.member?(left, &1))

    if next in path do
      [next | Enum.take_while(path, &(&1 != next))] |> Enum.reverse() |> then(&(&1 ++ [hd(&1)]))
    else
      walk(deps, next, left, [next | path])
    end
  end

  # -- domains and combinational paths ---------------------------------------------------

  # Domain set of a signal: %{key => witness}, key {:clk, clock} or :async.
  defp analyze(b, order, proc_map, inst_of, clock_of) do
    base = fn n, doms, paths ->
      s = b.signals[n]

      case s.kind do
        :input ->
          {port_dom(s.domain, clock_of, n), MapSet.new([n])}

        k when k in [:reg, :mem_data] ->
          {%{clock_of[s.domain] => n}, MapSet.new()}

        :reset ->
          d = Enum.find(b.domains, &(&1.reset && hd(&1.reset.args) == n))

          {if(d.reset_kind == :async, do: %{async: n}, else: %{clock_of[d.name] => n}),
           MapSet.new()}

        _ ->
          {Map.fetch!(doms, n), Map.fetch!(paths, n)}
      end
    end

    Enum.reduce(order, {%{}, %{}}, fn n, {doms, paths} ->
      s = b.signals[n]

      {dom, path} =
        case proc_map[n] do
          nil ->
            # instance output
            {i, port} = s.inst
            inst = inst_of[i]
            child = Module.port(inst.module, port)
            ins = Enum.map(Map.get(inst.module.comb_paths, port, []), &:"#{i}_#{&1}")
            own = port_dom(map_dom(child.domain, inst), clock_of, n)

            Enum.reduce(ins, {own, MapSet.new()}, fn w, {d, p} ->
              {wd, wp} = base.(w, doms, paths)
              {Map.merge(wd, d), MapSet.union(p, wp)}
            end)

          stmts ->
            Enum.reduce(Stmt.reads(stmts), {%{}, MapSet.new()}, fn r, {d, p} ->
              {rd, rp} = base.(r, doms, paths)
              {Map.merge(rd, d), MapSet.union(p, rp)}
            end)
        end

      mixed!(b, n, dom, clock_of)
      {Map.put(doms, n, dom), Map.put(paths, n, path)}
    end)
    |> then(fn {doms, paths} ->
      # inputs and registers for later lookups
      extra =
        for {n, s} <- b.signals, s.kind in [:input, :reg, :mem_data, :reset], into: %{} do
          {n, elem(base.(n, doms, paths), 0)}
        end

      {Map.merge(extra, doms), paths}
    end)
  end

  defp map_dom(d, _inst) when d in [:async, :static, nil], do: d
  defp map_dom(d, inst), do: Map.fetch!(inst.domains, d)

  defp port_dom(d, _clock_of, _n) when d in [:static, nil], do: %{}
  defp port_dom(:async, _clock_of, n), do: %{async: n}
  defp port_dom(d, clock_of, n), do: %{Map.fetch!(clock_of, d) => n}

  defp mixed!(b, n, dom, clock_of) do
    if map_size(dom) > 1 do
      desc = Enum.map_join(dom, " and ", fn {k, w} -> "#{w} (#{key_name(k, b, clock_of)})" end)

      raise DomainError,
            "#{b.name}: #{n} combines #{desc} combinationally; " <>
              "cross clock domains through an ExHdl.RTL.CDC cell"
    end
  end

  defp key_name(:async, _b, _), do: "asynchronous"

  defp key_name(k, _b, clock_of) do
    names = for {d, ^k} <- clock_of, do: d
    "domain #{Enum.join(Enum.sort(names), "/")}"
  end

  defp dom_of(doms, n), do: Map.get(doms, n, %{})

  defp reads_dom(stmts_or_exprs, doms) do
    stmts_or_exprs
    |> Enum.flat_map(fn
      %Expr{} = e -> Expr.reads(e)
      stmts when is_list(stmts) -> Stmt.reads(stmts)
    end)
    |> Enum.reduce(%{}, fn r, acc -> Map.merge(dom_of(doms, r), acc) end)
  end

  defp check_sync_domains!(b, sync_blocks, doms, clock_of) do
    for {d, stmts} <- sync_blocks, t <- Stmt.targets(stmts), not b.signals[t].attrs[:cdc] do
      key = clock_of[d]
      got = reads_dom([Stmt.slice(stmts, MapSet.new([t]))], doms)

      for {k, w} <- got, k != key do
        raise DomainError,
              "#{b.name}: register #{t} (domain #{d}) samples #{w} from #{key_name(k, b, clock_of)}; " <>
                "cross clock domains through an ExHdl.RTL.CDC cell"
      end
    end

    :ok
  end

  defp check_memories!(b, doms, clock_of) do
    for m <- b.memories, p <- m.read_ports ++ m.write_ports, p[:domain] do
      exprs = [p[:addr], p[:en], p[:data], p[:be]] |> Enum.filter(&match?(%Expr{}, &1))
      exprs = if Map.has_key?(p, :kind), do: [p.addr, p.en], else: exprs

      for {k, w} <- reads_dom(exprs, doms), k != clock_of[p.domain] do
        raise DomainError,
              "#{b.name}: memory #{m.name} port in domain #{p.domain} uses #{w} from #{key_name(k, b, clock_of)}"
      end
    end

    :ok
  end

  defp check_instances!(b, doms, inst_of, clock_of) do
    for {n, %{kind: :inst_in, inst: {i, port}}} <- b.signals do
      inst = inst_of[i]

      case Module.port(inst.module, port).domain do
        d when d in [:async, :static, nil] ->
          :ok

        d ->
          pd = inst.domains[d]

          for {k, w} <- dom_of(doms, n), k != clock_of[pd] do
            raise DomainError,
                  "#{b.name}: input #{port} of instance #{i} is in domain #{pd}, driven from #{w} " <>
                    "(#{key_name(k, b, clock_of)}); cross clock domains through an ExHdl.RTL.CDC cell"
          end
      end
    end

    :ok
  end

  defp output_domain!(b, p, doms, clock_of) do
    s = b.signals[p.name]
    got = if s.kind == :reg, do: %{clock_of[s.domain] => p.name}, else: dom_of(doms, p.name)

    case s.domain do
      d when d in [:async, :static] ->
        d

      nil ->
        case Map.keys(got) do
          [] -> nil
          [:async] -> :async
          [k] -> domain_for(b, k, clock_of)
        end

      d ->
        for {k, w} <- got, k != clock_of[d] do
          raise DomainError,
                "#{b.name}: output #{p.name} is declared in domain #{d}, driven from #{w} (#{key_name(k, b, clock_of)})"
        end

        d
    end
  end

  # The default domain if it has this clock, else the first such domain.
  defp domain_for(b, key, clock_of) do
    Enum.find_value(b.domains, fn d -> if clock_of[d.name] == key, do: d.name end)
  end
end
