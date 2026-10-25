defmodule ExHdl.OFDM.Equaliser do
  @moduledoc """
  The equaliser kernel (`ExHdl.OFDM.Equalise`) as an AXI4-Stream block:
  FFT bins in, one constellation word per data carrier out.

      {:ok, eq} = ExHdl.OFDM.Equaliser.build(spec, name: "eq_qpsk")
      eq.module                 # ExHdl.RTL module `eq_qpsk`
      eq.design                 # the kernel's scan design (latency, DSP, memories)

  Ports:

    * `s_axis`: the FFT output of one symbol per `fft` beats in bin order
      (bin 0 first), `tdata = {im[15:0], re[15:0]}` in the data format
      (signed, q(16, 12) by default), `tlast` ignored. Symbols are
      numbered from reset: the first one is pilot class 0 (as
      `FixedFrontEnd.run/4` starts at a class 0 symbol), then 1, 2, ...
    * `m_axis`: the constellation word of every data carrier (`bits`
      wide), carriers ascending, `tlast` on the last one of a symbol.

  Inside: a writer fills the inactive bank of the kernel's frame memory
  (a skid buffer in front breaks the ready path), a sequencer walks the
  row schedule of the symbol's pilot class (`ExHdl.OFDM.Plan`) through the
  kernel, one row per clock, and swaps banks when the next symbol is in.
  While one symbol is read the next is written, so a symbol per `fft`
  clocks goes through; the 1688 rows of a DVB-T 2k symbol (176 pilots,
  1512 data carriers) leave 360 clocks of slack.
  """
  use ExHdl.RTL

  alias ExHdl.RTL.{Builder, Examples, Interface, Wrap}

  @doc """
  `{:ok, %{module:, design:, plan:}}` for a front end spec (see
  `ExHdl.OFDM.Plan`); options `:name` (module name, default
  `"ofdm_equaliser"`; the kernel is `<name>_kernel`), `:format`, `:coef`,
  and generator options for the kernel (`:family`, `:clock_mhz`, ...).
  """
  def build(spec, opts \\ []) do
    name = Keyword.get(opts, :name, "ofdm_equaliser")
    {fmt, gen} = Keyword.split(opts, [:format, :coef])
    gen = gen |> Keyword.delete(:name) |> Keyword.put(:name, name <> "_kernel")

    with {:ok, d} <- ExHdl.OFDM.Equalise.scan_to_sv(spec, fmt ++ gen) do
      plan = ExHdl.OFDM.Plan.build(spec, Keyword.take(fmt, [:coef]))
      {:ok, %{module: wrapper(name, d, plan, spec), design: d, plan: plan}}
    end
  end

  @doc "The kernel as a black box with the frame memory's write port (`Wrap.scan/2` has none)."
  def kernel_box(%ExHdl.Backends.SystemVerilog.Scan.Design{} = d) do
    [%{name: mem}] = d.memories
    [m] = d.memories
    true = d.params == [] and m.banks == 2 and m.clock == :shared and d.channels == 1
    s_axis = Wrap.scan_axis(d, :s_axis)
    m_axis = Wrap.scan_axis(d, :m_axis)

    black_box d.name, sources: %{"#{d.name}.sv" => d.source} do
      domain(:sys)
      input(:"#{mem}_waddr", u(m.addr_bits), domain: :sys)
      input(:"#{mem}_wdata", u(m.data_bits), domain: :sys)
      input(:"#{mem}_we", 1, domain: :sys)
      input(:"#{mem}_swap", 1, domain: :sys)
      output(:"#{mem}_pending", 1, domain: :sys, comb_from: :none)
      slave(:s_axis, s_axis, domain: :sys, comb_from: :none)
      master(:m_axis, m_axis, domain: :sys, comb_from: :none)
    end
  end

  defp wrapper(name, d, plan, spec) do
    fft = spec.ofdm.fft
    bits = spec.constellation.bits
    aw = Builder.ceil_log2(fft)
    Bitwise.bsl(1, aw) == fft or raise ArgumentError, "the FFT size must be a power of two"
    pw = max(Builder.ceil_log2(plan.total), 1)
    ends = for {base, rows} <- Enum.zip(plan.bases, plan.classes), do: base + length(rows) - 1
    s_iface = Interface.axi_stream(data: 32, keep: false)
    m_iface = Interface.axi_stream(data: bits, keep: false)
    skid = Examples.skid_buffer(s_iface)
    kernel = kernel_box(d)

    module name do
      s = slave(:s_axis, s_iface)
      m = master(:m_axis, m_iface)
      inbuf = instance(:inbuf, skid)
      k = instance(:k, kernel)
      connect(s, inbuf.s_axis)

      # writer: bins in arrival order into the inactive bank
      wcnt = reg(:wcnt, aw, reset: 0)
      wfull = reg(:wfull, 1, reset: 0)
      swap_q = reg(:swap_q, 1, reset: 0)
      run = reg(:run, 1, reset: 0)
      pos = reg(:pos, pw, reset: 0)
      can = wire(:can, not wfull and not k.frame_pending and not swap_q)
      accept = wire(:accept, inbuf.m_axis.tvalid and can)
      inbuf.m_axis.tready <~ can
      k.frame_waddr <~ wcnt
      k.frame_wdata <~ inbuf.m_axis.tdata
      k.frame_we <~ accept
      k.frame_swap <~ swap_q

      # sequencer: one row per clock through the kernel, symbol after symbol
      issue = wire(:issue, run and k.s_axis.tready)

      at_end =
        wire(
          :at_end,
          Enum.reduce(ends, nil, fn e, acc ->
            case acc do
              nil -> pos == e
              _ -> acc or pos == e
            end
          end)
        )

      k.s_axis.tvalid <~ run
      k.s_axis.tdata <~ zext(pos, 32)

      sync do
        if accept do
          wcnt <~ add_wrap(wcnt, 1)
          if wcnt == fft - 1, do: wfull <~ 1
        end

        if not run and not swap_q and wfull do
          swap_q <~ 1
          wfull <~ 0
        end

        if swap_q do
          swap_q <~ 0
          run <~ 1
        end

        if issue do
          pos <~ mux(pos == plan.total - 1, 0, add_wrap(pos, 1))
          if at_end, do: run <~ 0
        end
      end

      m.tvalid <~ k.m_axis.tvalid
      m.tdata <~ k.m_axis.tdata[0..(bits - 1)]
      m.tlast <~ k.m_axis.tdata[8]
      k.m_axis.tready <~ m.tready
    end
  end
end
