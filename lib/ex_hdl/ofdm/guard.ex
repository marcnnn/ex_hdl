defmodule ExHdl.OFDM.Guard do
  @moduledoc """
  Guard removal: of every `fft + cp` samples the first `cp` are dropped
  and the last of the remaining `fft` carries `tlast`, so the output is
  the symbols the FFT takes, one per `tlast`.

  AXI4-Stream `s_axis` and `m_axis` of `width` bits (any sample format),
  `s_axis_tlast` ignored. The first sample after reset is the first sample
  of a guard interval (the symbol boundary comes from the synchroniser).
  Dropped samples are accepted whenever they arrive; the output is a
  skid buffer, so no combinational path runs from `m_axis_tready` to
  `s_axis_tready`. Options: `:name`, `:width`, `:fft`, `:cp`.
  """
  use ExHdl.RTL

  alias ExHdl.RTL.{Builder, Examples, Interface}

  def build(opts) do
    name = Keyword.get(opts, :name, "ofdm_guard")
    width = Keyword.fetch!(opts, :width)
    fft = Keyword.fetch!(opts, :fft)
    cp = Keyword.fetch!(opts, :cp)
    sym = fft + cp
    iface = Interface.axi_stream(data: width, keep: false)

    module name do
      s = slave(:s_axis, iface)
      m = master(:m_axis, iface)
      out = instance(:out, Examples.skid_buffer(iface))
      pos = reg(:pos, max(Builder.ceil_log2(sym), 1), reset: 0)
      drop = wire(:drop, pos < cp)

      s.tready <~ (drop or out.s_axis.tready)
      out.s_axis.tvalid <~ (s.tvalid and not drop)
      out.s_axis.tdata <~ s.tdata
      out.s_axis.tlast <~ (pos == sym - 1)
      connect(out.m_axis, m)

      sync do
        if s.tvalid and (drop or out.s_axis.tready) do
          pos <~ mux(pos == sym - 1, 0, add_wrap(pos, 1))
        end
      end
    end
  end
end
