defmodule ExHdl.Test.Audio do
  @moduledoc false
  # ex_audio's direct form I biquad (ExAudio.Biquad.step/3) with its
  # helpers, copied so the tests do not depend on ex_audio: 24-bit samples in
  # s32, Q5.27 numerator and Q2.30 denominator coefficients, 8 guard bits
  # and first-order error feedback.
  import Nx.Defn
  import Bitwise
  import NxFixed.Primitives, only: [shift_round: 2]

  @b_frac 27
  @a_frac 30
  @guard 8
  @y_max (1 <<< 31) - 1
  @y_min -(1 <<< 31)
  @res_shift 19
  @res_bits 18
  @res_half 1 <<< 18
  @res_mask (1 <<< 19) - 1
  @s_max (1 <<< 23) - 1
  @s_min -(1 <<< 23)

  deftransformp wide(x), do: Nx.as_type(x, :s64)

  deftransformp clamp(x, lo, hi) do
    type = Nx.type(x)
    Nx.clip(x, Nx.tensor(lo, type: type), Nx.tensor(hi, type: type))
  end

  deftransformp sat24(x), do: x |> Nx.clip(@s_min, @s_max) |> Nx.as_type(:s32)

  defn biquad(x, state, coef) do
    {x1, x2, y1, y2, res} = state
    {b0, b1, b2, a1, a2} = coef

    feedforward = wide(b0) * wide(x) + wide(b1) * wide(x1) + wide(b2) * wide(x2)
    feedback = wide(a1) * wide(y1) + wide(a2) * wide(y2)

    acc =
      feedforward - Nx.right_shift(feedback, @a_frac + 23 + @guard - (@b_frac + 23)) + wide(res)

    y_ext = acc |> shift_round(@res_shift) |> clamp(@y_min, @y_max)
    half = Nx.tensor(@res_half, type: :s64)
    res2 = acc |> Nx.add(half) |> Nx.bitwise_and(@res_mask) |> Nx.subtract(half)
    y = y_ext |> shift_round(@guard) |> sat24()
    {y, {x, x1, Nx.as_type(y_ext, :s32), y1, Nx.as_type(res2, :s32)}}
  end

  @doc "Argument templates of `biquad/3`."
  def args do
    s = Nx.template({}, :s32)
    [s, {s, s, s, s, s}, {s, s, s, s, s}]
  end

  @doc "Ranges of sample, state and coefficient leaves (flat index map)."
  def param_ranges do
    s = @s_min..@s_max
    y = @y_min..@y_max
    a2 = -(1 <<< 30)..((1 <<< 30) - 1)
    res = -(1 <<< @res_bits)..((1 <<< @res_bits) - 1)

    [s, s, s, y, y, res, y, y, y, y, a2]
    |> Enum.with_index()
    |> Map.new(fn {r, i} -> {i, r} end)
  end

  @doc "Kernel description for `ExHdl.DSP.cascade/1`."
  def stage(name),
    do: [
      fun: &biquad/3,
      args: args(),
      state: 1,
      init: zero_state(),
      param_ranges: param_ranges(),
      param_names: ["coef"],
      name: name
    ]

  def zero_state, do: List.to_tuple(for _ <- 1..5, do: Nx.tensor(0, type: :s32))

  @doc "Audio EQ Cookbook design, quantised to `{b0, b1, b2, a1, a2}` integers."
  def design(kind, f0, opts \\ []) do
    fs = 48_000
    q = Keyword.get(opts, :q, 0.707)
    gain_db = Keyword.get(opts, :gain_db, 0)
    w0 = 2 * :math.pi() * f0 / fs
    {sn, cs} = {:math.sin(w0), :math.cos(w0)}
    alpha = sn / (2 * q)
    a = :math.pow(10, gain_db / 40)

    {b0, b1, b2, a0, a1, a2} =
      case kind do
        :lowpass -> {(1 - cs) / 2, 1 - cs, (1 - cs) / 2, 1 + alpha, -2 * cs, 1 - alpha}
        :highpass -> {(1 + cs) / 2, -(1 + cs), (1 + cs) / 2, 1 + alpha, -2 * cs, 1 - alpha}
        :peaking -> {1 + alpha * a, -2 * cs, 1 - alpha * a, 1 + alpha / a, -2 * cs, 1 - alpha / a}
      end

    lim = (1 <<< 30) - 1

    {scale(b0 / a0, @b_frac), scale(b1 / a0, @b_frac), scale(b2 / a0, @b_frac),
     scale(a1 / a0, @a_frac), scale(a2 / a0, @a_frac) |> max(-lim) |> min(lim)}
  end

  defp scale(v, frac), do: round(v * (1 <<< frac))

  @doc "Coefficient tuple as `s32` tensors."
  def coef_tensors(coef),
    do: coef |> Tuple.to_list() |> Enum.map(&Nx.tensor(&1, type: :s32)) |> List.to_tuple()

  @doc "Deterministic 24-bit test signal: two tones and noise, per channel."
  def signal(n, channel) do
    :rand.seed(:exsss, 1000 + channel)

    for i <- 0..(n - 1) do
      t = i / 48_000

      v =
        0.4 * :math.sin(2 * :math.pi() * (200 + 150 * channel) * t) +
          0.3 * :math.sin(2 * :math.pi() * 7000 * t)

      v = v + 0.2 * (:rand.uniform() - 0.5)
      round(v * @s_max) |> max(@s_min) |> min(@s_max)
    end
  end

  @doc "A full-scale square wave burst (drives the saturation paths)."
  def loud(n), do: for(i <- 0..(n - 1), do: if(rem(div(i, 7), 2) == 0, do: @s_max, else: @s_min))
end
