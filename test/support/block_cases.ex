defmodule ExHdl.Test.BlockCases do
  @moduledoc false
  # ex_sdr's :stream blocks co-simulated from their %NxFixed.Block{}
  # descriptions (test/block_cosim_test.exs). One line per block:
  #
  #   {module, name, block_opts}                    generated and compared bit for bit
  #   {module, name, block_opts, case_opts}
  #
  # case_opts: :label (test and module name, default the block name),
  # :gen (options for ExHdl.Block.scan_to_sv/2, default ii: :auto),
  # :symbols (input range of :symbol items), :samples, and
  # :expect {:error, ~r/reason/} for blocks that do not generate (yet).
  # Every block gets format: q15/0 unless block_opts has one.

  alias NxFixed.Num

  def q15, do: Num.q(16, 15, rounding: :nearest, lut_bits: 10)

  def cases do
    [
      # filters
      {ExSdr.Filters, :fir_filter_fff, [taps: lowpass(63)], label: "fir_filter_fff_63"},
      {ExSdr.Filters, :fir_filter_ccf, [taps: lowpass(63)], label: "fir_filter_ccf_63"},
      {ExSdr.Filters, :fir_filter_ccc, [taps: Enum.map(lowpass(15), &{&1, &1 / 2})]},
      {ExSdr.Filters, :fir_filter_ccf, [taps: lowpass(63), decimation: 4],
       label: "fir_filter_ccf_decim4", expect: {:error, ~r/only :stream blocks/}},
      {ExSdr.Filters, :hilbert_fc, [ntaps: 31]},
      {ExSdr.Filters, :dc_blocker_ff, [length: 8]},
      {ExSdr.Filters, :dc_blocker_cc, [length: 8, long_form: false]},
      {ExSdr.Filters, :single_pole_iir_filter_ff, [alpha: 0.1]},
      {ExSdr.Filters, :single_pole_iir_filter_cc, [alpha: 0.1]},
      {ExSdr.Filters, :iir_filter_ffd, [fftaps: [0.2, 0.3], fbtaps: [1.0, 0.4]]},
      # analog
      {ExSdr.Analog, :frequency_modulator_fc, [sensitivity: 0.3]},
      {ExSdr.Analog, :phase_modulator_fc, [sensitivity: 0.3]},
      {ExSdr.Analog, :quadrature_demod_cf, [gain: 1.0]},
      {ExSdr.Analog, :am_demod, []},
      {ExSdr.Analog, :agc_cc, [rate: 1.0e-3, reference: 0.5]},
      {ExSdr.Analog, :agc_ff, [rate: 1.0e-3, reference: 0.5]},
      {ExSdr.Analog, :agc2_cc, []},
      {ExSdr.Analog, :pll_carriertracking_cc, [loop_bw: 0.05]},
      {ExSdr.Analog, :pll_freqdet_cf, [loop_bw: 0.05]},
      {ExSdr.Analog, :pll_refout_cc, [loop_bw: 0.05]},
      {ExSdr.Analog, :rail_ff, [lo: -0.5, hi: 0.5]},
      # sources
      {ExSdr.Sources, :nco, [frequency: 1000.0, sample_rate: 48_000.0]},
      {ExSdr.Sources, :sig_source_c, [frequency: 1000.0, sample_rate: 48_000.0]},
      {ExSdr.Sources, :rotator_cc, [frequency: 1000.0, sample_rate: 48_000.0]},
      {ExSdr.Sources, :vco_c, [sensitivity: 1000.0, sample_rate: 48_000.0]},
      # math
      {ExSdr.Math, :multiply_const_ff, [k: 0.7]},
      {ExSdr.Math, :multiply_const_cc, [k: 0.7]},
      {ExSdr.Math, :add_const_ff, [c: 0.25]},
      {ExSdr.Math, :moving_average_ff, [length: 16, scale: 1 / 16]},
      {ExSdr.Math, :moving_average_cc, [length: 16, scale: 1 / 16]},
      {ExSdr.Math, :add_ff, []},
      {ExSdr.Math, :complex_to_mag_squared, []},
      {ExSdr.Math, :delay, [delay: 5]},
      # digital
      {ExSdr.Digital, :chunks_to_symbols_bf, [table: [-1.0, -0.33, 0.33, 1.0]], symbols: 4},
      {ExSdr.Digital, :chunks_to_symbols_bc,
       [table: [{0.7, 0.7}, {-0.7, 0.7}, {-0.7, -0.7}, {0.7, -0.7}]], symbols: 4},
      {ExSdr.Digital, :diff_encoder_bb, [modulus: 4], symbols: 4},
      {ExSdr.Digital, :diff_decoder_bb, [modulus: 4], symbols: 4},
      {ExSdr.Digital, :binary_slicer_fb, []},
      {ExSdr.Digital, :constellation_decoder_cb, [constellation: :qpsk]}
    ]
    |> Enum.map(&normalize/1)
  end

  defp normalize({mod, name, opts}), do: normalize({mod, name, opts, []})

  defp normalize({mod, name, opts, case_opts}) do
    %{
      module: mod,
      name: name,
      opts: Keyword.put_new(opts, :format, q15()),
      label: Keyword.get(case_opts, :label, Atom.to_string(name)),
      gen: Keyword.get(case_opts, :gen, ii: :auto),
      symbols: Keyword.get(case_opts, :symbols, 256),
      samples: Keyword.get(case_opts, :samples, 300),
      expect: Keyword.get(case_opts, :expect, :ok)
    }
  end

  def block(c), do: c.module.block(c.name, c.opts)

  @doc "Windowed-sinc low-pass (Hamming), cutoff a quarter of the sample rate."
  def lowpass(n) do
    mid = (n - 1) / 2

    for i <- 0..(n - 1) do
      x = i - mid
      sinc = if x == 0, do: 0.25, else: :math.sin(:math.pi() * 0.25 * x) / (:math.pi() * x)
      sinc * (0.54 - 0.46 * :math.cos(2 * :math.pi() * i / (n - 1)))
    end
  end

  @doc """
  `n` random input items for a block, stacked (item index first), full
  range of the item type: format range for real items, 0/1 bits, bytes,
  symbols below `symbols`.
  """
  def stimulus(block, n, symbols, seed) do
    :rand.seed(:exsss, seed)
    {item, _} = block.item
    format = block.opts[:format]

    real = fn ->
      %NxFixed.Fixed{t: t, frac: frac} = Num.zeros({}, format)
      half = Bitwise.bsl(1, format.bits - 1)
      ints = for _ <- 1..n, do: :rand.uniform(2 * half) - 1 - half
      %NxFixed.Fixed{t: Nx.tensor(ints, type: t.type), frac: frac}
    end

    ints = fn hi -> Nx.tensor(for(_ <- 1..n, do: :rand.uniform(hi + 1) - 1), type: :u8) end

    case item do
      :real -> real.()
      :complex -> {real.(), real.()}
      :real_pair -> {real.(), real.()}
      :bit -> ints.(1)
      :byte -> ints.(255)
      :symbol -> ints.(symbols - 1)
      :none -> ints.(0)
    end
  end

  @doc "Flat integer lists, one per tensor leaf of a container."
  def leaf_ints(container),
    do: [container] |> Nx.Defn.Composite.flatten_list() |> Enum.map(&Nx.to_flat_list/1)
end
