defmodule ExHdl.Test.Mixer do
  @moduledoc false
  # A crosspoint mixer as one stream kernel: every beat is one row of `p`
  # crosspoints of an output (source channel and Q3.15 gain from two
  # memories), the `p` source samples are gathered from a frame memory,
  # multiplied and summed; the accumulator adds the rows of an output
  # (frame sideband: first and last row) and wraps at 48 bits, so its loop
  # is one adder. The output is rounded and saturated to 24 bits with a
  # clip flag, one per output (variable rate, `lanes: 1`).
  import Nx.Defn
  import Bitwise
  import NxFixed.Primitives, only: [shift_round: 2]

  @gain_min -(1 <<< 17)
  @gain_max (1 <<< 17) - 1
  @s_min -(1 <<< 23)
  @s_max (1 <<< 23) - 1

  defn xmix(sample, acc, src, gain, frame) do
    {row, {first, last}} = sample
    s = Nx.take(src, row)
    g = Nx.take(gain, row)
    x = Nx.take(frame, s)
    part = Nx.dot(Nx.as_type(x, :s64), Nx.as_type(g, :s64))
    base = Nx.select(first, Nx.tensor(0, type: :s64), acc)
    acc2 = ExHdl.DSP.wrap(base + part, 48)
    y = shift_round(acc2, 15)
    clip = Nx.logical_or(y > @s_max, y < @s_min)
    out = y |> Nx.clip(@s_min, @s_max) |> Nx.as_type(:s32)

    {{{Nx.reshape(out, {1}), Nx.reshape(Nx.as_type(clip, :s32), {1})}, Nx.as_type(last, :s32)},
     acc2}
  end

  @doc "Argument templates for `rows` rows of `p` crosspoints and `n_in` sources."
  def args(rows, p, n_in) do
    s32 = Nx.template({}, :s32)
    u8 = Nx.template({}, :u8)

    [
      {s32, {u8, u8}},
      Nx.template({}, :s64),
      Nx.template({rows, p}, :s32),
      Nx.template({rows, p}, :s32),
      Nx.template({n_in}, :s32)
    ]
  end

  def param_ranges(rows, n_in) do
    %{
      0 => 0..(rows - 1),
      1 => 0..1,
      2 => 0..1,
      3 => -(1 <<< 47)..((1 <<< 47) - 1),
      4 => 0..(n_in - 1),
      5 => @gain_min..@gain_max,
      6 => @s_min..@s_max
    }
  end

  def opts(rows, n_in, extra \\ []) do
    Keyword.merge(
      [
        state: 1,
        init: Nx.tensor(0, type: :s64),
        param_ranges: param_ranges(rows, n_in),
        param_names: ["src", "gain", "frame"],
        memories: ["src", "gain", "frame"],
        frame: true,
        lanes: 1
      ],
      extra
    )
  end
end

defmodule ExHdl.Test.Arith do
  @moduledoc false
  # Kernels for DSP splitting, DSP sharing and the priority encoder.
  import Nx.Defn

  deftransformp wide(x), do: Nx.as_type(x, :s64)

  # a 32 x 32 product and a dot of 32 x 24 bit products, no state
  defn wide_mul(sample, s) do
    {a, b, u, v} = sample
    {{wide(a) * wide(b), Nx.dot(wide(u), wide(v))}, s}
  end

  def wide_args do
    s32 = Nx.template({}, :s32)
    v = Nx.template({2}, :s32)
    [{s32, s32, v, v}, Nx.template({}, :u8)]
  end

  def wide_ranges, do: %{3 => -(2 ** 23)..(2 ** 23 - 1)}

  # four products with port coefficients over a delay line (not constant
  # taps, so no FIR chain)
  defn taps4(x, line, c) do
    {x1, x2, x3} = line
    {c0, c1, c2, c3} = c
    y = wide(x) * wide(c0) + wide(x1) * wide(c1) + wide(x2) * wide(c2) + wide(x3) * wide(c3)
    {y, {x, x1, x2}}
  end

  def taps4_args do
    s = Nx.template({}, :s16)
    [s, {s, s, s}, {s, s, s, s}]
  end

  # leading one and leading zeros of a 24-bit value, and the mantissa
  # normalised to 8 bits below the leading one
  defn levels(x, s) do
    m = ExHdl.DSP.msb(x, 24)
    z = ExHdl.DSP.count_leading_zeros(Nx.max(x, 0), 24)
    norm = Nx.right_shift(Nx.max(x, 1), Nx.max(m - 8, 0))
    {{m, z, norm}, s}
  end

  def levels_args, do: [Nx.template({}, :s32), Nx.template({}, :u8)]
  def levels_ranges, do: %{0 => -(2 ** 23)..(2 ** 24 - 1)}
end
