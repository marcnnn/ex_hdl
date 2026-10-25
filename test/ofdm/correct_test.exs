defmodule ExHdl.OFDM.CorrectTest do
  @moduledoc """
  Frequency correction (`ExHdl.OFDM.Correct`) in Verilator against the NCO
  rotation of `FixedFrontEnd` (`ExHdl.Test.OFDMRef.correct/4`) on the DVB-T
  test signal, bit for bit, with random backpressure, a chunk that starts
  inside the stream (`phase0`) and a parameter change in mid-stream.
  """
  use ExUnit.Case, async: true

  alias ExHdl.OFDM.Correct
  alias ExHdl.Sim.Verilator
  alias ExHdl.Test.OFDMRef, as: R
  alias ExSdr.Comm.OFDM.FixedFrontEnd, as: F

  @moduletag :verilator
  @moduletag timeout: 600_000

  @traffic [{100, 100, 1}, {70, 50, 2}, {30, 95, 3}, {95, 20, 4}]

  setup_all do
    {:ok, d} = Correct.scan_to_sv()
    {:ok, sim} = Verilator.build_stream(d)
    {sc16, cfo} = R.signal(:qpsk, 8)
    %{design: d, sim: sim, sc16: sc16, cfo: cfo}
  end

  defp leaves({re, im}), do: [Nx.to_flat_list(re.t), Nx.to_flat_list(im.t)]

  defp columns(sc16) do
    pairs = Nx.reshape(sc16, {:auto, 2})
    for c <- 0..1, do: pairs[[.., c]] |> Nx.to_flat_list()
  end

  test "the kernel is a single-cycle loop with four DSP slices", %{design: d} do
    assert d.ii == 1
    assert d.dsp == 4
  end

  test "whole signal from phase 0, four traffic patterns", %{sim: sim, sc16: sc16, cfo: cfo} do
    inc = F.phase_increment(cfo, 2048)
    expected = leaves(R.correct(sc16, inc, 0))
    refute expected |> List.flatten() |> Enum.uniq() |> length() < 100

    for {vp, rp, seed} = traffic <- @traffic do
      assert {:ok, res} =
               Verilator.run_stream(sim, columns(sc16), [inc, 0],
                 valid_pct: vp,
                 ready_pct: rp,
                 seed: seed
               )

      assert res.outputs == expected, "traffic #{inspect(traffic)}"
    end
  end

  test "a chunk that starts 3333 samples in joins the phase of the stream", %{
    sim: sim,
    sc16: sc16,
    cfo: cfo
  } do
    inc = F.phase_increment(cfo, 2048)
    start = 3333
    whole = leaves(R.correct(sc16, inc, 0))
    chunk = Nx.slice(sc16, [2 * start], [Nx.size(sc16) - 2 * start])

    assert {:ok, res} =
             Verilator.run_stream(sim, columns(chunk), [inc, Correct.phase0(inc, start)],
               valid_pct: 80,
               ready_pct: 70,
               seed: 5
             )

    assert res.outputs == Enum.map(whole, &Enum.drop(&1, start))
  end

  test "a new increment applies from the sample it is loaded with", %{sim: sim, sc16: sc16} do
    {inc1, inc2} = {F.phase_increment(0.37, 2048), F.phase_increment(-1.2, 2048)}
    k = 5000
    n = div(Nx.size(sc16), 2)

    assert {:ok, res} =
             Verilator.run_stream(sim, columns(sc16), [inc1, 0],
               valid_pct: 90,
               ready_pct: 90,
               seed: 6,
               switch: {k, [inc2, 0]}
             )

    # the accumulator keeps its phase and continues with the new step
    first = leaves(R.correct(Nx.slice(sc16, [0], [2 * k]), inc1, 0))
    phase_k = Correct.phase0(inc1, k)
    rest = Nx.slice(sc16, [2 * k], [2 * (n - k)])
    second = leaves(R.correct(rest, inc2, phase_k))
    assert res.outputs == Enum.zip_with(first, second, &(&1 ++ &2))
  end
end
