defmodule ExHdl.SIMD do
  @moduledoc """
  Hand-optimised SIMD implementations (Google Highway, c_src/simd) of
  `ExHdl.DSP.Blocks` for the Q15 format (`ExHdl.Num.q(16, 15, ...)`).

  They are bit-identical to the Nx reference of the same block and format;
  the test suite checks this for random inputs, parameters and lengths.
  Highway picks the best instruction set at runtime (`target/0`).

  The functions mirror the blocks but work on whole sample blocks: samples
  are `ExHdl.Num.Fixed` values whose tensors carry the sample index as first
  axis, as for `ExHdl.DSP.run_scan_stacked/5`. They return `:unsupported`
  when the format or parameters are outside what the kernels implement;
  `ExHdl.CPU.run_block/5` then falls back to the compiled Nx loop.
  """

  alias ExHdl.DSP.Primitives
  alias ExHdl.Num
  alias ExHdl.Num.{Fixed, Format}
  alias ExHdl.SIMD.NIF

  @doc "Whether the NIF is loaded."
  def available? do
    # Modules load lazily; the NIF's @on_load records the result.
    Code.ensure_loaded?(NIF) and :persistent_term.get({NIF, :loaded}, false) == true
  end

  @doc "SIMD target chosen at runtime, e.g. `\"NEON\"` or `\"AVX2\"`."
  def target, do: if(available?(), do: NIF.simd_target(), else: nil)

  @doc "NCO + mixer + gain, see `ExHdl.DSP.Blocks.ddc/5`."
  def ddc({%Fixed{} = i, %Fixed{} = q}, phase, phase_inc, %Fixed{} = gain, format) do
    with :ok <- q15?(format, [i, q, gain]),
         true <- format.lut_bits in 2..14 || :unsupported do
      {oi, oq, last} =
        NIF.ddc_q15(
          bin(i),
          bin(q),
          Nx.to_number(phase),
          Nx.to_number(phase_inc),
          Nx.to_number(gain.t),
          format.lut_bits,
          format.rounding == :nearest,
          table(format.lut_bits)
        )

      {{fixed(oi), fixed(oq)}, Nx.tensor(last, type: :u16)}
    end
  end

  @doc "Complex FIR with constant real taps, see `ExHdl.DSP.Blocks.fir_complex/3`."
  def fir_complex(
        {%Fixed{} = i, %Fixed{} = q},
        {%Fixed{} = line_i, %Fixed{} = line_q},
        taps,
        format
      ) do
    q_taps = format.kind == :fixed && Num.quantize_constants(taps, format)

    with :ok <- q15?(format, [i, q, line_i, line_q]),
         true <- Enum.all?(q_taps, &(&1 in -32767..32767)) || :unsupported,
         true <- 32768 * Enum.sum(Enum.map(q_taps, &abs/1)) < 2 ** 31 || :unsupported do
      taps_bin = for t <- q_taps, into: <<>>, do: <<t::signed-native-32>>
      {yi, next_i} = fir_one(i, line_i, taps_bin, format)
      {yq, next_q} = fir_one(q, line_q, taps_bin, format)
      {{yi, yq}, {next_i, next_q}}
    end
  end

  # The line is newest first; the kernel wants history oldest first + block.
  # The line is newest first; the kernel's history is oldest first.
  defp fir_one(x, line, taps_bin, format) do
    history = line.t |> Nx.reverse() |> Nx.to_binary()

    {y, new_history} =
      NIF.fir_q15(history, Nx.to_binary(x.t), taps_bin, format.rounding == :nearest)

    {fixed(y), %Fixed{t: new_history |> Nx.from_binary(:s16) |> Nx.reverse(), frac: 15}}
  end

  @doc "One-pole low-pass, see `ExHdl.DSP.Blocks.one_pole/4`."
  def one_pole(%Fixed{} = x, %Fixed{} = y, %Fixed{} = alpha, format) do
    with :ok <- q15?(format, [x, y, alpha]) do
      {out, last} =
        NIF.one_pole_q15(
          bin(x),
          Nx.to_number(y.t),
          Nx.to_number(alpha.t),
          format.rounding == :nearest
        )

      {fixed(out), %Fixed{t: Nx.tensor(last, type: :s16), frac: 15}}
    end
  end

  defp q15?(%Format{kind: :fixed, bits: 16, frac: 15}, values) do
    cond do
      not available?() -> :unsupported
      Enum.all?(values, &(&1.frac == 15 and Nx.type(&1.t) == {:s, 16})) -> :ok
      true -> :unsupported
    end
  end

  defp q15?(_format, _values), do: :unsupported

  defp bin(%Fixed{t: t}), do: Nx.to_binary(t)
  defp fixed(binary), do: %Fixed{t: Nx.from_binary(binary, :s16), frac: 15}

  # Sine table as native int32, the same values as the Nx reference.
  defp table(bits) do
    key = {__MODULE__, :table, bits}

    case :persistent_term.get(key, nil) do
      nil ->
        bin =
          for v <- Primitives.sine_values(2 ** bits, 32767),
              into: <<>>,
              do: <<v::signed-native-32>>

        :persistent_term.put(key, bin)
        bin

      bin ->
        bin
    end
  end
end

defmodule ExHdl.CPU do
  @moduledoc """
  Runs `ExHdl.DSP.Blocks` on the CPU with the fastest available
  implementation: the SIMD kernels (`ExHdl.SIMD`) where they cover the block
  and format, otherwise the compiled Nx loop (`ExHdl.DSP.run_scan_stacked/5`).
  Both are bit-identical for fixed-point formats.
  """
  alias ExHdl.DSP.Blocks

  @doc """
  `block` is a function of `ExHdl.DSP.Blocks`; `samples` are stacked as for
  `ExHdl.DSP.run_scan_stacked/5`. Returns `{outputs, final_state, implementation}`
  with `implementation` `:simd` or `:nx`.
  """
  def run_block(block, samples, state, params, kernel_opts) do
    format = Keyword.fetch!(kernel_opts, :format)

    info = Function.info(block)

    simd =
      case {info[:module], info[:name], params} do
        {Blocks, :ddc, [inc, gain]} ->
          ExHdl.SIMD.ddc(samples, state, inc, gain, format)

        {Blocks, :fir_complex, []} ->
          ExHdl.SIMD.fir_complex(samples, state, Keyword.fetch!(kernel_opts, :taps), format)

        {Blocks, :one_pole, [alpha]} ->
          ExHdl.SIMD.one_pole(samples, state, alpha, format)

        _ ->
          :unsupported
      end

    case simd do
      :unsupported ->
        {out, final} =
          ExHdl.DSP.run_scan_stacked(block, samples, state, params, kernel_opts: kernel_opts)

        {out, final, :nx}

      {out, final} ->
        {out, final, :simd}
    end
  end
end
