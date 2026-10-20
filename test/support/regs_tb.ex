defmodule ExHdl.Test.RegsTB do
  @moduledoc false
  # Test benches for ExHdl.Regs slaves: window RAMs, an RTL AXI4-Lite
  # master running commands from a ROM, and a transaction-level reference
  # model of a register map.
  use ExHdl.RTL
  import Bitwise, only: [bsl: 2, bsr: 2, band: 2, bor: 2, bnot: 1]

  alias ExHdl.Regs
  alias ExHdl.RTL.Builder

  # Slave plus one RAM per window (`latency` cycles: a synchronous read
  # and latency - 1 registers). Every other slave port is a top port.
  # With `master: cmds` an RTL master drives the slave instead of the
  # `s_axil` ports.
  def bench(%Regs{} = map, opts \\ []) do
    slave_mod = Regs.RTL.build(map, Keyword.take(opts, [:unmapped]))
    cmds = Keyword.get(opts, :master)
    win_names = Enum.map(map.windows, &Atom.to_string(&1.name))

    passthrough =
      for p <- slave_mod.ports,
          p.role == :data,
          not String.starts_with?(Atom.to_string(p.name), "s_axil_"),
          not Enum.any?(win_names, &String.starts_with?(Atom.to_string(p.name), &1 <> "_")),
          do: p

    name = if cmds, do: "#{map.name}_mtb", else: "#{map.name}_tb"

    module name do
      u = instance(:u, slave_mod)

      if cmds do
        mm = axil_master(map.addr_width, cmds)
        mst = instance(:mst, mm)
        connect(mst.m_axil, u.s_axil)
        for p <- [:bstall, :rstall, :hold_aw, :hold_w, :hold_ar], do: mst[p] <~ input(p, 1)

        for p <- [:res_valid, :res_read, :res_data, :res_resp, :done] do
          o = output(p, ExHdl.RTL.Module.port(mm, p).type)
          o <~ mst[p]
        end
      else
        connect(slave(:s_axil, Interface.axi_lite(addr: map.addr_width)), u.s_axil)
      end

      for p <- passthrough do
        case p.dir do
          :input -> u[p.name] <~ input(p.name, p.type)
          :output -> output(p.name, p.type) <~ u[p.name]
        end
      end

      for w <- map.windows do
        port = u[w.name]
        words = div(w.size, 4)
        mem = memory(:"#{w.name}_mem", width: 32, depth: words)
        write_port(mem, addr: port.addr, data: port.wdata, en: port.en and port.we, be: port.be)
        d = read_port(mem, addr: port.addr, en: port.en)

        d =
          Enum.reduce(2..w.latency//1, d, fn i, d ->
            r = reg(:"#{w.name}_d#{i}", 32)
            sync(do: r <~ d)
            r
          end)

        port.rdata <~ d
      end
    end
  end

  # An AXI4-Lite master executing `cmds` (`{:write, addr, data, strb}` or
  # `{:read, addr}`) one after the other. `hold_*` inputs delay raising a
  # valid (never dropping one), `bstall`/`rstall` hold bready/rready low.
  # Each response pulses `res_valid` with `res_read`, `res_data`,
  # `res_resp`; `done` rises after the last.
  def axil_master(aw, cmds) do
    n = length(cmds)
    pw = max(Builder.ceil_log2(n + 1), 1)
    cw = 1 + aw + 32 + 4

    init =
      Enum.map(cmds, fn
        {:write, a, d, s} -> bor(bsl(1, cw - 1), bor(bsl(a, 36), bor(bsl(d, 4), s)))
        {:read, a} -> bsl(a, 36)
      end)

    hash = :erlang.phash2(cmds)

    module "axil_master_#{hash}" do
      m = master(:m_axil, Interface.axi_lite(addr: aw))
      bstall = input(:bstall, 1)
      rstall = input(:rstall, 1)
      hold_aw = input(:hold_aw, 1)
      hold_w = input(:hold_w, 1)
      hold_ar = input(:hold_ar, 1)
      res_valid = output(:res_valid, 1, reset: 0)
      res_read = output(:res_read, 1, reset: 0)
      res_data = output(:res_data, 32, reset: 0)
      res_resp = output(:res_resp, 2, reset: 0)
      done = output(:done, 1, reset: 0)

      rom = memory(:cmds, width: cw, depth: max(n, 2), init: init)
      pc = reg(:pc, pw)
      cmd = read_port(rom, addr: resize(pc, max(Builder.ceil_log2(max(n, 2)), 1)))
      is_wr = reg(:is_wr, 1)
      addr = reg(:addr, aw)
      data = reg(:data, 32)
      strb = reg(:strb, 4)
      awv = reg(:awv, 1)
      wv = reg(:wv, 1)
      arv = reg(:arv, 1)
      aw_pend = reg(:aw_pend, 1)
      w_pend = reg(:w_pend, 1)
      ar_pend = reg(:ar_pend, 1)

      m.awaddr <~ addr
      m.awprot <~ 0
      m.awvalid <~ awv
      m.wdata <~ data
      m.wstrb <~ strb
      m.wvalid <~ wv
      m.bready <~ not bstall
      m.araddr <~ addr
      m.arprot <~ 0
      m.arvalid <~ arv
      m.rready <~ not rstall

      fsm :ctl, reset: :fetch do
        state :fetch do
          res_valid <~ 0
          if pc == n, do: goto(:finished), else: goto(:load)
        end

        state :load do
          is_wr <~ cmd[cw - 1]
          addr <~ cmd[36..(36 + aw - 1)]
          data <~ cmd[4..35]
          strb <~ cmd[0..3]

          if cmd[cw - 1] do
            aw_pend <~ 1
            w_pend <~ 1
          else
            ar_pend <~ 1
          end

          goto(:busy)
        end

        state :busy do
          if aw_pend and not awv and not hold_aw, do: awv <~ 1
          if w_pend and not wv and not hold_w, do: wv <~ 1
          if ar_pend and not arv and not hold_ar, do: arv <~ 1

          if awv and m.awready do
            awv <~ 0
            aw_pend <~ 0
          end

          if wv and m.wready do
            wv <~ 0
            w_pend <~ 0
          end

          if arv and m.arready do
            arv <~ 0
            ar_pend <~ 0
          end

          if is_wr and m.bvalid and not bstall do
            res_valid <~ 1
            res_read <~ 0
            res_data <~ 0
            res_resp <~ m.bresp
            pc <~ add_wrap(pc, 1)
            goto(:fetch)
          end

          if not is_wr and m.rvalid and not rstall do
            res_valid <~ 1
            res_read <~ 1
            res_data <~ m.rdata
            res_resp <~ m.rresp
            pc <~ add_wrap(pc, 1)
            goto(:fetch)
          end
        end

        state :finished do
          res_valid <~ 0
          done <~ 1
        end
      end
    end
  end

  # -- reference model ---------------------------------------------------------------------

  # Transaction-level model of a map with all hardware inputs held at
  # `hw` (port name => value; set/clear inputs default 0). State: port
  # name => value for every stored field, window name => %{word => value}.
  def model_new(%Regs{} = map, hw \\ %{}) do
    fields =
      for r <- map.registers,
          {_, i, _} <- Regs.instances(r),
          f <- r.fields,
          stored?(f),
          into: %{} do
        {port(r, i, f), f.reset}
      end

    %{map: map, hw: hw, vals: fields, mems: Map.new(map.windows, &{&1.name, %{}})}
  end

  defp stored?(f), do: f.access != :ro

  defp port(r, i, f), do: :"#{Regs.RTL.prefix(r, i)}_#{f.name}"

  defp find(map, addr) do
    reg =
      Enum.find_value(map.registers, fn r ->
        Enum.find_value(Regs.instances(r), fn {_, i, off} -> if off == addr, do: {r, i} end)
      end)

    win =
      Enum.find(map.windows, fn w -> addr >= w.offset and addr < w.offset + w.size end)

    cond do
      reg -> {:reg, reg}
      win -> {:win, win, div(addr - win.offset, 4)}
      true -> :none
    end
  end

  defp lanes(strb),
    do:
      Enum.reduce(0..3, 0, fn b, m ->
        if band(bsr(strb, b), 1) == 1, do: bor(m, bsl(0xFF, 8 * b)), else: m
      end)

  def model_write(st, addr, data, strb) do
    a = band(addr, bsl(1, st.map.addr_width) - 1) |> band(bnot(3))
    lm = lanes(strb)

    case find(st.map, a) do
      {:reg, {r, i}} ->
        vals =
          Enum.reduce(r.fields, st.vals, fn f, vals ->
            p = port(r, i, f)
            fm = bsl(1, f.width) - 1
            w = band(bsr(data, f.lo), fm)
            l = band(bsr(lm, f.lo), fm)
            old = Map.get(vals, p)

            case f.access do
              a when a in [:rw, :wo] -> Map.put(vals, p, bor(band(old, bnot(l)), band(w, l)))
              :w1c -> Map.put(vals, p, band(old, bnot(band(w, l))))
              :w1s -> Map.put(vals, p, bor(old, band(w, l)))
              _ -> vals
            end
          end)

        {:okay, %{st | vals: vals}}

      {:win, w, word} ->
        if w.access == :ro do
          {:okay, st}
        else
          mem = st.mems[w.name]
          old = Map.get(mem, word, 0)
          new = bor(band(old, bnot(lm)), band(data, lm))
          {:okay, %{st | mems: Map.put(st.mems, w.name, Map.put(mem, word, new))}}
        end

      :none ->
        {:okay, st}
    end
  end

  def model_read(st, addr) do
    a = band(addr, bsl(1, st.map.addr_width) - 1) |> band(bnot(3))

    case find(st.map, a) do
      {:reg, {r, i}} ->
        {word, vals} =
          Enum.reduce(r.fields, {0, st.vals}, fn f, {word, vals} ->
            p = port(r, i, f)

            {v, vals} =
              case f.access do
                :ro when f.const != nil -> {f.const, vals}
                :ro -> {Map.get(st.hw, p, 0), vals}
                :wo -> {0, vals}
                :rc -> {Map.get(vals, p), Map.put(vals, p, 0)}
                _ -> {Map.get(vals, p), vals}
              end

            {bor(word, bsl(v, f.lo)), vals}
          end)

        {word, :okay, %{st | vals: vals}}

      {:win, w, word} ->
        v = if w.access == :wo, do: 0, else: Map.get(st.mems[w.name], word, 0)
        {v, :okay, st}

      :none ->
        {0, :okay, st}
    end
  end

  # Expected `{read?, data, resp}` results of a command list.
  def model_run(st, cmds) do
    {res, _} =
      Enum.map_reduce(cmds, st, fn
        {:write, a, d, s}, st ->
          {resp, st} = model_write(st, a, d, s)
          {{0, 0, resp}, st}

        {:read, a}, st ->
          {d, resp, st} = model_read(st, a)
          {{1, d, resp}, st}
      end)

    res
  end

  # Random commands over every register, window word and some unmapped
  # addresses.
  def random_cmds(%Regs{} = map, n, seed) do
    :rand.seed(:exsss, {seed, 5, 6})

    addrs =
      Enum.flat_map(map.registers, fn r -> Enum.map(Regs.instances(r), &elem(&1, 2)) end) ++
        Enum.flat_map(map.windows, fn w -> [w.offset, w.offset + 4, w.offset + w.size - 4] end) ++
        [bsl(1, map.addr_width) - 4]

    for _ <- 1..n do
      a = Enum.random(addrs)

      if :rand.uniform(2) == 1,
        do:
          {:write, a, :rand.uniform(0x1_0000_0000) - 1,
           Enum.random([0xF, 0xF, 0x1, 0x6, 0x8, 0x0])},
        else: {:read, a}
    end
  end
end
