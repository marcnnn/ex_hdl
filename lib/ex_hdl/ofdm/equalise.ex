defmodule ExHdl.OFDM.Equalise do
  @moduledoc """
  Channel estimation, equalisation and hard decisions of
  `ExSdr.Comm.OFDM.FixedFrontEnd` as one stream kernel with a frame
  memory: the same arithmetic on the same quantised constants, one carrier
  per clock.

  The input beat is a row number of the schedule (`ExHdl.OFDM.Plan`: pilot
  and data carriers of every pilot class in interpolation order). The
  kernel reads the FFT output of that row's carrier from the memory `frame`
  (`fft` words of `{re, im}`, the data format; two banks, the FFT of the
  next symbol is written while this one is read):

    * a pilot row computes the channel at the pilot, `Y * conj(P) / |P|^2`
      (constants from a ROM, rescaled and saturated to the data format)
      and shifts it into the state: left neighbour <- right neighbour,
      right neighbour <- this one
    * a data row interpolates `h = l + (r - l) * w`, forms
      `z = Y * conj(h)` (`|h|^2` times the equalised point) and decides
      by sign for QPSK, by comparing with the decision boundaries times
      `|h|^2` for square QAM, and outputs the constellation word

  Outputs (variable rate, one lane): the word (`u8`) and `1` on the last
  carrier of a symbol; the count is 1 on data rows, 0 on pilot rows. All
  tables are constants (block RAM or LUT ROM); only `frame` is written at
  run time. `ExHdl.OFDM.Equaliser` wraps the kernel with the writer of the
  frame memory and the row sequencer.
  """
  import Nx.Defn
  alias NxFixed.{Fixed, Num}

  @doc "The kernel: `step(row, state, frame, opts)`, `opts` from `kernel_opts/2`."
  defn step(row, state, frame, opts \\ []) do
    opts = keyword!(opts, [:format, :coef, :square, :tables])
    equalise(row, state, frame, opts)
  end

  deftransformp equalise(row, {hlr, hli, hrr, hri}, frame, opts) do
    f = opts[:format]
    coef = opts[:coef]
    t = opts[:tables]
    take = fn table -> Nx.take(table, row) end
    [pilot?, bin, a, b, last] = Enum.map([:pilot, :bin, :a, :b, :last], &take.(Map.fetch!(t, &1)))

    y = Nx.take(frame, bin)
    yv = {fixed(y[0], f), fixed(y[1], f)}
    fx = fn x -> fixed(x, f) end

    # pilot: channel at this carrier
    h_new =
      yv
      |> Num.cmul({coef_value(a, coef), coef_value(b, coef)})
      |> Num.rescale(f)
      |> Num.quantize(f)

    # data: interpolation between the two held pilots
    {l, r} = {{fx.(hlr), fx.(hli)}, {fx.(hrr), fx.(hri)}}
    w = coef_value(a, coef)

    interp = fn l, r ->
      l |> Num.add(Num.rescale(Num.mul(Num.sub(r, l), w), f)) |> Num.quantize(f)
    end

    {hr, hi} = {interp.(elem(l, 0), elem(r, 0)), interp.(elem(l, 1), elem(r, 1))}
    {yr, yi} = yv
    zr = Num.add(Num.mul(yr, hr), Num.mul(yi, hi))
    zi = Num.sub(Num.mul(yi, hr), Num.mul(yr, hi))
    energy = fn -> Num.add(Num.mul(hr, hr), Num.mul(hi, hi)) end

    sq = opts[:square]
    i = axis_index(zr, energy, sq)
    q = axis_index(zi, energy, sq)
    word = Nx.bitwise_or(Nx.take(u8(sq.i_words), i), Nx.take(u8(sq.q_words), q))

    pilot = Nx.equal(pilot?, 1)
    keep = fn old, new -> Nx.select(pilot, Nx.as_type(new, :s32), old) end
    {nhr, nhi} = h_new

    state =
      {keep.(hlr, value(fx.(hrr))), keep.(hli, value(fx.(hri))), keep.(hrr, value(nhr)),
       keep.(hri, value(nhi))}

    {{{Nx.reshape(word, {1}), Nx.reshape(last, {1})}, Nx.as_type(Nx.equal(pilot?, 0), :s32)},
     state}
  end

  # level index 0..L-1: the number of boundaries b (-(L-2), ..., L-2) with
  # a * scale >= b * |h|^2 (ties to the larger level), as FixedFrontEnd
  defp axis_index(a, energy, %{levels: l, scale: scale}) do
    bounds = Enum.to_list(-(l - 2)..(l - 2)//2)

    if bounds == [0] do
      Nx.greater_equal(value(a), 0) |> Nx.as_type(:s32)
    else
      {lhs, e, k} = scaled(a, energy.(), scale)

      bounds
      |> Enum.map(&Nx.greater_equal(lhs, Nx.multiply(e, &1 * k)))
      |> Enum.map(&Nx.as_type(&1, :s32))
      |> Enum.reduce(&Nx.add/2)
    end
  end

  defp scaled(%Fixed{t: a}, %Fixed{t: e}, scale),
    do: {Nx.multiply(Nx.as_type(a, :s64), round(scale * 1024)), Nx.as_type(e, :s64), 1024}

  defp fixed(t, %Num.Format{frac: frac}), do: %Fixed{t: Nx.as_type(t, :s32), frac: frac}
  defp coef_value(t, %Num.Format{frac: frac}), do: %Fixed{t: t, frac: frac}
  defp value(%Fixed{t: t}), do: t
  defp value(t), do: t
  defp u8(list), do: Nx.tensor(list, type: :u8, backend: Nx.BinaryBackend)

  @doc """
  Options of the kernel for a `plan` (`ExHdl.OFDM.Plan.build/2`) and a
  `spec` (the constellation's `square` tables): `:format` (data, default
  q(16, 12)), `:coef` (q(16, 15)).
  """
  def kernel_opts(plan, spec, opts \\ []) do
    f = Keyword.get(opts, :format, Num.q(16, 12))
    coef = Keyword.get(opts, :coef, Num.q(16, 15, lut_bits: 12))
    rows = List.flatten(plan.classes)

    col = fn key, type ->
      rows |> Enum.map(key) |> Nx.tensor(type: type, backend: Nx.BinaryBackend)
    end

    b2i = fn
      true -> 1
      false -> 0
    end

    tables = %{
      pilot: col.(&if(&1.kind == :pilot, do: 1, else: 0), :u8),
      bin: col.(& &1.bin, :s32),
      a: col.(& &1.a, :s32),
      b: col.(& &1.b, :s32),
      last: col.(&b2i.(&1.last), :u8)
    }

    [format: f, coef: coef, square: spec.constellation.square, tables: tables]
  end

  @doc "Argument templates for `ExHdl.DSP.analyze_scan/3` (state is argument 1)."
  def args(plan, kernel_opts, fft) do
    _ = plan
    s32 = Nx.template({}, :s32)
    [s32, {s32, s32, s32, s32}, Nx.template({fft, 2}, :s16), kernel_opts]
  end

  @doc """
  The module of the kernel (`ExHdl.DSP.scan_to_sv/3`). `spec` is the front
  end spec of `ExHdl.OFDM.Plan`; options `:format`, `:coef`, `:fft`
  (frame memory words, default `spec.ofdm.fft`), the rest goes to the
  generator (`:name`, `:family`, `:clock_mhz`, ...).
  """
  def scan_to_sv(spec, opts \\ []) do
    {fmt, gen} = Keyword.split(opts, [:format, :coef])
    plan = ExHdl.OFDM.Plan.build(spec, Keyword.take(fmt, [:coef]))
    kopts = kernel_opts(plan, spec, fmt)

    gen =
      Keyword.merge(
        [
          name: "ofdm_equalise",
          state: 1,
          init:
            {Nx.tensor(0, type: :s32), Nx.tensor(0, type: :s32), Nx.tensor(0, type: :s32),
             Nx.tensor(0, type: :s32)},
          param_names: ["frame"],
          memories: ["frame"],
          param_ranges: %{0 => 0..(plan.total - 1)},
          lanes: 1,
          ii: 1
        ],
        gen
      )

    fft = Keyword.get(gen, :fft, spec.ofdm.fft)
    ExHdl.DSP.scan_to_sv(&step/4, args(plan, kopts, fft), Keyword.delete(gen, :fft))
  end
end
