defmodule ExHdl.RTL.Sim.Flat do
  @moduledoc false
  # Flattens a module hierarchy into closures over a value map:
  #   nodes - combinational processes in evaluation order
  #   sync  - register groups per clock
  #   mems, mem_writes, mem_reads, models, async_resets
  # Signal ids are hierarchical strings ("q", "u_cnt.count").

  import Bitwise

  alias ExHdl.RTL.{ElaborationError, Expr, Module, Stmt}

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

    acc = flatten(top, "", clock_map, acc)

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

  defp id(prefix, name), do: prefix <> Atom.to_string(name)

  # clocks: this module's clock signal name => top-level clock id
  defp flatten(%Module{kind: :black_box} = m, prefix, clocks, acc) do
    model =
      m.model ||
        raise ElaborationError,
              "black box #{m.name} (#{String.trim_trailing(prefix, ".")}) has no simulation model; " <>
                "pass model: to black_box/3"

    acc = add_port_sigs(m, prefix, acc)
    inputs = for p <- m.ports, p.dir == :input, p.role != :clock, do: {p.name, id(prefix, p.name)}
    outputs = for p <- m.ports, p.dir == :output, do: {p.name, id(prefix, p.name), p.type}
    state_key = {:model, prefix}

    run = fn vals ->
      ins = Map.new(inputs, fn {p, i} -> {p, Map.fetch!(vals, i)} end)
      outs = model.outputs(Map.fetch!(vals, state_key), ins)

      Enum.reduce(outputs, vals, fn {p, i, t}, vals ->
        v =
          Map.get(outs, p) ||
            raise ArgumentError, "model #{inspect(model)} returned no value for output #{p}"

        unless is_integer(v) and v in Expr.range(t),
          do:
            raise(
              ArgumentError,
              "model #{inspect(model)}: #{p} = #{inspect(v)} does not fit #{Expr.fmt(t)}"
            )

        Map.put(vals, i, v)
      end)
    end

    deps =
      m.comb_paths |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.map(&id(prefix, &1))

    node = %{outs: Enum.map(outputs, &elem(&1, 1)), deps: deps, run: run}

    doms =
      for d <- m.domains, into: %{} do
        {Map.fetch!(clocks, hd(d.clock.args)), d.name}
      end

    entry = %{
      key: state_key,
      model: model,
      init: model.init(m.params),
      clocks: doms,
      inputs: inputs
    }

    %{acc | nodes: [node | acc.nodes], models: [entry | acc.models]}
  end

  defp flatten(%Module{} = m, prefix, clocks, acc) do
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
        body = cs(stmts, prefix, m)

        run = fn vals ->
          Map.put(vals, tid, Map.fetch!(body.(vals, %{}), tid))
        end

        deps = stmts |> Stmt.reads() |> Enum.map(&id(prefix, &1))
        %{acc | nodes: [%{outs: [tid], deps: deps, run: run} | acc.nodes]}
      end)

    # registers
    acc =
      Enum.reduce(m.domains, acc, fn d, acc ->
        cid = Map.fetch!(clocks, hd(d.clock.args))
        stmts = Keyword.get(m.sync, d.name, [])
        regs = for n <- m.decls, s = m.signals[n], s.kind == :reg, s.domain == d.name, do: s
        resets = for r <- regs, r.reset != nil, do: {id(prefix, r.name), r.reset}
        body = cs(stmts, prefix, m)
        rst = d.reset && id(prefix, hd(d.reset.args))
        level = if d.reset_active == :low, do: 0, else: 1

        group = %{
          clock: cid,
          reset: rst && {rst, level},
          resets: resets,
          run: fn vals -> body.(vals, %{}) end
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
            init: mem.init || %{}
          })
    }

    clock = fn dom -> Map.fetch!(clocks, hd(Module.domain(m, dom).clock.args)) end

    acc =
      Enum.reduce(mem.write_ports, acc, fn p, acc ->
        fa = cx(p.addr, prefix, m)
        fd = cx(p.data, prefix, m)
        fe = cx(p.en, prefix, m)
        full = (1 <<< mem.width) - 1

        fm =
          case p.be do
            nil ->
              fn _ -> full end

            be ->
              fb = cx(be, prefix, m)
              n = div(mem.width, mem.byte)
              byte_mask = (1 <<< mem.byte) - 1

              fn vals ->
                b = fb.(vals)

                Enum.reduce(0..(n - 1), 0, fn i, acc ->
                  if (b >>> i &&& 1) == 1, do: acc ||| byte_mask <<< (i * mem.byte), else: acc
                end)
              end
          end

        run = fn vals ->
          if fe.(vals) == 1, do: {key, fa.(vals), fd.(vals), fm.(vals), mem.depth}, else: nil
        end

        %{acc | mem_writes: [%{clock: clock.(p.domain), run: run} | acc.mem_writes]}
      end)

    Enum.reduce(mem.read_ports, acc, fn
      %{kind: :async}, acc ->
        acc

      p, acc ->
        fa = cx(p.addr, prefix, m)
        fe = cx(p.en, prefix, m)
        did = id(prefix, p.data)

        run = fn vals ->
          if fe.(vals) == 1, do: {did, mem_get(vals, key, fa.(vals))}, else: nil
        end

        %{acc | mem_reads: [%{clock: clock.(p.domain), run: run} | acc.mem_reads]}
    end)
  end

  @doc false
  def mem_get(vals, key, addr), do: vals |> Map.fetch!(key) |> Map.get(addr, 0)

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
          alias_node(acc, src, dst, fn v -> v end)

        {port, {:reset, pd, invert}}, acc ->
          rid = id(prefix, hd(Module.domain(m, pd).reset.args))
          alias_node(acc, rid, id(cprefix, port), if(invert, do: &(1 - &1), else: & &1))

        {_port, {:clock, _}}, acc ->
          acc
      end)

    flatten(child, cprefix, child_clocks, acc)
  end

  defp alias_node(acc, src, dst, f) do
    node = %{
      outs: [dst],
      deps: [src],
      run: fn vals -> Map.put(vals, dst, f.(Map.fetch!(vals, src))) end
    }

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

  # -- closures --------------------------------------------------------------------------

  # Statements: fn vals, acc -> acc (acc: id => assigned value).
  defp cs(stmts, p, m) do
    fs = Enum.map(stmts, &cs1(&1, p, m))
    fn vals, acc -> Enum.reduce(fs, acc, fn f, acc -> f.(vals, acc) end) end
  end

  defp cs1({:assign, t, e}, p, m) do
    tid = id(p, t)
    f = cx(e, p, m)
    fn vals, acc -> Map.put(acc, tid, f.(vals)) end
  end

  defp cs1({:if, c, a, b}, p, m) do
    fc = cx(c, p, m)
    fa = cs(a, p, m)
    fb = cs(b, p, m)
    fn vals, acc -> if fc.(vals) == 1, do: fa.(vals, acc), else: fb.(vals, acc) end
  end

  defp cs1({:switch, subj, cases, default}, p, m) do
    fs = cx(subj, p, m)

    table =
      for {vals, body} <- cases, f = cs(body, p, m), v <- vals, into: %{}, do: {hd(v.args), f}

    fd = cs(default || [], p, m)

    fn vals, acc ->
      case table do
        %{} -> Map.get(table, fs.(vals), fd).(vals, acc)
      end
    end
  end

  # Expressions: fn vals -> integer. Same semantics as ExHdl.RTL.Expr.eval/3.
  @doc false
  def cx(%Expr{op: :sig, args: [n | _]}, p, _m) do
    i = id(p, n)
    fn vals -> :erlang.map_get(i, vals) end
  end

  def cx(%Expr{op: :const, args: [c | _]}, _p, _m), do: fn _ -> c end

  def cx(%Expr{op: :mem_read, args: [mem, addr]}, p, _m) do
    key = {:mem, id(p, mem)}
    fa = cx(addr, p, nil)
    fn vals -> mem_get(vals, key, fa.(vals)) end
  end

  def cx(%Expr{op: op, args: [a, b], type: t}, p, m) when op in [:add, :sub, :mul] do
    fa = cx(a, p, m)
    fb = cx(b, p, m)
    exact = exact?(op, a, b, t)

    case {op, exact} do
      {:add, true} -> fn v -> fa.(v) + fb.(v) end
      {:add, false} -> fn v -> Expr.wrap(fa.(v) + fb.(v), t) end
      {:sub, true} -> fn v -> fa.(v) - fb.(v) end
      {:sub, false} -> fn v -> Expr.wrap(fa.(v) - fb.(v), t) end
      {:mul, true} -> fn v -> fa.(v) * fb.(v) end
      {:mul, false} -> fn v -> Expr.wrap(fa.(v) * fb.(v), t) end
    end
  end

  def cx(%Expr{op: :and, args: [a, b], type: t}, p, m), do: bin2(&Bitwise.band/2, a, b, t, p, m)
  def cx(%Expr{op: :or, args: [a, b], type: t}, p, m), do: bin2(&Bitwise.bor/2, a, b, t, p, m)
  def cx(%Expr{op: :xor, args: [a, b], type: t}, p, m), do: bin2(&Bitwise.bxor/2, a, b, t, p, m)

  def cx(%Expr{op: :eq, args: [a, b]}, p, m), do: cmp(&Kernel.==/2, a, b, p, m)
  def cx(%Expr{op: :ne, args: [a, b]}, p, m), do: cmp(&Kernel.!=/2, a, b, p, m)
  def cx(%Expr{op: :lt, args: [a, b]}, p, m), do: cmp(&Kernel.</2, a, b, p, m)
  def cx(%Expr{op: :le, args: [a, b]}, p, m), do: cmp(&Kernel.<=/2, a, b, p, m)
  def cx(%Expr{op: :gt, args: [a, b]}, p, m), do: cmp(&Kernel.>/2, a, b, p, m)
  def cx(%Expr{op: :ge, args: [a, b]}, p, m), do: cmp(&Kernel.>=/2, a, b, p, m)

  def cx(%Expr{op: :land, args: [a, b]}, p, m) do
    fa = cx(a, p, m)
    fb = cx(b, p, m)
    fn v -> fa.(v) &&& fb.(v) end
  end

  def cx(%Expr{op: :lor, args: [a, b]}, p, m) do
    fa = cx(a, p, m)
    fb = cx(b, p, m)
    fn v -> fa.(v) ||| fb.(v) end
  end

  def cx(%Expr{op: :lnot, args: [a]}, p, m) do
    fa = cx(a, p, m)
    fn v -> 1 - fa.(v) end
  end

  def cx(%Expr{op: :mux, args: [c, a, b]}, p, m) do
    fc = cx(c, p, m)
    fa = cx(a, p, m)
    fb = cx(b, p, m)
    fn v -> if fc.(v) == 1, do: fa.(v), else: fb.(v) end
  end

  def cx(%Expr{op: :slice, args: [a, lo, w], type: _}, p, m) do
    fa = cx(a, p, m)
    mask = (1 <<< w) - 1
    fn v -> fa.(v) >>> lo &&& mask end
  end

  def cx(%Expr{op: :cat, args: [items]}, p, m) do
    fs = Enum.map(items, fn i -> {cx(i, p, m), Expr.width(i), (1 <<< Expr.width(i)) - 1} end)
    fn v -> Enum.reduce(fs, 0, fn {f, w, mask}, acc -> acc <<< w ||| (f.(v) &&& mask) end) end
  end

  def cx(%Expr{op: :resize, args: [a], type: t}, p, m) do
    fa = cx(a, p, m)
    if Expr.width(a) <= Expr.width(t), do: fa, else: fn v -> Expr.wrap(fa.(v), t) end
  end

  def cx(%Expr{op: :muxn, args: [sel, items, d]}, p, m) do
    fsel = cx(sel, p, m)
    fs = items |> Enum.map(&cx(&1, p, m)) |> List.to_tuple()
    fd = cx(d, p, m)
    n = tuple_size(fs)

    fn v ->
      i = fsel.(v)
      if i < n, do: elem(fs, i).(v), else: fd.(v)
    end
  end

  # Remaining (less frequent) operators through the reference evaluator.
  def cx(%Expr{args: args} = e, p, m) do
    subs = sub_exprs(args)
    fsubs = Map.new(subs, fn s -> {s, cx(s, p, m)} end)

    fn vals ->
      e
      |> replace_subs(fsubs, vals)
      |> Expr.eval(fn _ -> raise "unreachable" end)
    end
  end

  defp sub_exprs(args) do
    Enum.flat_map(args, fn
      %Expr{} = e -> [e]
      l when is_list(l) -> sub_exprs(l)
      _ -> []
    end)
  end

  defp replace_subs(%Expr{args: args} = e, fsubs, vals) do
    %{e | args: Enum.map(args, &rep_arg(&1, fsubs, vals))}
  end

  defp rep_arg(%Expr{type: t} = s, fsubs, vals),
    do: %Expr{op: :const, args: [Map.fetch!(fsubs, s).(vals)], type: t}

  defp rep_arg(l, fsubs, vals) when is_list(l), do: Enum.map(l, &rep_arg(&1, fsubs, vals))
  defp rep_arg(v, _, _), do: v

  defp exact?(:add, a, b, {_, w}), do: w > max(Expr.width(a), Expr.width(b))
  defp exact?(:sub, a, b, {s, w}), do: s == :s and w > max(Expr.width(a), Expr.width(b))
  defp exact?(:mul, a, b, {_, w}), do: w >= Expr.width(a) + Expr.width(b)

  defp bin2(f, a, b, t, p, m) do
    fa = cx(a, p, m)
    fb = cx(b, p, m)
    fn v -> Expr.wrap(f.(fa.(v), fb.(v)), t) end
  end

  defp cmp(f, a, b, p, m) do
    fa = cx(a, p, m)
    fb = cx(b, p, m)
    fn v -> if f.(fa.(v), fb.(v)), do: 1, else: 0 end
  end
end
