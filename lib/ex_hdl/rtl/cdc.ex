defmodule ExHdl.RTL.CDC do
  @moduledoc """
  Clock domain crossing cells. They are the only modules whose inputs are
  `domain: :async` and whose first registers may sample another domain
  (`async_reg: true`, emitted with `(* ASYNC_REG = "TRUE" *)` so Vivado
  places the stages together and the timing tools treat them as
  synchronisers).

    * `sync_ff/1` - multi-stage flip-flop synchroniser (one domain `:dst`).
      For buses only when at most one bit changes at a time, e.g. Gray-coded
      FIFO pointers (`gray/1`, `ungray/1`).
    * `pulse_sync/1` - a one-cycle pulse in `:src` becomes a one-cycle
      pulse in `:dst` (toggle, synchroniser, edge detect). Pulses closer
      than about three `:dst` cycles merge.
    * `reset_sync/1` - asynchronous assertion, synchronous deassertion.
    * `handshake/2` - bus transfer with req/ack toggles: `s_valid`/`s_ready`
      in `:src`, a one-cycle `d_valid` with `d_data` in `:dst`.

  Instantiate them like any module, mapping their domains:

      sync = instance :sync, CDC.sync_ff(width: 5), domains: [dst: :rd]
      sync.d <~ wr_ptr_gray
      rd_side_ptr = sync.q

  `paths/1` lists every crossing of a design for timing constraints
  (`set_max_delay -datapath_only`).
  """
  use ExHdl.RTL

  @doc """
  `stages` (default 2) flip-flops per bit of `width` (default 1).
  Ports: `clk`, (`rst_n` with `reset: true`), `d` (async), `q` (dst).
  """
  def sync_ff(opts \\ []) do
    w = Keyword.get(opts, :width, 1)
    n = Keyword.get(opts, :stages, 2)
    reset? = Keyword.get(opts, :reset, false)
    if n < 2, do: raise(ArgumentError, "a synchroniser needs at least 2 stages")

    module "exhdl_cdc_sync_w#{w}_s#{n}#{if reset?, do: "_r", else: ""}" do
      domain(:dst, clock: :clk, reset: if(reset?, do: :rst_n, else: nil))
      d = input(:d, w, domain: :async)
      q = output(:q, w)
      rst = if reset?, do: 0, else: nil
      stages = for i <- 0..(n - 1), do: reg(:"s#{i}", w, reset: rst, async_reg: true)

      sync :dst do
        hd(stages) <~ d
        for {a, b} <- Enum.zip(stages, tl(stages)), do: b <~ a
      end

      q <~ List.last(stages)
    end
  end

  @doc """
  Pulse synchroniser. Ports: `clk_src`, `rst_src_n`, `pulse_in` (src),
  `clk_dst`, `rst_dst_n`, `pulse_out` (dst). Latency 3 `:dst` cycles.
  """
  def pulse_sync(opts \\ []) do
    n = Keyword.get(opts, :stages, 2)

    module "exhdl_cdc_pulse_s#{n}" do
      domain(:src, clock: :clk_src, reset: :rst_src_n)
      domain(:dst, clock: :clk_dst, reset: :rst_dst_n)
      pulse_in = input(:pulse_in, 1, domain: :src)
      pulse_out = output(:pulse_out, 1)

      toggle = reg(:toggle, 1, domain: :src)
      stages = for i <- 0..(n - 1), do: reg(:"s#{i}", 1, domain: :dst, async_reg: true)
      last = reg(:last, 1, domain: :dst)

      sync :src do
        if pulse_in, do: toggle <~ not toggle
      end

      sync :dst do
        hd(stages) <~ toggle
        for {a, b} <- Enum.zip(stages, tl(stages)), do: b <~ a
        last <~ List.last(stages)
      end

      pulse_out <~ bxor(List.last(stages), last)
    end
  end

  @doc """
  Reset synchroniser: `arst_n` (asynchronous, active low) asserts `rst_n`
  immediately, deassertion follows `stages` (default 2) rising edges of
  `clk`. With `active: :high` the output is `rst` (active high).
  """
  def reset_sync(opts \\ []) do
    n = Keyword.get(opts, :stages, 2)
    active = Keyword.get(opts, :active, :low)

    module "exhdl_cdc_reset_sync_s#{n}#{if active == :high, do: "_h", else: ""}" do
      domain(:dst, clock: :clk, reset: :arst_n, reset_kind: :async)
      out = output(if(active == :low, do: :rst_n, else: :rst), 1)
      stages = for i <- 0..(n - 1), do: reg(:"s#{i}", 1, reset: 0, async_reg: true)

      sync :dst do
        hd(stages) <~ 1
        for {a, b} <- Enum.zip(stages, tl(stages)), do: b <~ a
      end

      if active == :low,
        do: out <~ List.last(stages),
        else: out <~ not List.last(stages)
    end
  end

  @doc """
  Handshake bus synchroniser for `width`-bit words. `:src` ports:
  `s_valid`, `s_data`, `s_ready` (high when a new word is accepted);
  `:dst` ports: `d_valid` (one cycle), `d_data` (held until the next
  word). One transfer takes about `2 * stages + 2` cycles of each clock.
  """
  def handshake(width, opts \\ []) do
    n = Keyword.get(opts, :stages, 2)

    module "exhdl_cdc_handshake_w#{width}_s#{n}" do
      domain(:src, clock: :clk_src, reset: :rst_src_n)
      domain(:dst, clock: :clk_dst, reset: :rst_dst_n)
      s_valid = input(:s_valid, 1, domain: :src)
      s_data = input(:s_data, width, domain: :src)
      s_ready = output(:s_ready, 1)
      d_valid = output(:d_valid, 1, reset: 0, domain: :dst)
      d_data = output(:d_data, width, reset: 0, domain: :dst, cdc: true)

      req = reg(:req, 1, domain: :src)
      data_q = reg(:data_q, width, domain: :src, reset: nil)
      ack_sync = for i <- 0..(n - 1), do: reg(:"ack_s#{i}", 1, domain: :src, async_reg: true)
      req_sync = for i <- 0..(n - 1), do: reg(:"req_s#{i}", 1, domain: :dst, async_reg: true)
      ack = reg(:ack, 1, domain: :dst)

      ready = wire(:ready, not bxor(req, List.last(ack_sync)))
      s_ready <~ ready

      sync :src do
        if s_valid and ready do
          data_q <~ s_data
          req <~ not req
        end

        hd(ack_sync) <~ ack
        for {a, b} <- Enum.zip(ack_sync, tl(ack_sync)), do: b <~ a
      end

      sync :dst do
        hd(req_sync) <~ req
        for {a, b} <- Enum.zip(req_sync, tl(req_sync)), do: b <~ a
        d_valid <~ 0

        if List.last(req_sync) != ack do
          d_data <~ data_q
          d_valid <~ 1
          ack <~ List.last(req_sync)
        end
      end
    end
  end

  # -- constraint export -----------------------------------------------------------------

  @doc """
  The clock domain crossings of a design, for timing constraints.

  One entry per pair of a crossing register and a source in another clock:
  every `async_reg: true` or `cdc: true` register anywhere in the hierarchy
  is followed backwards through combinational logic, instance ports and
  module boundaries to the registers, memories, black-box outputs and
  top-level inputs it samples. Sources clocked like the register itself
  (the second stage of a synchroniser) are left out.

      %{
        to: "u_ts/c_tag",          # register, instance labels joined with "/"
        to_clock: "clk_mac",       # top-level clock signal of its domain
        from: "tag_hold",          # source register, memory, black-box pin or port
        from_kind: :reg,           # :reg | :memory | :black_box | :port
        from_clock: "clk",         # nil for :async/:static ports and outputs
        kind: :cdc                 # :async_reg | :cdc
      }

  Clocks are named by the top-level clock port, or `path/name` for an
  internal clock (`clock_port: false`). A constraint generator emits, for
  example, `set_max_delay -datapath_only -from [get_cells tag_hold_reg*]
  -to [get_cells u_ts/c_tag_reg*] <period of to_clock>`, and
  `set_false_path` (or the same) for `from_kind: :port`. Sorted by `to`,
  then `from`.
  """
  @spec paths(ExHdl.RTL.Module.t()) :: [map()]
  def paths(%ExHdl.RTL.Module{} = top) do
    tree = tree(top, [], nil, %{})

    tree
    |> Enum.flat_map(fn {path, %{module: m}} ->
      for {dom, stmts} <- m.sync,
          t <- ExHdl.RTL.Stmt.targets(stmts),
          sig = m.signals[t],
          sig.attrs[:cdc],
          ck = clock(tree, path, dom),
          src <- stmts |> ExHdl.RTL.Stmt.slice(MapSet.new([t])) |> ExHdl.RTL.Stmt.reads(),
          leaf <- sources(tree, path, src, MapSet.new()),
          {kind, at, name, lck} = leaf,
          lck != ck,
          uniq: true do
        %{
          to: join(path, t),
          to_clock: ck,
          from: join(at, name),
          from_kind: kind,
          from_clock: lck,
          kind: if(sig.attrs[:async_reg], do: :async_reg, else: :cdc)
        }
      end
    end)
    |> Enum.sort_by(&{&1.to, &1.from})
  end

  defp tree(m, path, parent, acc) do
    acc = Map.put(acc, path, %{module: m, parent: parent})

    Enum.reduce(m.instances, acc, fn i, acc ->
      if i.module.kind == :black_box,
        do: acc,
        else: tree(i.module, path ++ [i.name], {path, i}, acc)
    end)
  end

  defp join(path, name), do: Enum.join(path ++ [name], "/")

  # Top-level name of the clock of domain `dom` of the module at `path`.
  defp clock(tree, path, dom) do
    %{module: m, parent: parent} = tree[path]
    d = Enum.find(m.domains, &(&1.name == dom))
    clk = hd(d.clock.args)

    case parent do
      _ when not d.clock_port -> join(path, clk)
      nil -> Atom.to_string(clk)
      {ppath, inst} -> clock(tree, ppath, Map.fetch!(inst.domains, dom))
    end
  end

  # Leaves `{kind, path, name, clock | nil}` driving signal `n` at `path`.
  defp sources(tree, path, n, seen) do
    if MapSet.member?(seen, {path, n}) do
      []
    else
      seen = MapSet.put(seen, {path, n})
      %{module: m, parent: parent} = tree[path]
      sig = m.signals[n]

      case sig.kind do
        k when k in [:reg, :mem_data] ->
          [{:reg, path, n, clock(tree, path, sig.domain)}]

        :input when parent == nil ->
          [{:port, [], n, port_clock(tree, path, sig.domain)}]

        :input ->
          {ppath, inst} = parent
          {:wire, w} = Keyword.fetch!(inst.conns, n)
          sources(tree, ppath, w, seen)

        :inst_out ->
          {i, port} = sig.inst
          inst = Enum.find(m.instances, &(&1.name == i))

          if inst.module.kind == :black_box do
            d = ExHdl.RTL.Module.port(inst.module, port).domain

            ck =
              if d in [nil, :async, :static],
                do: nil,
                else: clock(tree, path, Map.fetch!(inst.domains, d))

            [{:black_box, path ++ [i], port, ck}]
          else
            sources(tree, path ++ [i], port, seen)
          end

        :mem_async ->
          mem = Enum.find(m.memories, &Enum.any?(&1.read_ports, fn p -> p.data == n end))

          for w <- mem.write_ports,
              do: {:memory, path, mem.name, clock(tree, path, w.domain)}

        k when k in [:clock, :clock_int, :reset, :reset_int, :inout] ->
          []

        _ ->
          case List.keyfind(m.comb, n, 0) do
            nil ->
              []

            {_, stmts} ->
              stmts
              |> ExHdl.RTL.Stmt.reads()
              |> Enum.flat_map(&sources(tree, path, &1, seen))
          end
      end
    end
  end

  defp port_clock(_tree, _path, d) when d in [nil, :async, :static], do: nil
  defp port_clock(tree, path, d), do: clock(tree, path, d)

  @doc "Binary to Gray code (an expression of the same width)."
  def gray(e), do: rtl(do: bxor(e, e >>> 1))

  @doc "Gray code to binary."
  def ungray(e) do
    w = width(e)

    bits =
      Enum.reduce((w - 2)..0//-1, [e[w - 1]], fn i, [prev | _] = acc ->
        [bxor(prev, e[i]) | acc]
      end)

    cat(Enum.reverse(bits))
  end
end
