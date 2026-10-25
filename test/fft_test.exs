defmodule ExHdl.FFTTest do
  @moduledoc """
  `ExHdl.FFT`: the integer model and the generated pipeline against
  `ExSdr.DSP.FFT.fft/2`, bit for bit (inverse: the same on swapped re/im),
  with random backpressure.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias ExHdl.FFT
  alias ExHdl.Sim.Verilator
  alias NxFixed.Num

  @q15 Num.q(16, 15)
  @traffic [{100, 100, 1}, {70, 50, 2}, {30, 95, 3}, {95, 20, 4}]

  # random full-range symbols: [{re, im}] of n integers each
  defp symbols(n, count, f, seed) do
    :rand.seed(:exsss, seed)
    half = 1 <<< (f.bits - 1)
    rnd = fn -> for _ <- 1..n, do: :rand.uniform(2 * half) - 1 - half end
    for _ <- 1..count, do: {rnd.(), rnd.()}
  end

  # ExSdr.DSP.FFT on one symbol; inverse by swapping re and im
  defp reference({re, im}, opts) do
    f = opts[:format]
    inverse = Keyword.get(opts, :inverse, false)
    {re, im} = if inverse, do: {im, re}, else: {re, im}
    type = if f.bits <= 16, do: :s16, else: :s32
    t = &%NxFixed.Fixed{t: Nx.tensor(&1, type: type), frac: f.frac}
    fft_opts = Keyword.take(opts, [:format, :twiddle, :shifts])
    {r, i} = ExSdr.DSP.FFT.fft({t.(re), t.(im)}, fft_opts)
    {r, i} = {Nx.to_flat_list(r.t), Nx.to_flat_list(i.t)}
    if inverse, do: {i, r}, else: {r, i}
  end

  defp bit_reverse({re, im}, n) do
    bits = round(:math.log2(n))
    {rt, it} = {List.to_tuple(re), List.to_tuple(im)}
    order = for p <- 0..(n - 1), do: FFT.bitrev(p, bits)
    {Enum.map(order, &elem(rt, &1)), Enum.map(order, &elem(it, &1))}
  end

  describe "model" do
    test "matches ExSdr.DSP.FFT for every size, shifts, formats and rounding" do
      configs =
        for n <- [2, 4, 8, 16, 32, 64, 128, 256, 512, 1024],
            stages = round(:math.log2(n)),
            shifts <- Enum.uniq([0, div(stages, 2), stages]),
            {f, tw} <- [
              {@q15, @q15},
              {@q15, Num.q(18, 17)},
              {Num.q(12, 11, rounding: :truncate), Num.q(12, 11, rounding: :truncate)},
              {Num.q(20, 15), Num.q(16, 14)}
            ],
            do: {n, [format: f, twiddle: tw, shifts: shifts]}

      for {{n, opts}, k} <- Enum.with_index(configs) do
        {:ok, spec} = FFT.spec(n, opts)

        for x <- symbols(n, 2, opts[:format], k) do
          assert FFT.model(spec, x) == reference(x, opts), "#{n} #{inspect(opts)}"
        end
      end
    end

    test "inverse and the large sizes" do
      for {n, opts} <- [
            {64, [format: @q15, shifts: 3, inverse: true]},
            {2048, [format: @q15, shifts: 11]},
            {8192, [format: @q15, twiddle: Num.q(18, 17), shifts: 13]},
            {8192, [format: @q15, shifts: 0]}
          ] do
        {:ok, spec} = FFT.spec(n, opts)
        [x] = symbols(n, 1, @q15, n)
        assert FFT.model(spec, x) == reference(x, opts)
      end
    end

    test "invalid parameters" do
      assert {:error, msg} = FFT.spec(100, format: @q15)
      assert msg =~ "power of two"
      assert {:error, _} = FFT.spec(64, format: Num.float())
      assert {:error, msg} = FFT.spec(64, format: @q15, shifts: 7)
      assert msg =~ "shifts"
      assert {:error, _} = FFT.generate(64, format: @q15, order: :random)
    end

    test "twiddles are the reference's quantized values" do
      {:ok, spec} = FFT.spec(8, format: @q15)
      assert FFT.twiddles(spec, 1) == [{32_767, 0}, {0, -32_768}]
      assert length(FFT.twiddles(spec, 2)) == 4
    end
  end

  describe "co-simulation" do
    @describetag :verilator
    @describetag timeout: 900_000

    for {label, n, count, opts} <- [
          {"64", 64, 4, [format: @q15, shifts: 3]},
          {"64_full_scale", 64, 3, [format: @q15, shifts: 6]},
          {"64_inverse", 64, 3, [format: @q15, shifts: 2, inverse: true]},
          {"64_bit_reversed", 64, 3, [format: @q15, shifts: 3, order: :bit_reversed]},
          {"64_q12_truncate", 64, 3,
           [format: Num.q(12, 11, rounding: :truncate), twiddle: Num.q(18, 17), shifts: 1]},
          {"8", 8, 6, [format: @q15]},
          {"2048", 2048, 3, [format: @q15, shifts: 5]},
          {"8192", 8192, 2, [format: @q15, shifts: 7]}
        ] do
      @n n
      @count count
      @opts opts
      test "#{label}: RTL is bit-identical to ExSdr.DSP.FFT" do
        n = @n
        opts = @opts

        {:ok, design} =
          FFT.generate(n, opts ++ [name: "fft_" <> String.replace(unquote(label), ".", "_")])

        assert design.frame
        {:ok, sim} = Verilator.build_stream(design)

        xs = symbols(n, @count, opts[:format], n)

        want =
          Enum.map(xs, fn x ->
            y = reference(x, opts)
            if opts[:order] == :bit_reversed, do: bit_reverse(y, n), else: y
          end)

        input = [Enum.flat_map(xs, &elem(&1, 0)), Enum.flat_map(xs, &elem(&1, 1))]
        expected = [Enum.flat_map(want, &elem(&1, 0)), Enum.flat_map(want, &elem(&1, 1))]
        lasts = for k <- 1..(n * @count), do: if(rem(k, n) == 0, do: 1, else: 0)

        for {vp, rp, seed} = traffic <- @traffic do
          assert {:ok, res} =
                   Verilator.run_stream(sim, input, [],
                     valid_pct: vp,
                     ready_pct: rp,
                     seed: seed,
                     tlast: lasts
                   )

          assert res.outputs == expected, "#{n}, traffic #{inspect(traffic)}"
          assert res.tlast == lasts

          if {vp, rp} == {100, 100} do
            # one sample per cycle in, one per cycle out, a symbol leaves
            # without waiting for the next: the run takes the samples, one
            # symbol latency and the harness's drain of 64 + latency cycles
            assert res.cycles <= n * @count + 2 * design.latency + 64 + 32
          end
        end
      end
    end
  end

  describe "resources (Yosys synth_xilinx)" do
    @describetag :yosys
    @describetag timeout: 900_000

    test "2048 points: radix-2 SDF in block RAM, four DSP per stage after the first" do
      {:ok, d} = FFT.generate(2048, format: @q15, name: "fft2048_res")
      {:ok, u} = ExHdl.Synth.Yosys.utilization(%{"fft.sv" => d.source}, d.name)
      assert u.dsp == d.dsp and d.dsp == 40
      assert u.bram36 <= 8
      assert u.lut < 4000
    end
  end
end
