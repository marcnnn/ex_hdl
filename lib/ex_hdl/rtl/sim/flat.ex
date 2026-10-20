defmodule ExHdl.RTL.Sim.Flat do
  @moduledoc false
  # Flattens a module hierarchy into a symbolic description both simulator
  # engines read (ExHdl.RTL.Sim.Interp builds closures from it,
  # ExHdl.RTL.Sim.Compiler generates a BEAM module):
  #
  #   sigs         - id => %{type, kind}
  #   nodes        - combinational processes in evaluation order, each
  #                  %{outs, deps, ir} with ir one of
  #                    {:comb, target_id, stmts, prefix}
  #                    {:alias, src_id, dst_id, invert?}
  #                    {:model, state_key, model, inputs, outputs}
  #   sync         - register groups (one per domain of every module):
  #                  %{clock, reset: {id, level} | nil, resets: [{id, value}],
  #                    stmts, prefix}
  #   mems         - memory id => %{key, width, depth, init, byte}
  #   mem_writes   - %{clock, key, addr, data, en, be, width, byte, depth, prefix}
  #   mem_reads    - synchronous read ports %{clock, key, addr, en, data, prefix}
  #   models       - black-box model instances %{key, model, init, clocks, inputs}
  #   async_resets - %{reset, level, regs: [{id, value}]}
  #
  # Signal ids are hierarchical strings ("q", "u_cnt.count"); expressions
  # keep the names of their module and are resolved with `prefix`.

  alias ExHdl.RTL.{ElaborationError, Module, Stmt}

  defstruct sigs: %{},
            nodes: [],
            sync: [],
            mems: %{},
            mem_writes: [],
            mem_reads: [],
            models: [],
            async_resets: [],
            clocks: [],
            domain_clock: %{}

  def clock_ids(%Module{} = top), do: top |> clock_map() |> Map.values() |> Enum.uniq()

  def domain_clocks(%Module{} = top),
    do: Map.new(top.domains, &{&1.name, Atom.to_string(hd(&1.clock.args))})

  defp clock_map(top),
    do: for(d <- top.domains, into: %{}, do: {hd(d.clock.args), Atom.to_string(hd(d.clock.args))})

  def build(%Module{} = top) do
    clock_map = clock_map(top)

    acc = %{
      sigs: %{},
      nodes: [],
      sync: [],
      mems: %{},
      mem_writes: [],
      mem_reads: [],
      models: [],
      async_resets: []
    }

    acc = flatten(top, "", clock_map, [], acc)

    %__MODULE__{
      sigs: acc.sigs,
      nodes: order!(Enum.reverse(acc.nodes)),
      sync: Enum.reverse(acc.sync),
      mems: acc.mems,
      mem_writes: Enum.reverse(acc.mem_writes),
      mem_reads: Enum.reverse(acc.mem_reads),
      models: Enum.reverse(acc.models),
      async_resets: Enum.reverse(acc.async_resets),
      clocks: clock_map |> Map.values() |> Enum.uniq(),
      domain_clock: Map.new(top.domains, &{&1.name, clock_map[hd(&1.clock.args)]})
    }
  end

  @doc false
  def id(prefix, name), do: prefix <> Atom.to_string(name)

  # clocks: this module's clock signal name => top-level clock id
  # params: the instance's parameters (black boxes: defaults merged with the
  # instance's params:)
  defp flatten(%Module{kind: :black_box} = m, prefix, clocks, params, acc) do
    {model, config} =
      case m.model do
        nil ->
          raise ElaborationError,
                "black box #{m.name} (#{String.trim_trailing(prefix, ".")}) has no simulation model; " <>
                  "pass model: to black_box/3"

        {mod, config} when is_atom(mod) ->
          {mod, {:config, config}}

        mod when is_atom(mod) ->
          {mod, nil}
      end

    acc = add_port_sigs(m, prefix, acc)
    inputs = for p <- m.ports, p.dir == :input, p.role != :clock, do: {p.name, id(prefix, p.name)}
    outputs = for p <- m.ports, p.dir == :output, do: {p.name, id(prefix, p.name), p.type}
    state_key = {:model, prefix}

    deps =
      m.comb_paths |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.map(&id(prefix, &1))

    node = %{
      outs: Enum.map(outputs, &elem(&1, 1)),
      deps: deps,
      ir: {:model, state_key, model, inputs, outputs}
    }

    doms =
      for d <- m.domains, into: %{} do
        {Map.fetch!(clocks, hd(d.clock.args)), d.name}
      end

    params = if params == [], do: m.params, else: params

    entry = %{
      key: state_key,
      model: model,
      init:
        case config do
          {:config, c} -> model.init(params, c)
          nil -> model.init(params)
        end,
      clocks: doms,
      inputs: inputs
    }

    %{acc | nodes: [node | acc.nodes], models: [entry | acc.models]}
  end

  defp flatten(%Module{} = m, prefix, clocks, _params, acc) do
    acc = add_port_sigs(m, prefix, acc)

    acc =
      Enum.reduce(m.decls, acc, fn n, acc ->
        s = m.signals[n]
        if s.port, do: acc, else: put_sig(acc, id(prefix, n), s.type, s.kind)
      end)

    # combinational processes
    acc =
      Enum.reduce(m.comb, acc, fn {t, stmts}, acc ->
        tid = id(prefix, t)
        deps = stmts |> Stmt.reads() |> Enum.map(&id(prefix, &1))
        node = %{outs: [tid], deps: deps, ir: {:comb, tid, stmts, prefix}}
        %{acc | nodes: [node | acc.nodes]}
      end)

    # registers
    acc =
      Enum.reduce(m.domains, acc, fn d, acc ->
        cid = Map.fetch!(clocks, hd(d.clock.args))
        stmts = Keyword.get(m.sync, d.name, [])
        regs = for n <- m.decls, s = m.signals[n], s.kind == :reg, s.domain == d.name, do: s
        resets = for r <- regs, r.reset != nil, do: {id(prefix, r.name), r.reset}
        rst = d.reset && id(prefix, hd(d.reset.args))
        level = if d.reset_active == :low, do: 0, else: 1

        group = %{
          clock: cid,
          reset: rst && {rst, level},
          resets: resets,
          stmts: stmts,
          prefix: prefix
        }

        acc = %{acc | sync: [group | acc.sync]}

        if (d.reset_kind == :async and rst) && resets != [],
          do: %{
            acc
            | async_resets: [%{reset: rst, level: level, regs: resets} | acc.async_resets]
          },
          else: acc
      end)

    acc = Enum.reduce(m.memories, acc, &memory(&1, prefix, m, clocks, &2))
    Enum.reduce(m.instances, acc, &instance(&1, prefix, m, clocks, &2))
  end

  defp add_port_sigs(m, prefix, acc) do
    Enum.reduce(m.ports, acc, fn p, acc ->
      kind = if p.role == :data, do: p.dir, else: p.role
      put_sig(acc, id(prefix, p.name), p.type, kind)
    end)
  end

  defp put_sig(acc, id, type, kind),
    do: %{acc | sigs: Map.put(acc.sigs, id, %{type: type, kind: kind})}

  defp memory(mem, prefix, m, clocks, acc) do
    mid = id(prefix, mem.name)
    key = {:mem, mid}

    acc = %{
      acc
      | mems:
          Map.put(acc.mems, mid, %{
            key: key,
            width: mem.width,
            depth: mem.depth,
            init: mem.init || %{},
            byte: mem.byte
          })
    }

    clock = fn dom -> Map.fetch!(clocks, hd(Module.domain(m, dom).clock.args)) end

    acc =
      Enum.reduce(mem.write_ports, acc, fn p, acc ->
        w = %{
          clock: clock.(p.domain),
          key: key,
          addr: p.addr,
          data: p.data,
          en: p.en,
          be: p.be,
          width: mem.width,
          byte: mem.byte,
          depth: mem.depth,
          prefix: prefix
        }

        %{acc | mem_writes: [w | acc.mem_writes]}
      end)

    Enum.reduce(mem.read_ports, acc, fn
      %{kind: :async}, acc ->
        acc

      p, acc ->
        r = %{
          clock: clock.(p.domain),
          key: key,
          addr: p.addr,
          en: p.en,
          data: id(prefix, p.data),
          prefix: prefix
        }

        %{acc | mem_reads: [r | acc.mem_reads]}
    end)
  end

  defp instance(inst, prefix, m, clocks, acc) do
    child = inst.module
    cprefix = prefix <> "#{inst.name}."

    child_clocks =
      for {port, {:clock, pd}} <- inst.conns, into: %{} do
        {port, Map.fetch!(clocks, hd(Module.domain(m, pd).clock.args))}
      end

    # internal clocks of the child are driven by the simulator too
    child_clocks =
      Enum.reduce(child.domains, child_clocks, fn d, cc ->
        n = hd(d.clock.args)
        if d.clock_port, do: cc, else: Map.put(cc, n, cprefix <> Atom.to_string(n))
      end)

    acc =
      Enum.reduce(inst.conns, acc, fn
        {port, {:wire, w}}, acc ->
          p = Module.port(child, port)
          wid = id(prefix, w)
          pid = id(cprefix, port)
          {src, dst} = if p.dir == :input, do: {wid, pid}, else: {pid, wid}
          alias_node(acc, src, dst, false)

        {port, {:reset, pd, invert}}, acc ->
          rid = id(prefix, hd(Module.domain(m, pd).reset.args))
          alias_node(acc, rid, id(cprefix, port), invert)

        {_port, {:clock, _}}, acc ->
          acc
      end)

    flatten(child, cprefix, child_clocks, Map.get(inst, :params, []), acc)
  end

  defp alias_node(acc, src, dst, invert) do
    node = %{outs: [dst], deps: [src], ir: {:alias, src, dst, invert}}
    %{acc | nodes: [node | acc.nodes]}
  end

  # Orders nodes so every node runs after the nodes producing its inputs.
  defp order!(nodes) do
    producer = for {n, i} <- Enum.with_index(nodes), o <- n.outs, into: %{}, do: {o, i}
    indexed = nodes |> Enum.with_index() |> Map.new(fn {n, i} -> {i, n} end)

    deps =
      Map.new(indexed, fn {i, n} ->
        {i,
         n.deps
         |> Enum.flat_map(&List.wrap(producer[&1]))
         |> Enum.uniq()
         |> Enum.reject(&(&1 == i))}
      end)

    {order, _} = visit_all(Map.keys(indexed) |> Enum.sort(), deps, indexed)
    Enum.map(order, &indexed[&1])
  end

  defp visit_all(ids, deps, indexed) do
    Enum.reduce(ids, {[], %{}}, fn i, {order, marks} ->
      visit(i, deps, indexed, order, marks, [])
    end)
    |> then(fn {order, marks} -> {Enum.reverse(order), marks} end)
  end

  defp visit(i, deps, indexed, order, marks, path) do
    case marks[i] do
      :done ->
        {order, marks}

      :active ->
        names = [i | path] |> Enum.reverse() |> Enum.flat_map(&indexed[&1].outs)

        raise ElaborationError,
              "combinational loop across the hierarchy through #{Enum.join(names, " -> ")}"

      nil ->
        marks = Map.put(marks, i, :active)

        {order, marks} =
          Enum.reduce(deps[i], {order, marks}, fn d, {o, mk} ->
            visit(d, deps, indexed, o, mk, [i | path])
          end)

        {[i | order], Map.put(marks, i, :done)}
    end
  end

  @doc false
  def mem_get(vals, key, addr), do: vals |> Map.fetch!(key) |> Map.get(addr, 0)
end
