defmodule ExHdl.Test.OFDMRef do
  @moduledoc false
  # The stages of ExSdr.Comm.OFDM.FixedFrontEnd as separate functions, for
  # the hardware tests: the same Nx code as its private graph/5 and
  # class_words/6 (copied, with the front end's own prepared tables), cut at
  # the stage boundaries. `bits/3` chains them; the test compares that with
  # FixedFrontEnd.run/4 on the same samples, so the pieces are the front end.
  import Bitwise
  alias ExSdr.Comm.OFDM
  alias ExSdr.Comm.OFDM.FixedFrontEnd
  alias ExSdr.DSP.FFT
  alias NxFixed.{Fixed, Num}
  alias NxFixed.Primitives, as: P

  @cache {__MODULE__, :signal}

  @doc """
  `symbols` OFDM symbols of the DVB-T test signal (ExSdr's transmitter on
  the TestSignal transport stream), 2k, 1/32 guard, with a carrier offset
  and noise: `{sc16 samples as an s16 tensor, freq_offset}`.
  """
  def signal(constellation, symbols, opts \\ []) do
    key = {@cache, constellation, symbols, opts}

    case :persistent_term.get(key, nil) do
      nil ->
        alias ExSdr.DVBT.{Channel, OFDM, TestSignal, Transmitter}
        o = [constellation: constellation, code_rate: {1, 2}, guard_interval: {1, 32}, cell_id: 0]
        ts = TestSignal.ts_packets(168)
        x = ts |> Transmitter.symbols(o) |> Enum.take(symbols) |> OFDM.modulate(o)
        cfo = Keyword.get(opts, :cfo, 0.37)
        snr = Keyword.get(opts, :snr, 12.0)
        x = x |> Channel.frequency_offset(cfo) |> Channel.awgn(snr, 42)
        v = {FixedFrontEnd.to_sc16(x, 0.47), -cfo}
        :persistent_term.put(key, v)
        v

      v ->
        v
    end
  end

  @doc "Frequency correction: `{re, im}` Fixed in the data format (as in FixedFrontEnd.graph/5)."
  def correct(sc16, inc, phase0, opts \\ []) do
    {f, coef} = formats(opts)
    mask = 0xFFFFFFFF
    n = div(Nx.size(sc16), 2)
    pairs = Nx.reshape(sc16, {:auto, 2})

    col = fn c ->
      %Fixed{t: pairs |> Nx.slice_along_axis(c, 1, axis: 1) |> Nx.squeeze(axes: [1]), frac: 15}
    end

    phase =
      Nx.iota({n}, type: :s64)
      |> Nx.multiply(Bitwise.band(inc, mask))
      |> Nx.add(Bitwise.band(phase0, mask))
      |> Nx.bitwise_and(mask)

    {cos, sin} =
      phase
      |> Nx.right_shift(16)
      |> Nx.as_type(:u16)
      |> P.lut_sincos_q15(bits: coef.lut_bits, amplitude: (1 <<< coef.frac) - 1, round: true)

    nco = {%Fixed{t: cos, frac: coef.frac}, %Fixed{t: sin, frac: coef.frac}}
    {col.(0), col.(1)} |> Num.cmul(nco) |> Num.rescale(f) |> Num.quantize(f)
  end

  @doc "Guard removal: `{symbols, fft}` views of the corrected samples."
  def strip({re, im}, spec, n) do
    o = spec.ofdm
    sym = o.fft + o.cp
    cut = fn t -> t |> Nx.reshape({n, sym}) |> Nx.slice_along_axis(o.cp, o.fft, axis: 1) end
    {map(re, cut), map(im, cut)}
  end

  @doc "The FFT of `{n, fft}` symbols as FixedFrontEnd runs it."
  def fft(x, opts \\ []) do
    {f, coef} = formats(opts)
    FFT.fft(x, format: f, twiddle: coef, shifts: Keyword.get(opts, :shifts, 5))
  end

  @doc """
  Hard decisions of every data carrier: a `{n, data}` u8 tensor of constellation
  words; `tables` from `FixedFrontEnd.prepare/3` for `n` symbols.
  """
  def words({re, im}, spec, tables, n, opts \\ []) do
    {f, coef} = formats(opts)
    flat = {map(re, &Nx.flatten/1), map(im, &Nx.flatten/1)}
    period = OFDM.period(spec.ofdm)

    for p <- 0..(period - 1) do
      class_words(flat, tables, p, f, coef, spec.constellation)
    end
    |> Enum.map(&Nx.new_axis(&1, 1))
    |> Nx.concatenate(axis: 1)
    |> Nx.reshape({n, :auto})
  end

  @doc "Cell deinterleaver, bit unpacking, bit deinterleaver, as the end of FixedFrontEnd.graph/5."
  def code_bits(words, tables, constellation, spec) do
    words = if spec.cells, do: take_in(Nx.flatten(words), tables.cells), else: words
    v = constellation.bits
    shifts = Nx.tensor(Enum.to_list((v - 1)..0//-1), type: :u8, backend: Nx.BinaryBackend)

    bits =
      words
      |> Nx.flatten()
      |> Nx.new_axis(1)
      |> Nx.right_shift(Nx.new_axis(shifts, 0))
      |> Nx.bitwise_and(1)
      |> Nx.as_type(:u8)
      |> Nx.flatten()

    if spec.bits, do: take_in(bits, Nx.flatten(tables.bits)), else: bits
  end

  # -- FixedFrontEnd.class_words/6 and helpers, unchanged -------------------------------

  defp class_words(flat, t, p, f, coef, constellation) do
    take = fn idx -> map2(flat, &take_in(&1, idx)) end
    inv = {coef_value(elem(t.inv_re, p), coef), coef_value(elem(t.inv_im, p), coef)}
    {groups, pilots} = Nx.shape(elem(t.pilot, p))

    h_pilots =
      take.(elem(t.pilot, p))
      |> Num.cmul(map2(inv, &Nx.reshape(&1, {1, pilots})))
      |> Num.rescale(f)
      |> Num.quantize(f)
      |> map2(&Nx.flatten/1)

    l_idx = Nx.clip(elem(t.left, p), 0, groups * pilots - 2)
    left = map2(h_pilots, &Nx.take(&1, l_idx))
    right = map2(h_pilots, &Nx.take(&1, Nx.add(l_idx, 1)))
    w = coef_value(elem(t.weight, p), coef) |> view(&Nx.reshape(&1, {1, :auto}))

    interp = fn l, r ->
      l |> Num.add(Num.rescale(Num.mul(Num.sub(r, l), w), f)) |> Num.quantize(f)
    end

    {hr, hi} = {interp.(elem(left, 0), elem(right, 0)), interp.(elem(left, 1), elem(right, 1))}
    {yr, yi} = take.(elem(t.data, p))
    zr = Num.add(Num.mul(yr, hr), Num.mul(yi, hi))
    zi = Num.sub(Num.mul(yi, hr), Num.mul(yr, hi))
    energy = fn -> Num.add(Num.mul(hr, hr), Num.mul(hi, hi)) end

    sq = constellation.square
    i = axis_index(zr, energy, sq)
    q = axis_index(zi, energy, sq)
    Nx.bitwise_or(Nx.take(u8(sq.i_words), i), Nx.take(u8(sq.q_words), q))
  end

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

  defp take_in(table, idx), do: Nx.take(table, Nx.clip(idx, 0, Nx.size(table) - 1))
  defp u8(list), do: Nx.tensor(list, type: :u8, backend: Nx.BinaryBackend)
  defp coef_value(t, %Num.Format{} = c), do: %Fixed{t: t, frac: c.frac}
  defp map(%Fixed{} = x, fun), do: view(x, fun)
  defp map2({a, b}, fun), do: {view(a, fun), view(b, fun)}
  defp value(%Fixed{t: t}), do: t
  defp value(t), do: t
  defp view(%Fixed{} = x, fun), do: %{x | t: fun.(x.t)}
  defp view(t, fun), do: fun.(t)

  defp formats(opts) do
    d = FixedFrontEnd.default_opts()
    {Keyword.get(opts, :format, d[:format]), Keyword.get(opts, :coef, d[:coef])}
  end
end
