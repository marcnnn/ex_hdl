defmodule ExHdl.Regs.RTL do
  @moduledoc """
  The AXI4-Lite slave of an `ExHdl.Regs` map, as an `ExHdl.RTL` module
  named after the map, in the `:sys` domain (`clk`, `rst_n`).

  Ports: the slave bundle `s_axil` (`ExHdl.RTL.Interface.axi_lite/1` with
  the map's `addr_width`, 32-bit data), the field ports described in
  `ExHdl.Regs`, strobes, and one `ExHdl.RTL.Interface.mem_port/1` master
  per window.

  Protocol: `awready`/`wready` rise together for one cycle once both
  `awvalid` and `wvalid` are high and no write response is pending;
  `arready` for one cycle once `arvalid` is high and no read is in flight.
  All AXI outputs are registered. Reads and writes take effect one at a
  time (a write and a read never hit the RAM port in the same cycle);
  when both wait, they alternate. A register read returns data one cycle
  after the address handshake, a window read `latency + 1` cycles after
  it. Addresses decode the low `addr_width` bits; byte lanes outside
  `wstrb` keep their value; unmapped accesses complete with OKAY (or
  SLVERR with `unmapped: :slverr`) and read 0.
  """

  use ExHdl.RTL

  alias ExHdl.Regs
  alias ExHdl.RTL.Builder

  @okay 0
  @slverr 2

  @doc "The slave module. Options: `unmapped:` `:okay` (default) or `:slverr`."
  @spec build(Regs.t(), keyword()) :: ExHdl.RTL.Module.t()
  def build(%Regs{} = m, opts \\ []) do
    err =
      case Keyword.get(opts, :unmapped, :okay) do
        :okay -> @okay
        :slverr -> @slverr
      end

    aw = m.addr_width
    insts = for r <- m.registers, {_, i, off} <- Regs.instances(r), do: {r, i, off}
    wins = Enum.with_index(m.windows)
    rd_wins = for {w, j} <- wins, w.access != :wo, do: {w, j}
    lmax = rd_wins |> Enum.map(fn {w, _} -> w.latency end) |> Enum.max(fn -> 0 end)

    module m.name do
      s = slave(:s_axil, Interface.axi_lite(addr: aw, data: 32))

      aw_rdy = reg(:aw_rdy, 1)
      ar_rdy = reg(:ar_rdy, 1)
      bvalid = reg(:bvalid_r, 1)
      bresp = reg(:bresp_r, 2)
      rvalid = reg(:rvalid_r, 1)
      rresp = reg(:rresp_r, 2)
      rdata = reg(:rdata_r, 32)
      prio_rd = reg(:prio_rd, 1)

      s.awready <~ aw_rdy
      s.wready <~ aw_rdy
      s.bvalid <~ bvalid
      s.bresp <~ bresp
      s.arready <~ ar_rdy
      s.rvalid <~ rvalid
      s.rresp <~ rresp
      s.rdata <~ rdata

      wr_go = wire(:wr_go, aw_rdy and s.awvalid and s.wvalid)
      rd_go = wire(:rd_go, ar_rdy and s.arvalid)
      waddr = wire(:waddr_w, s.awaddr[2..(aw - 1)])
      raddr = wire(:raddr_w, s.araddr[2..(aw - 1)])

      pipe = if lmax > 0, do: reg(:win_pipe, lmax)
      win_sel = if rd_wins != [], do: reg(:win_sel, max(Builder.ceil_log2(length(wins)), 1))

      rd_pend =
        case pipe do
          nil -> const(0, 1)
          p -> wire(:rd_pend, reduce_or(p))
        end

      # -- arbitration ---------------------------------------------------------------------

      idle = wire(:idle, not aw_rdy and not ar_rdy)
      want_w = wire(:want_w, s.awvalid and s.wvalid and not bvalid)
      want_r = wire(:want_r, s.arvalid and not rvalid and not rd_pend)

      sync do
        aw_rdy <~ 0
        ar_rdy <~ 0

        if idle do
          if want_w and (not want_r or not prio_rd) do
            aw_rdy <~ 1
            prio_rd <~ 1
          else
            if want_r do
              ar_rdy <~ 1
              prio_rd <~ 0
            end
          end
        end
      end

      # -- decode --------------------------------------------------------------------------

      hits =
        for {r, i, off} <- insts do
          pre = prefix(r, i)
          wh = wire(:"whit_#{pre}", wr_go and waddr == div(off, 4))
          rh = wire(:"rhit_#{pre}", rd_go and raddr == div(off, 4))
          {r, i, off, wh, rh}
        end

      win_hits =
        for {w, j} <- wins do
          k = Builder.ceil_log2(w.size)
          wh = wire(:"whit_#{w.name}", wr_go and window_hit(s.awaddr, aw, k, w.offset))
          rh = wire(:"rhit_#{w.name}", rd_go and window_hit(s.araddr, aw, k, w.offset))
          {w, j, k, wh, rh}
        end

      any = fn list -> Enum.reduce(list, const(0, 1), fn x, acc -> acc or x end) end
      wr_mapped = any.(Enum.map(hits, &elem(&1, 3)) ++ Enum.map(win_hits, &elem(&1, 3)))
      rd_reg_hit = wire(:rd_reg_hit, any.(Enum.map(hits, &elem(&1, 4))))

      rd_win_start =
        wire(:rd_win_start, any.(for {w, _, _, _, rh} <- win_hits, w.access != :wo, do: rh))

      rd_win_mapped = any.(Enum.map(win_hits, &elem(&1, 4)))

      # -- write response -------------------------------------------------------------------

      sync do
        if bvalid and s.bready, do: bvalid <~ 0

        if wr_go do
          bvalid <~ 1
          bresp <~ mux(wr_mapped, const(@okay, 2), const(err, 2))
        end
      end

      # -- fields ------------------------------------------------------------------------

      reads =
        for {r, i, off, wh, rh} <- hits do
          pre = prefix(r, i)

          vals =
            for f <- r.fields do
              {f, field_logic(s, f, :"#{pre}_#{f.name}", wh, rh)}
            end

          if r.strobe in [:write, :both] do
            st = output(:"#{pre}_wr", 1, reset: 0)
            sync(do: st <~ wh)
          end

          if r.strobe in [:read, :both] do
            st = output(:"#{pre}_rd", 1, reset: 0)
            sync(do: st <~ rh)
          end

          {div(off, 4), readback(vals)}
        end

      rd_val =
        case reads do
          [] ->
            const(0, 32)

          _ ->
            v = wire(:rd_val, 32)

            comb do
              v <~ 0

              Builder.switch(
                raddr,
                for({word, x} <- reads, do: {fn -> word end, fn -> v <~ x end})
              )
            end

            v
        end

      # -- windows -----------------------------------------------------------------------

      ports =
        for {w, j, k, wh, rh} <- win_hits do
          p = master(w.name, Interface.mem_port(addr: k - 2, data: 32, be: true))
          wh = if w.access == :ro, do: const(0, 1), else: wh
          rh = if w.access == :wo, do: const(0, 1), else: rh
          p.en <~ (wh or rh)
          p.we <~ wh
          p.addr <~ mux(wr_go, s.awaddr[2..(k - 1)], s.araddr[2..(k - 1)])
          p.wdata <~ s.wdata
          p.be <~ s.wstrb
          {w, j, p}
        end

      {done, win_data} =
        case pipe do
          nil ->
            {const(0, 1), const(0, 32)}

          _ ->
            readable = for {w, j, p} <- ports, w.access != :wo, do: {w, j, p}

            done =
              wire(
                :win_done,
                any.(for {w, j, _} <- readable, do: pipe[w.latency - 1] and win_sel == j)
              )

            data =
              wire(
                :win_rdata,
                mux(
                  win_sel,
                  for({w, _, p} <- ports, do: if(w.access == :wo, do: 0, else: p.rdata))
                )
              )

            next = if lmax == 1, do: rd_win_start, else: cat([pipe[0..(lmax - 2)], rd_win_start])

            sync do
              pipe <~ next
              if done, do: pipe <~ 0

              for {w, j, _, _, rh} <- win_hits, w.access != :wo do
                if rh, do: win_sel <~ j
              end
            end

            {done, data}
        end

      # -- read response -------------------------------------------------------------------

      sync do
        if rvalid and s.rready, do: rvalid <~ 0

        if rd_go and not rd_win_start do
          rvalid <~ 1
          rdata <~ mux(rd_reg_hit, rd_val, 0)
          rresp <~ mux(rd_reg_hit or rd_win_mapped, const(@okay, 2), const(err, 2))
        end

        if done do
          rvalid <~ 1
          rdata <~ win_data
          rresp <~ @okay
        end
      end
    end
  end

  @internal ~w(clk rst_n aw_rdy ar_rdy bvalid_r bresp_r rvalid_r rresp_r rdata_r prio_rd wr_go
    rd_go waddr_w raddr_w win_pipe win_sel rd_pend idle want_w want_r rd_reg_hit rd_win_start
    rd_val win_done win_rdata)a

  @doc false
  # Every signal name the slave of `m` declares, with what it comes from, so
  # `ExHdl.Regs` can reject keywords and clashes when the map is defined.
  def names(%Regs{} = m) do
    axil =
      for {f, _, _} <- Interface.axi_lite().fields, do: {:"s_axil_#{f}", "the AXI4-Lite slave"}

    fixed = for n <- @internal, do: {n, "the slave logic"}

    regs =
      for r <- m.registers, {_, i, _} <- Regs.instances(r) do
        pre = prefix(r, i)
        what = "register #{pre}"

        hits = [{:"whit_#{pre}", what}, {:"rhit_#{pre}", what}]

        strobes =
          for {kind, suffix} <- [write: "wr", read: "rd"],
              r.strobe in [kind, :both],
              do: {:"#{pre}_#{suffix}", "the #{kind} strobe of #{what}"}

        fields =
          Enum.flat_map(r.fields, fn f ->
            base = :"#{pre}_#{f.name}"
            fw = "field #{f.name} of #{what}"

            case f.access do
              :ro when f.const != nil -> []
              a when a in [:w1c, :rc] -> [{base, fw}, {:"#{base}_set", fw}]
              :w1s -> [{base, fw}, {:"#{base}_clr", fw}]
              _ -> [{base, fw}]
            end
          end)

        hits ++ strobes ++ fields
      end

    wins =
      for w <- m.windows do
        what = "window #{w.name}"

        ports =
          for {f, _, _} <- Interface.mem_port(addr: 1, data: 32, be: true).fields,
              do: {:"#{w.name}_#{f}", what}

        [{:"whit_#{w.name}", what}, {:"rhit_#{w.name}", what} | ports]
      end

    axil ++ fixed ++ List.flatten(regs) ++ List.flatten(wins)
  end

  @doc false
  def prefix(r, nil), do: "#{r.name}"
  def prefix(r, i), do: "#{r.name}_#{i}"

  defp window_hit(_addr, aw, k, _offset) when k >= aw, do: const(1, 1)

  defp window_hit(addr, aw, k, offset),
    do: rtl(do: addr[k..(aw - 1)] == Bitwise.bsr(offset, k))

  # Hardware of one field; returns its read value (an expression or an integer).
  defp field_logic(_s, %{access: :ro, const: c}, _name, _wh, _rh) when c != nil, do: c
  defp field_logic(_s, %{access: :ro} = f, name, _wh, _rh), do: input(name, f.width)

  defp field_logic(s, %{access: a} = f, name, wh, _rh) when a in [:rw, :wo] do
    q = output(name, f.width, reset: f.reset)
    new = merge(s, f, q)

    rtl do
      sync do
        if wh, do: q <~ new
      end
    end

    if a == :rw, do: q, else: 0
  end

  defp field_logic(s, %{access: :w1c} = f, name, wh, _rh) do
    q = output(name, f.width, reset: f.reset)
    set = input(:"#{name}_set", f.width)
    clr = ones(s, f)
    rtl(do: sync(do: q <~ ((q &&& ~~~mux(wh, clr, 0)) ||| set)))
    q
  end

  defp field_logic(s, %{access: :w1s} = f, name, wh, _rh) do
    q = output(name, f.width, reset: f.reset)
    clr = input(:"#{name}_clr", f.width)
    set = ones(s, f)
    rtl(do: sync(do: q <~ ((q &&& ~~~clr) ||| mux(wh, set, 0))))
    q
  end

  defp field_logic(_s, %{access: :rc} = f, name, _wh, rh) do
    q = output(name, f.width, reset: f.reset)
    set = input(:"#{name}_set", f.width)
    rtl(do: sync(do: q <~ (mux(rh, 0, q) ||| set)))
    q
  end

  # Byte-lane segments of a field: [{lo, hi, byte}] in register bit numbers.
  defp segments(f) do
    hi = f.lo + f.width - 1

    for b <- div(f.lo, 8)..div(hi, 8) do
      {max(f.lo, 8 * b), min(hi, 8 * b + 7), b}
    end
  end

  # The field after a write: written lanes from wdata, others from q.
  defp merge(s, f, q) do
    f
    |> segments()
    |> Enum.reverse()
    |> Enum.map(fn {lo, hi, b} ->
      rtl(do: mux(s.wstrb[b], s.wdata[lo..hi], q[(lo - f.lo)..(hi - f.lo)]))
    end)
    |> cat()
  end

  # The written bits of the field's enabled lanes, 0 elsewhere.
  defp ones(s, f) do
    f
    |> segments()
    |> Enum.reverse()
    |> Enum.map(fn {lo, hi, b} -> rtl(do: mux(s.wstrb[b], s.wdata[lo..hi], 0)) end)
    |> cat()
  end

  # The 32-bit read word from `{field, value}` pairs (sorted by bit).
  defp readback(vals) do
    {parts, top} =
      Enum.reduce(vals, {[], 0}, fn {f, v}, {parts, next} ->
        gap = if f.lo > next, do: [const(0, f.lo - next)], else: []
        v = if is_integer(v), do: const(v, f.width), else: v
        {[v | gap] ++ parts, f.lo + f.width}
      end)

    parts = if top < 32, do: [const(0, 32 - top) | parts], else: parts
    cat(parts)
  end
end
