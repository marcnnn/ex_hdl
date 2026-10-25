defmodule ExHdl.OFDM.Permute do
  @moduledoc """
  Frame permutation in hardware: output item `j` of a block of `n` items is
  input item `table[j]` of that block, one item per clock in and out, the
  `ExSdr.Comm.Permutation` gather. With several tables block `i` uses
  table `rem(i, count)` (the DVB-T symbol interleaver alternates between H
  and its inverse).

      Permute.build(name: "cells", width: 2, tables: [h_inverse, h])

  The module has an AXI4-Stream slave `s_axis` and master `m_axis` of
  `width`-bit items (`tdata`, `tlast`, `tvalid`, `tready`):

    * A block RAM of two banks of `n` items: the writer fills one bank in
      arrival order while the reader drains the other, so a steady stream
      loses no cycle; a bank is handed over when its last item is in
      (`tready` drops only when both banks are full).
    * One ROM of `count * n` addresses; its counter runs through the
      tables in turn, so the table select needs no extra logic. Read
      address, RAM read and output register are one pipeline with one clock
      enable, which is the `tready` of a skid buffer at the output (no
      combinational path from `m_axis_tready` to `s_axis_tready`).
    * `m_axis_tlast` marks the last item of every block. `s_axis_tlast` is
      ignored: blocks are `n` items, and the first block after reset
      uses table `first_block` (default 0).

  Latency is `n` items (the block must be complete) plus 4 clocks. Options:
  `:name`, `:width`, `:tables` (lists of equal length, each a permutation
  of `0..n-1`), `:first_block`, `:style` of the data RAM (`:block`, default).
  """
  use ExHdl.RTL

  alias ExHdl.RTL.{Builder, Examples, Interface}

  @doc "The module; see the module documentation."
  def build(opts) do
    name = Keyword.fetch!(opts, :name)
    width = Keyword.fetch!(opts, :width)
    tables = Keyword.fetch!(opts, :tables)
    first = Keyword.get(opts, :first_block, 0)
    style = Keyword.get(opts, :style, :block)

    [n] = tables |> Enum.map(&length/1) |> Enum.uniq()

    for t <- tables,
        do: Enum.sort(t) == Enum.to_list(0..(n - 1)) or raise(ArgumentError, "not a permutation")

    count = length(tables)
    rom_depth = count * n
    aw = max(Builder.ceil_log2(n), 1)
    ra = max(Builder.ceil_log2(rom_depth), 1)
    iface = Interface.axi_stream(data: width, keep: false)
    rom = List.flatten(tables)

    module "permute_#{name}" do
      s = slave(:s_axis, iface)
      m = master(:m_axis, iface)

      ram = memory(:ram, width: width, depth: 1 <<< (aw + 1), style: style)
      rom = memory(:rom, width: aw, depth: max(rom_depth, 2), init: rom)

      # writer: arrival order into bank wbank
      wcnt = reg(:wcnt, aw, reset: 0)
      wbank = reg(:wbank, 1, reset: 0)
      full0 = reg(:full0, 1, reset: 0)
      full1 = reg(:full1, 1, reset: 0)
      wfull = wire(:wfull, mux(wbank == 1, full1, full0))
      accept = wire(:accept, s.tvalid and not wfull)
      wlast = wire(:wlast, wcnt == n - 1)
      s.tready <~ not wfull
      write_port(ram, addr: cat([wbank, wcnt]), data: s.tdata, en: accept)

      # reader: table counter, ROM, RAM, output buffer, one clock enable
      out = instance(:out, Examples.skid_buffer(iface))
      adv = wire(:adv, out.s_axis.tready)
      rbank = reg(:rbank, 1, reset: 0)
      rcnt = reg(:rcnt, aw, reset: 0)
      raddr = reg(:raddr, ra, reset: rem(first * n, rom_depth))
      rfull = wire(:rfull, mux(rbank == 1, full1, full0))
      issue = wire(:issue, rfull and adv)
      s1v = reg(:s1v, 1, reset: 0)
      s1_bank = reg(:s1_bank, 1, reset: 0)
      s1_last = reg(:s1_last, 1, reset: 0)
      s2v = reg(:s2v, 1, reset: 0)
      s2_last = reg(:s2_last, 1, reset: 0)
      index = read_port(rom, addr: raddr, en: adv)
      item = read_port(ram, addr: cat([s1_bank, index]), en: adv)
      retire = wire(:retire, adv and s1v and s1_last)

      sync do
        if accept do
          if wlast do
            wcnt <~ 0
            wbank <~ not wbank
          else
            wcnt <~ add_wrap(wcnt, 1)
          end
        end

        if accept and wlast and wbank == 0, do: full0 <~ 1
        if accept and wlast and wbank == 1, do: full1 <~ 1
        if retire and s1_bank == 0, do: full0 <~ 0
        if retire and s1_bank == 1, do: full1 <~ 0

        if adv do
          s1v <~ issue
          s1_bank <~ rbank
          s1_last <~ (rcnt == n - 1)
          s2v <~ s1v
          s2_last <~ s1_last

          if issue do
            raddr <~ mux(raddr == rom_depth - 1, 0, add_wrap(raddr, 1))
            rcnt <~ mux(rcnt == n - 1, 0, add_wrap(rcnt, 1))
            if rcnt == n - 1, do: rbank <~ not rbank
          end
        end
      end

      out.s_axis.tvalid <~ s2v
      out.s_axis.tdata <~ item
      out.s_axis.tlast <~ s2_last
      connect(out.m_axis, m)
    end
  end
end
