defmodule ExHdl.FFT do
  @moduledoc """
  Streaming pipeline FFT and IFFT in hardware, bit-exact with
  `ExSdr.DSP.FFT.fft/2` (radix-2 decimation in time, Stockham order).

      {:ok, design} = ExHdl.FFT.generate(2048, format: NxFixed.Num.q(16, 15), shifts: 11)
      File.write!("fft2k.sv", design.source)

  ## Interface

  The module (`design.name`, default `"fft<n>"`) is an AXI4-Stream block
  with one clock (`clk`, active-low synchronous `rst_n`):

    * `s_axis_tdata`: one complex sample per beat, `{im, re}`: `re` in bits
      `[B-1:0]`, `im` in `[2B-1:B]` (`B` the format's bits, signed), padded
      with zeros to a multiple of 8 bits (`design.in_width`).
      `s_axis_tlast` is accepted and ignored: the module counts `n`
      samples per symbol from reset.
    * `m_axis_tdata`: the same layout (`design.out_width`), `n` beats per
      symbol, `m_axis_tlast` on the last.
    * `s_axis_tready` is registered logic (no combinational path from
      `m_axis_tready`); the module takes one sample per clock and gives one
      per clock while the output is ready.

  Symbols can follow each other without a gap, and a symbol leaves the
  module without waiting for the next one: `design.latency` is the number
  of cycles from the last sample of a symbol to the last output of its
  transform (about `2n` in natural order, `n` in bit-reversed order),
  without stalls.

  ## Options (`generate/2`, `spec/2`)

    * `:format` - data format, `NxFixed.Num.q/3` (bits, frac, rounding);
      required.
    * `:twiddle` - twiddle format (default `:format`).
    * `:shifts` - the last `shifts` stages halve their outputs (rounded per
      format): the result is DFT / 2^shifts (default 0).
    * `:inverse` - IFFT (default false): `swap(fft(swap(x)))` with
      `swap({re, im}) = {im, re}`, the unnormalised inverse DFT with the
      same butterflies and rounding (`model/2` is the reference).
    * `:order` - `:natural` (default) or `:bit_reversed` (output `p` is
      bin `bitrev(p)`; no reorder buffer, half the latency, less memory).
    * `:name` - module name.

  ## Architecture

  One radix-2 single-path delay-feedback (SDF) stage per FFT stage, so
  every stage computes exactly the butterflies of the reference: stage
  `s` (`m = 2^s`) joins `a = X_m[k][c]` and `b = X_m[k][c + h]` (`h =
  n / 2m`) into `a + w b` and `a - w b` with `w = exp(-i pi k / m)` in the
  twiddle format, the product rounded to the data format (`rescale`), the
  sums halved in the last `shifts` stages and saturated (`quantize`).
  Stage 0 has no multiplier (`w = 1`, as in the reference); every other
  stage has four DSP multipliers, also for `k = 0`, since the quantized
  `w^0` is `2^frac - 1`, not 1. Radix-2^2 would move twiddle products
  between stages and change the rounding, so it is not used.

  The input comes in natural order. Stage `s` takes blocks of `2h`
  samples (one row `k` of the reference, rows in bit-reversed order): the
  first `h` are stored, each of the next `h` meets its partner, the sum
  leaves at once and the difference is stored and leaves after the
  block. Each stage has its own memory for the first halves and one for
  the differences (block RAM for long stages, LUT RAM or registers for
  short ones, chosen by synthesis; stages from 256 words per half share
  one memory for both) and a twiddle ROM of `m` entries.
  Differences leave in free cycles, so the stage does not need the next
  block to push them out. The pipeline gives the bins in bit-reversed
  order; with `order: :natural` a reorder buffer of `n` words (one
  memory: frames alternate between writing in natural and in
  bit-reversed address order, reading the other way) puts them in
  natural order.

  All registers share one clock enable from a small output buffer, as in
  the other generated stream modules.
  """

  import Bitwise

  alias NxFixed.Num
  alias NxFixed.Num.Format

  defstruct [:n, :stages, :format, :twiddle, :shifts, :inverse, :order]

  @type t :: %__MODULE__{
          n: pos_integer(),
          stages: pos_integer(),
          format: Format.t(),
          twiddle: Format.t(),
          shifts: non_neg_integer(),
          inverse: boolean(),
          order: :natural | :bit_reversed
        }

  @doc """
  Validates the parameters of an `n`-point transform (`n` a power of two,
  2 to 65536). Returns `{:ok, %ExHdl.FFT{}}` or `{:error, message}`.
  """
  def spec(n, opts) do
    opts =
      Keyword.validate!(opts, [
        :format,
        :twiddle,
        :name,
        shifts: 0,
        inverse: false,
        order: :natural
      ])

    f = opts[:format]
    tw = opts[:twiddle] || f
    stages = if is_integer(n) and n >= 2, do: bit_len(n) - 1, else: 0

    cond do
      not (is_integer(n) and n >= 2 and n <= 65_536 and 1 <<< stages == n) ->
        {:error, "fft: n must be a power of two in 2..65536, got #{inspect(n)}"}

      not match?(%Format{kind: :fixed}, f) ->
        {:error, "fft: :format must be a fixed-point NxFixed.Num.q/3 format"}

      not match?(%Format{kind: :fixed}, tw) ->
        {:error, "fft: :twiddle must be a fixed-point NxFixed.Num.q/3 format"}

      opts[:shifts] not in 0..stages ->
        {:error, "fft: :shifts must be in 0..#{stages}"}

      opts[:order] not in [:natural, :bit_reversed] ->
        {:error, "fft: :order must be :natural or :bit_reversed"}

      true ->
        {:ok,
         %__MODULE__{
           n: n,
           stages: stages,
           format: f,
           twiddle: tw,
           shifts: opts[:shifts],
           inverse: opts[:inverse] == true,
           order: opts[:order]
         }}
    end
  end

  @doc """
  Generates the module (see the moduledoc). Returns
  `{:ok, %ExHdl.Backends.SystemVerilog.Scan.Design{}}` (with `frame: true`,
  `dsp` the multiplier count) or `{:error, message}`.
  """
  def generate(n, opts) do
    name = Keyword.get(opts, :name, "fft#{n}")

    with {:ok, spec} <- spec(n, opts) do
      {:ok, ExHdl.Backends.SystemVerilog.FFT.generate(spec, name: name)}
    end
  end

  @doc """
  The twiddles of stage `s` (`m = 2^s`), `w^k = exp(-i pi k / m)` for
  `k = 0..m-1`, as `{re, im}` integers of the twiddle format, exactly as
  `ExSdr.DSP.FFT` quantizes them.
  """
  def twiddles(%__MODULE__{twiddle: tw}, s) do
    m = 1 <<< s
    angles = for k <- 0..(m - 1), do: -:math.pi() * k / m
    re = Num.quantize_constants(Enum.map(angles, &:math.cos/1), tw)
    im = Num.quantize_constants(Enum.map(angles, &:math.sin/1), tw)
    Enum.zip(re, im)
  end

  @doc """
  Bit-exact integer model of the generated hardware (and of
  `ExSdr.DSP.FFT.fft/2`, swapped for `inverse: true`): `{re, im}` lists of
  `n` integers of the data format in, `{re, im}` in natural order out.
  """
  def model(%__MODULE__{n: n} = spec, {re, im}) when length(re) == n and length(im) == n do
    {re, im} = if spec.inverse, do: {im, re}, else: {re, im}
    x = Enum.zip(re, im) |> List.to_tuple()

    x =
      Enum.reduce(0..(spec.stages - 1), x, fn s, x -> stage(spec, x, s) end)
      |> Tuple.to_list()

    {re, im} = Enum.unzip(x)
    if spec.inverse, do: {im, re}, else: {re, im}
  end

  defp stage(%__MODULE__{n: n} = spec, x, s) do
    m = 1 <<< s
    half = div(n, 2 * m)
    w = twiddles(spec, s) |> List.to_tuple()
    halve? = s >= spec.stages - spec.shifts

    pairs =
      for k <- 0..(m - 1), c <- 0..(half - 1) do
        a = elem(x, k * 2 * half + c)
        b = elem(x, k * 2 * half + c + half)
        {top, bottom} = butterfly(spec, a, b, if(s == 0, do: nil, else: elem(w, k)), halve?)
        [{k * half + c, top}, {(k + m) * half + c, bottom}]
      end

    pairs |> List.flatten() |> Enum.sort() |> Enum.map(&elem(&1, 1)) |> List.to_tuple()
  end

  @doc false
  # One butterfly: {a + w b, a - w b} with the reference's rounding.
  def butterfly(%__MODULE__{format: f, twiddle: tw}, {ar, ai}, {br, bi}, w, halve?) do
    {tr, ti} =
      case w do
        nil ->
          {br, bi}

        {wr, wi} ->
          {round_shift(br * wr - bi * wi, tw.frac, f.rounding),
           round_shift(br * wi + bi * wr, tw.frac, f.rounding)}
      end

    fin = fn v ->
      v = if halve?, do: round_shift(v, 1, f.rounding), else: v
      v |> max(-(1 <<< (f.bits - 1))) |> min((1 <<< (f.bits - 1)) - 1)
    end

    {{fin.(ar + tr), fin.(ai + ti)}, {fin.(ar - tr), fin.(ai - ti)}}
  end

  @doc false
  def round_shift(v, 0, _rounding), do: v
  def round_shift(v, k, :nearest), do: (v + (1 <<< (k - 1))) >>> k
  def round_shift(v, k, :truncate), do: v >>> k

  @doc "Bit reversal of `i` over `bits` bits."
  def bitrev(_i, 0), do: 0

  def bitrev(i, bits) do
    Enum.reduce(0..(bits - 1), 0, fn b, acc -> acc ||| (i >>> b &&& 1) <<< (bits - 1 - b) end)
  end

  defp bit_len(0), do: 0
  defp bit_len(v), do: 1 + bit_len(v >>> 1)
end
