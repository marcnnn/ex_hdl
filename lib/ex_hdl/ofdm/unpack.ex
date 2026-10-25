defmodule ExHdl.OFDM.Unpack do
  @moduledoc """
  Bit unpacking: a `bits`-bit word becomes `bits` one-bit items, the most
  significant first (`FixedFrontEnd`'s `code_bits`), one bit per clock.
  `tlast` of a word goes with its last bit.

  `s_axis` carries words (`tdata`, `tlast`), `m_axis` single bits. A word
  is accepted in the clock its last bit leaves, so a stream of words never
  stalls the bit stream; the output is a skid buffer. Options: `:name`,
  `:bits`.
  """
  use ExHdl.RTL

  alias ExHdl.RTL.{Builder, Examples, Interface}

  def build(opts) do
    name = Keyword.get(opts, :name, "ofdm_unpack")
    v = Keyword.fetch!(opts, :bits)
    s_iface = Interface.axi_stream(data: v, keep: false)
    m_iface = Interface.axi_stream(data: 1, keep: false)

    module name do
      s = slave(:s_axis, s_iface)
      m = master(:m_axis, m_iface)
      out = instance(:out, Examples.skid_buffer(m_iface))
      hold = reg(:hold, v, reset: 0)
      busy = reg(:busy, 1, reset: 0)
      last = reg(:last, 1, reset: 0)
      idx = reg(:idx, max(Builder.ceil_log2(v), 1), reset: 0)
      adv = wire(:adv, out.s_axis.tready)
      end_of_word = wire(:end_of_word, idx == v - 1)
      take = wire(:take, s.tvalid and (not busy or (adv and end_of_word)))
      s.tready <~ (not busy or (adv and end_of_word))

      out.s_axis.tvalid <~ busy
      out.s_axis.tdata <~ hold[v - 1]
      out.s_axis.tlast <~ (busy and last and end_of_word)
      connect(out.m_axis, m)

      sync do
        if busy and adv do
          hold <~ trunc(hold <<< 1, v)
          idx <~ add_wrap(idx, 1)
          if end_of_word, do: busy <~ 0
        end

        if take do
          hold <~ s.tdata
          last <~ s.tlast
          idx <~ 0
          busy <~ 1
        end
      end
    end
  end
end
