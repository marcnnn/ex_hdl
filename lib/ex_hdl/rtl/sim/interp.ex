defmodule ExHdl.RTL.Sim.Interp do
  @moduledoc false
  # Reference engine of ExHdl.RTL.Sim: closures over a value map
  # (id => value, memories and model states under their keys). Slow but
  # simple; the compiled engine (ExHdl.RTL.Sim.Compiler) is checked
  # against it.

  import Bitwise

  alias ExHdl.RTL.Expr
  alias ExHdl.RTL.Sim.Flat

  defstruct [:nodes, :sync, :mem_writes, :mem_reads, :models, :async_resets, :init]

  def build(%Flat{} = flat) do
    vals =
      Map.new(flat.sigs, fn {id, _} -> {id, 0} end)
      |> then(fn v ->
        Enum.reduce(flat.mems, v, fn {_, m}, v -> Map.put(v, m.key, m.init) end)
      end)
      |> then(fn v -> Enum.reduce(flat.models, v, fn m, v -> Map.put(v, m.key, m.init) end) end)

    %__MODULE__{
      nodes: Enum.map(flat.nodes, &comb_node/1),
      sync: Enum.map(flat.sync, &sync_group/1),
      mem_writes: Enum.map(flat.mem_writes, &mem_write/1),
      mem_reads: Enum.map(flat.mem_reads, &mem_read/1),
      models: flat.models,
      async_resets: flat.async_resets,
      init: vals
    }
  end

  def init(%__MODULE__{init: v}), do: v

  def get(_p, vals, id), do: Map.fetch!(vals, id)

  def has?(_p, vals, id), do: Map.has_key?(vals, id)

  def put(_p, vals, id, v), do: Map.put(vals, id, v)

  def mem_get(_p, vals, key, addr), do: Flat.mem_get(vals, key, addr)

  def settle(%__MODULE__{} = p, vals) do
    vals = Enum.reduce(p.nodes, vals, fn run, v -> run.(v) end)
    async_resets(p, vals, 10)
  end

  defp async_resets(_p, _vals, 0), do: raise(ArgumentError, "asynchronous resets do not settle")

  defp async_resets(p, vals, budget) do
    forced =
      Enum.reduce(p.async_resets, vals, fn r, v ->
        if Map.fetch!(v, r.reset) == r.level,
          do: Enum.reduce(r.regs, v, fn {id, rv}, v -> Map.put(v, id, rv) end),
          else: v
      end)

    if forced == vals do
      vals
    else
      vals = Enum.reduce(p.nodes, forced, fn run, v -> run.(v) end)
      async_resets(p, vals, budget - 1)
    end
  end

  # `fire`: list of rising clock ids
  def edge(%__MODULE__{} = p, vals, fire) do
    regs =
      for g <- p.sync, g.clock in fire, reduce: %{} do
        acc ->
          next = g.run.(vals)

          next =
            case g.reset do
              {rst, level} ->
                if Map.fetch!(vals, rst) == level,
                  do: Enum.reduce(g.resets, next, fn {id, v}, n -> Map.put(n, id, v) end),
                  else: next

              nil ->
                next
            end

          Map.merge(acc, next)
      end

    writes = for w <- p.mem_writes, w.clock in fire, x = w.run.(vals), x != nil, do: x
    reads = for r <- p.mem_reads, r.clock in fire, x = r.run.(vals), x != nil, into: %{}, do: x

    models =
      for m <- p.models, {c, d} <- m.clocks, c in fire, reduce: %{} do
        acc ->
          state = Map.get(acc, m.key, Map.fetch!(vals, m.key))
          ins = Map.new(m.inputs, fn {port, i} -> {port, Map.fetch!(vals, i)} end)
          Map.put(acc, m.key, m.model.clock(d, state, ins))
      end

    vals =
      Enum.reduce(writes, vals, fn {key, addr, data, mask, depth}, v ->
        if addr < depth do
          words = Map.fetch!(v, key)
          old = Map.get(words, addr, 0)
          Map.put(v, key, Map.put(words, addr, (old &&& ~~~mask) ||| (data &&& mask)))
        else
          v
        end
      end)

    vals |> Map.merge(regs) |> Map.merge(reads) |> Map.merge(models)
  end

  # -- building closures -------------------------------------------------------------------

  defp comb_node(%{ir: {:comb, tid, stmts, prefix}}) do
    body = cs(stmts, prefix)
    fn vals -> Map.put(vals, tid, Map.fetch!(body.(vals, %{}), tid)) end
  end

  defp comb_node(%{ir: {:alias, src, dst, invert}}) do
    if invert,
      do: fn vals -> Map.put(vals, dst, 1 - Map.fetch!(vals, src)) end,
      else: fn vals -> Map.put(vals, dst, Map.fetch!(vals, src)) end
  end

  defp comb_node(%{ir: {:model, key, model, inputs, outputs}}) do
    fn vals ->
      ins = Map.new(inputs, fn {port, i} -> {port, Map.fetch!(vals, i)} end)
      outs = ExHdl.RTL.Sim.Runtime.model_outputs(model, Map.fetch!(vals, key), ins, outputs)

      outputs
      |> Enum.zip(Tuple.to_list(outs))
      |> Enum.reduce(vals, fn {{_, i, _}, v}, vals -> Map.put(vals, i, v) end)
    end
  end

  defp sync_group(g) do
    body = cs(g.stmts, g.prefix)
    Map.merge(Map.drop(g, [:stmts, :prefix]), %{run: fn vals -> body.(vals, %{}) end})
  end

  defp mem_write(w) do
    fa = cx(w.addr, w.prefix)
    fd = cx(w.data, w.prefix)
    fe = cx(w.en, w.prefix)
    full = (1 <<< w.width) - 1

    fm =
      case w.be do
        nil ->
          fn _ -> full end

        be ->
          fb = cx(be, w.prefix)
          n = div(w.width, w.byte)
          fn vals -> ExHdl.RTL.Sim.Runtime.byte_mask(fb.(vals), n, w.byte) end
      end

    key = w.key
    depth = w.depth

    run = fn vals ->
      if fe.(vals) == 1, do: {key, fa.(vals), fd.(vals), fm.(vals), depth}, else: nil
    end

    %{clock: w.clock, run: run}
  end

  defp mem_read(r) do
    fa = cx(r.addr, r.prefix)
    fe = cx(r.en, r.prefix)
    did = r.data
    key = r.key

    run = fn vals ->
      if fe.(vals) == 1, do: {did, Flat.mem_get(vals, key, fa.(vals))}, else: nil
    end

    %{clock: r.clock, run: run}
  end

  # Statements: fn vals, acc -> acc (acc: id => assigned value).
  defp cs(stmts, p) do
    fs = Enum.map(stmts, &cs1(&1, p))
    fn vals, acc -> Enum.reduce(fs, acc, fn f, acc -> f.(vals, acc) end) end
  end

  defp cs1({:assign, t, e}, p) do
    tid = Flat.id(p, t)
    f = cx(e, p)
    fn vals, acc -> Map.put(acc, tid, f.(vals)) end
  end

  defp cs1({:if, c, a, b}, p) do
    fc = cx(c, p)
    fa = cs(a, p)
    fb = cs(b, p)
    fn vals, acc -> if fc.(vals) == 1, do: fa.(vals, acc), else: fb.(vals, acc) end
  end

  defp cs1({:switch, subj, cases, default}, p) do
    fs = cx(subj, p)
    table = for {vals, body} <- cases, f = cs(body, p), v <- vals, into: %{}, do: {hd(v.args), f}
    fd = cs(default || [], p)
    fn vals, acc -> Map.get(table, fs.(vals), fd).(vals, acc) end
  end

  # Expressions: fn vals -> integer. Same semantics as ExHdl.RTL.Expr.eval/3.
  @doc false
  def cx(%Expr{op: :sig, args: [n | _]}, p) do
    i = Flat.id(p, n)
    fn vals -> :erlang.map_get(i, vals) end
  end

  def cx(%Expr{op: :const, args: [c | _]}, _p), do: fn _ -> c end

  def cx(%Expr{op: :mem_read, args: [mem, addr]}, p) do
    key = {:mem, Flat.id(p, mem)}
    fa = cx(addr, p)
    fn vals -> Flat.mem_get(vals, key, fa.(vals)) end
  end

  def cx(%Expr{op: op, args: [a, b], type: t}, p) when op in [:add, :sub, :mul] do
    fa = cx(a, p)
    fb = cx(b, p)
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

  def cx(%Expr{op: :and, args: [a, b], type: t}, p), do: bin2(&Bitwise.band/2, a, b, t, p)
  def cx(%Expr{op: :or, args: [a, b], type: t}, p), do: bin2(&Bitwise.bor/2, a, b, t, p)
  def cx(%Expr{op: :xor, args: [a, b], type: t}, p), do: bin2(&Bitwise.bxor/2, a, b, t, p)

  def cx(%Expr{op: :eq, args: [a, b]}, p), do: cmp(&Kernel.==/2, a, b, p)
  def cx(%Expr{op: :ne, args: [a, b]}, p), do: cmp(&Kernel.!=/2, a, b, p)
  def cx(%Expr{op: :lt, args: [a, b]}, p), do: cmp(&Kernel.</2, a, b, p)
  def cx(%Expr{op: :le, args: [a, b]}, p), do: cmp(&Kernel.<=/2, a, b, p)
  def cx(%Expr{op: :gt, args: [a, b]}, p), do: cmp(&Kernel.>/2, a, b, p)
  def cx(%Expr{op: :ge, args: [a, b]}, p), do: cmp(&Kernel.>=/2, a, b, p)

  def cx(%Expr{op: :land, args: [a, b]}, p) do
    fa = cx(a, p)
    fb = cx(b, p)
    fn v -> fa.(v) &&& fb.(v) end
  end

  def cx(%Expr{op: :lor, args: [a, b]}, p) do
    fa = cx(a, p)
    fb = cx(b, p)
    fn v -> fa.(v) ||| fb.(v) end
  end

  def cx(%Expr{op: :lnot, args: [a]}, p) do
    fa = cx(a, p)
    fn v -> 1 - fa.(v) end
  end

  def cx(%Expr{op: :mux, args: [c, a, b]}, p) do
    fc = cx(c, p)
    fa = cx(a, p)
    fb = cx(b, p)
    fn v -> if fc.(v) == 1, do: fa.(v), else: fb.(v) end
  end

  def cx(%Expr{op: :slice, args: [a, lo, w], type: _}, p) do
    fa = cx(a, p)
    mask = (1 <<< w) - 1
    fn v -> fa.(v) >>> lo &&& mask end
  end

  def cx(%Expr{op: :cat, args: [items]}, p) do
    fs = Enum.map(items, fn i -> {cx(i, p), Expr.width(i), (1 <<< Expr.width(i)) - 1} end)
    fn v -> Enum.reduce(fs, 0, fn {f, w, mask}, acc -> acc <<< w ||| (f.(v) &&& mask) end) end
  end

  def cx(%Expr{op: :resize, args: [a], type: t}, p) do
    fa = cx(a, p)
    if Expr.width(a) <= Expr.width(t), do: fa, else: fn v -> Expr.wrap(fa.(v), t) end
  end

  def cx(%Expr{op: :muxn, args: [sel, items, d]}, p) do
    fsel = cx(sel, p)
    fs = items |> Enum.map(&cx(&1, p)) |> List.to_tuple()
    fd = cx(d, p)
    n = tuple_size(fs)

    fn v ->
      i = fsel.(v)
      if i < n, do: elem(fs, i).(v), else: fd.(v)
    end
  end

  # Remaining (less frequent) operators through the reference evaluator.
  def cx(%Expr{args: args} = e, p) do
    subs = sub_exprs(args)
    fsubs = Map.new(subs, fn s -> {s, cx(s, p)} end)

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

  defp bin2(f, a, b, t, p) do
    fa = cx(a, p)
    fb = cx(b, p)
    fn v -> Expr.wrap(f.(fa.(v), fb.(v)), t) end
  end

  defp cmp(f, a, b, p) do
    fa = cx(a, p)
    fb = cx(b, p)
    fn v -> if f.(fa.(v), fb.(v)), do: 1, else: 0 end
  end
end
