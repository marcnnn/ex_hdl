defmodule ExHdl.OFDM.FrontEndTest do
  @moduledoc """
  Everything but the FFT, as one stream in Verilator
  (`ExHdl.OFDM.FrontEnd`): sc16 samples in, code bits out, the FFT done by
  the software FFT of `FixedFrontEnd` between the design's `fft_in` and
  `fft_out` ports. The bits are those of `FixedFrontEnd.run/4`, bit for bit.
  """
  use ExUnit.Case, async: true

  alias ExHdl.OFDM.{Correct, FrontEnd}
  alias ExHdl.RTL.{Bench, Cosim}
  alias ExHdl.Test.{AxisSink, AxisSource, Pulse, SoftFFT}
  alias ExHdl.Test.OFDMRef, as: R
  alias ExSdr.Comm.OFDM.FixedFrontEnd, as: F

  @moduletag :verilator
  @moduletag timeout: 1_800_000

  @symbols 8

  defp samples(sc16) do
    sc16
    |> Nx.reshape({:auto, 2})
    |> Nx.to_list()
    |> Enum.map(fn [re, im] ->
      {Bitwise.bor(Bitwise.bsl(Bitwise.band(im, 0xFFFF), 16), Bitwise.band(re, 0xFFFF)), 0}
    end)
  end

  for {c, v, snr} <-
        [qpsk: 2, qam16: 4, qam64: 6]
        |> Enum.map(fn {c, v} -> {c, v, if(c == :qpsk, do: 12.0, else: 28.0)} end) do
    @c c
    @v v
    @snr snr
    test "#{c}: bits equal FixedFrontEnd.run/4 on the test signal, random traffic" do
      spec = ExSdr.DVBT.Receiver.front_end_spec(@c)
      {sc16, cfo} = R.signal(@c, @symbols, snr: @snr)
      fe = F.prepare(spec, @symbols, compiler: Nx.Defn.Evaluator)
      expected = F.run(fe, sc16, cfo, 0) |> :binary.bin_to_list()
      assert length(expected) == @symbols * 1512 * @v

      {:ok, d} = FrontEnd.build(spec, name: "fe_#{@c}")
      inc = F.phase_increment(cfo, 2048)
      :rand.seed(:exsss, {1, 2, 3})
      {:ok, s} = Cosim.open(d.module)

      bench =
        Bench.new(
          s,
          [
            src: AxisSource.new(samples(sc16), p: 0.9),
            sink: AxisSink.new(p: 0.8),
            fft: SoftFFT.new(p: 0.7, q: 0.8),
            load: %Pulse{port: :load, at: 3}
          ],
          idle: %{inc: inc, phase0: Correct.phase0(inc, 0)}
        )
        |> Bench.run_until(
          &(AxisSink.count(Bench.agent(&1, :sink)) == length(expected)),
          3_000_000
        )

      Cosim.close(s)
      out = AxisSink.items(Bench.agent(bench, :sink))
      assert Enum.map(out, &elem(&1, 0)) == expected
      block = 126 * @v

      assert Enum.map(out, &elem(&1, 1)) ==
               for(i <- 1..length(expected), do: if(rem(i, block) == 0, do: 1, else: 0))

      assert Bench.agent(bench, :fft).symbols == @symbols
    end
  end
end
