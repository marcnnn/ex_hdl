defmodule ExHdl.OFDM.FrontEnd do
  @moduledoc """
  `ExSdr.Comm.OFDM.FixedFrontEnd` as one AXI4-Stream pipeline, everything
  but the FFT:

      sc16 samples -> Correct -> Guard -> [FFT] -> Equaliser -> Permute (cells)
        -> Unpack -> Permute (bits) -> code bits

  | Stage | Module | Notes |
  |---|---|---|
  | frequency correction | `ExHdl.OFDM.Correct` | stream kernel, 1 sample per clock, DSP slices 4 |
  | guard removal, `tlast` per symbol | `ExHdl.OFDM.Guard` | |
  | channel estimate, equaliser, decisions | `ExHdl.OFDM.Equaliser` | frame kernel, double-buffered symbol RAM |
  | symbol (cell) deinterleaver | `ExHdl.OFDM.Permute` | `spec.cells` |
  | bit unpacking | `ExHdl.OFDM.Unpack` | |
  | bit deinterleaver | `ExHdl.OFDM.Permute` | `spec.bits` |

  `build(spec, opts)` returns `{:ok, %{module:, equaliser:, ...}}`. The
  module's ports:

    * `s_axis`: `sc16` samples, `tdata = {im[15:0], re[15:0]}` (signed Q15,
      full scale 1.0), `tlast` ignored. The first sample after reset is the
      first sample of the guard interval of a symbol of pilot class 0
      (the synchroniser's job); chunking is free, the phase of the
      correction runs on across beats.
    * `inc`, `phase0`, `load`: the correction's phase word per sample
      (`FixedFrontEnd.phase_increment/2`) and the word at the first
      sample (`ExHdl.OFDM.Correct.phase0/2`); a cycle with `load` high
      captures them, they apply from the next sample accepted.
    * `m_axis`: the code bits (one bit per beat, 0 or 1, as the `u8`
      bytes of `FixedFrontEnd.run/4`), `tlast` on the last bit of every
      bit-interleaver block (126 words of the constellation).

  ## Composition point for the FFT

  Between guard removal and the equaliser the design has two AXI4-Stream
  connections, both `tdata = {im[15:0], re[15:0]}`, signed, in the data
  format (default q(16, 12)), one beat per sample or bin:

    * to the FFT (`fft_in`, master): the `fft` samples of a symbol with
      `tlast` on the last. Time order, cyclic prefix removed, corrected.
    * from the FFT (`fft_out`, slave): the `fft` bins of the symbol in
      natural order (bin 0 first), `tlast` ignored, any gap between
      symbols (the equaliser needs the whole symbol, so it buffers).

  The FFT must compute what `ExSdr.DSP.FFT.fft/2` does with
  `shifts: 5`: radix-2, twiddles `exp(-i pi k / m)` in the coefficient
  format (q(16, 15)), each twiddle product rescaled to the data format
  with `Num.rescale` rounding, every stage saturated to the data format,
  the last five stages halved with rounding (output DFT / 32).

  With `fft: :hardware` the streaming FFT of `ExHdl.FFT` is generated for
  the format (`:shifts`, default 5) and instantiated between them;
  `fft: module` takes any `ExHdl.RTL` module with bundles `s_axis` and
  `m_axis` of that kind; with `fft: nil` (default) the two connections
  are the ports `fft_in_*` (outputs) and `fft_out_*` (inputs), as a test
  bench or a larger design wants them.
  """
  use ExHdl.RTL

  alias ExHdl.OFDM.{Correct, Equaliser, Guard, Permute, Unpack}
  alias ExHdl.RTL.{Interface, Wrap}

  @doc """
  Options: `:name` (default `"ofdm_front_end"`), `:fft` (see above),
  `:shifts` (halving stages of the FFT, default 5), `:format`, `:coef` (as
  `ExHdl.OFDM.Correct.default_opts/0`), `:family`, `:clock_mhz` (for the
  kernels).
  """
  def build(spec, opts \\ []) do
    name = Keyword.get(opts, :name, "ofdm_front_end")
    fmt = Keyword.take(opts, [:format, :coef])
    gen = Keyword.take(opts, [:family, :clock_mhz])
    o = spec.ofdm
    v = spec.constellation.bits

    with {:ok, correct} <- Correct.scan_to_sv(fmt ++ gen ++ [name: name <> "_correct"]),
         {:ok, eq} <- Equaliser.build(spec, fmt ++ gen ++ [name: name <> "_eq"]) do
      guard = Guard.build(name: name <> "_guard", width: 32, fft: o.fft, cp: o.cp)

      cells =
        spec.cells &&
          Permute.build(name: name <> "_cells", width: v, tables: tables(spec.cells))

      unpack = Unpack.build(name: name <> "_unpack", bits: v)

      bits =
        spec.bits &&
          Permute.build(name: name <> "_bits", width: 1, tables: tables(spec.bits))

      {:ok, fft_module, fft_design} = fft(Keyword.get(opts, :fft), spec, opts)

      top = %{
        name: name,
        fft: fft_module,
        correct: correct,
        guard: guard,
        eq: eq.module,
        cells: cells,
        unpack: unpack,
        bits: bits,
        v: v
      }

      {:ok,
       %{
         module: wrapper(top),
         correct: correct,
         equaliser: eq,
         fft: fft_design,
         submodules: %{guard: guard, cells: cells, unpack: unpack, bits: bits}
       }}
    end
  end

  defp fft(:hardware, spec, opts) do
    f = Keyword.get(opts, :format, Correct.default_opts()[:format])
    tw = Keyword.get(opts, :coef, Correct.default_opts()[:coef])

    gen = [
      format: f,
      twiddle: tw,
      shifts: Keyword.get(opts, :shifts, 5),
      name: "#{opts[:name] || "ofdm_front_end"}_fft"
    ]

    with {:ok, d} <- ExHdl.FFT.generate(spec.ofdm.fft, gen), do: {:ok, fft_box(d), d}
  end

  defp fft(other, _spec, _opts), do: {:ok, other, nil}

  # a generated FFT (a stream design with frame sideband) as a black box
  defp fft_box(d) do
    s_iface = Interface.axi_stream(data: d.in_width, keep: false)
    m_iface = Interface.axi_stream(data: d.out_width, keep: false)

    (d.in_width == 32 and d.out_width == 32) or
      raise ArgumentError, "the FFT must take 32-bit samples"

    black_box d.name, sources: %{"#{d.name}.sv" => d.source} do
      domain(:sys)
      slave(:s_axis, s_iface, domain: :sys, comb_from: :none)
      master(:m_axis, m_iface, domain: :sys, comb_from: :none)
    end
  end

  defp tables(p), do: Enum.map(p.tables, &Tuple.to_list/1)

  defp wrapper(t) do
    s32 = Interface.axi_stream(data: 32, keep: false)
    b1 = Interface.axi_stream(data: 1, keep: false)
    kernel = Wrap.scan(t.correct)

    module t.name do
      s = slave(:s_axis, s32)
      m = master(:m_axis, b1)
      inc = input(:inc, 32, domain: :static)
      phase0 = input(:phase0, 32, domain: :static)
      load = input(:load, 1)

      {fft_to, fft_from} =
        if t.fft do
          f = instance(:fft, t.fft)
          {f.s_axis, f.m_axis}
        else
          {master(:fft_in, s32), slave(:fft_out, s32)}
        end

      # correction
      k = instance(:correct, kernel)
      k.p_inc <~ zext(inc, 64)
      k.p_phase0 <~ zext(phase0, 64)
      k.p_load <~ load
      k.s_axis.tdata <~ s.tdata
      k.s_axis.tvalid <~ s.tvalid
      s.tready <~ k.s_axis.tready

      # guard removal, to the FFT
      g = instance(:guard, t.guard)
      g.s_axis.tdata <~ k.m_axis.tdata
      g.s_axis.tvalid <~ k.m_axis.tvalid
      g.s_axis.tlast <~ 0
      k.m_axis.tready <~ g.s_axis.tready
      connect(g.m_axis, fft_to)

      # equaliser, deinterleavers, bits
      eq = instance(:eq, t.eq)
      connect(fft_from, eq.s_axis)

      to_unpack =
        if t.cells do
          c = instance(:cells, t.cells)
          connect(eq.m_axis, c.s_axis)
          c.m_axis
        else
          eq.m_axis
        end

      u = instance(:unpack, t.unpack)
      connect(to_unpack, u.s_axis)

      if t.bits do
        b = instance(:bits, t.bits)
        connect(u.m_axis, b.s_axis)
        connect(b.m_axis, m)
      else
        connect(u.m_axis, m)
      end
    end
  end
end
