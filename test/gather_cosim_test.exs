defmodule ExHdl.GatherCosimTest do
  @moduledoc """
  Memories read at computed addresses (gathers), the frame sideband and an
  accumulator without a clamp, on a crosspoint mixer (`ExHdl.Test.Mixer`):
  every output sums a runtime number of rows of crosspoints, each row
  gathers its source samples from a double-buffered frame memory. Compared
  bit for bit with the Nx reference and with an integer model of the mix.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias ExHdl.Sim.Verilator
  alias ExHdl.Test.Mixer, as: M

  @moduletag :verilator
  @moduletag timeout: 600_000

  @traffic [{100, 100, 1}, {70, 50, 2}, {30, 95, 3}, {95, 20, 4}]

  # n_in sources, n_out outputs of up to parts rows of p crosspoints
  @n_in 16
  @n_out 6
  @p 4
  @parts 3
  @rows @n_out * @parts

  # {src, gain} tables ({rows, p} each) and the number of rows per output
  defp matrix(seed) do
    :rand.seed(:exsss, seed)

    per_out =
      for o <- 0..(@n_out - 1) do
        n = if o == 0, do: @p * @parts, else: :rand.uniform(@p * @parts)
        srcs = Enum.take(Enum.shuffle(0..(@n_in - 1)), n)
        # output 0 is loud enough to saturate
        gains =
          for _ <- srcs,
              do: if(o == 0, do: 120_000, else: :rand.uniform(1 <<< 17) - (1 <<< 16))

        parts = div(n + @p - 1, @p)
        pad = parts * @p - n
        {Enum.zip(srcs, gains) ++ List.duplicate({0, 0}, pad), parts}
      end

    rows =
      Enum.flat_map(per_out, fn {xp, parts} ->
        xp
        |> Enum.chunk_every(@p)
        |> Kernel.++(List.duplicate(List.duplicate({0, 0}, @p), @parts - parts))
      end)

    src = for row <- rows, do: Enum.map(row, &elem(&1, 0))
    gain = for row <- rows, do: Enum.map(row, &elem(&1, 1))
    {src, gain, Enum.map(per_out, &elem(&1, 1))}
  end

  defp frame_data(seed) do
    :rand.seed(:exsss, seed)
    for _ <- 1..@n_in, do: :rand.uniform(1 <<< 24) - (1 <<< 23)
  end

  # the beats of one audio frame: {row, first, last} per row of each output
  defp beats(parts) do
    for {n, o} <- Enum.with_index(parts),
        k <- 0..(n - 1),
        do: {o * @parts + k, k == 0, k == n - 1}
  end

  defp reference({src, gain, _}, frame, beats) do
    rows = Enum.map(beats, &elem(&1, 0))
    {firsts, lasts} = {Enum.map(beats, &b(elem(&1, 1))), Enum.map(beats, &b(elem(&1, 2)))}

    {{{y, clip}, count}, _} =
      NxFixed.run_scan_stacked(
        &M.xmix/5,
        {Nx.tensor(rows, type: :s32),
         {Nx.tensor(firsts, type: :u8), Nx.tensor(lasts, type: :u8)}},
        Nx.tensor(0, type: :s64),
        [Nx.tensor(src, type: :s32), Nx.tensor(gain, type: :s32), Nx.tensor(frame, type: :s32)],
        param_ranges: M.param_ranges(@rows, @n_in)
      )

    keep = Nx.to_flat_list(count)

    pick = fn t ->
      t
      |> Nx.to_flat_list()
      |> Enum.zip(keep)
      |> Enum.filter(&(elem(&1, 1) == 1))
      |> Enum.map(&elem(&1, 0))
    end

    {pick.(y), pick.(clip)}
  end

  # the mix as integers: round half up, saturate to 24 bits
  defp model({src, gain, parts}, frame) do
    for {n, o} <- Enum.with_index(parts) do
      acc =
        for k <- 0..(n - 1), j <- 0..(@p - 1), reduce: 0 do
          acc ->
            row = o * @parts + k
            acc + Enum.at(Enum.at(gain, row), j) * Enum.at(frame, Enum.at(Enum.at(src, row), j))
        end

      y = (acc + (1 <<< 14)) >>> 15
      {y |> max(-(1 <<< 23)) |> min((1 <<< 23) - 1), b(y > (1 <<< 23) - 1 or y < -(1 <<< 23))}
    end
    |> Enum.unzip()
  end

  defp b(true), do: 1
  defp b(false), do: 0

  defp writes(op, {src, gain, _}, frame) do
    Enum.flat_map(Enum.with_index(src), fn {row, r} -> [{op, "src", r, row}] end) ++
      Enum.flat_map(Enum.with_index(gain), fn {row, r} -> [{op, "gain", r, row}] end) ++
      Enum.map(Enum.with_index(frame), fn {x, i} -> {op, "frame", i, [x]} end)
  end

  test "the accumulator wraps instead of clamping: one sample per cycle" do
    {:ok, scan} =
      ExHdl.DSP.analyze_scan(&M.xmix/5, M.args(@rows, @p, @n_in), M.opts(@rows, @n_in))

    assert scan.loop_latency == 1 and scan.ii == 1

    assert Enum.map(scan.memories, &{&1.name, &1.row}) == [
             {"src", @p},
             {"gain", @p},
             {"frame", 1}
           ]
  end

  test "crosspoint mixer: gathers from a frame memory, runtime rows per output, bank swaps" do
    {:ok, d} =
      ExHdl.DSP.scan_to_sv(
        &M.xmix/5,
        M.args(@rows, @p, @n_in),
        M.opts(@rows, @n_in, name: "xmix")
      )

    assert d.frame and d.dsp == @p

    assert Enum.map(d.memories, &{&1.name, &1.read_ports}) == [
             {"src", 1},
             {"gain", 1},
             {"frame", @p}
           ]

    {:ok, sim} = Verilator.build_stream(d)

    m1 = matrix(1)
    m2 = matrix(2)
    {fa, fb} = {frame_data(3), frame_data(4)}
    frames = 5
    swap_frame = 3

    b1 = beats(elem(m1, 2))
    b2 = beats(elem(m2, 2))
    stream = List.duplicate(b1, swap_frame) ++ List.duplicate(b2, frames - swap_frame)
    flat = List.flatten(stream)

    {y1, c1} = reference(m1, fa, List.flatten(List.duplicate(b1, swap_frame)))
    {y2, c2} = reference(m2, fb, List.flatten(List.duplicate(b2, frames - swap_frame)))

    # the reference agrees with the integer model of the mix
    {my1, mc1} = model(m1, fa)
    assert y1 == List.flatten(List.duplicate(my1, swap_frame))
    assert c1 == List.flatten(List.duplicate(mc1, swap_frame))
    assert Enum.any?(c1, &(&1 == 1))

    k = swap_frame * length(b1)

    pc =
      writes(:mem, m1, fa) ++
        [:swap] ++
        writes(:mem, m2, fb) ++
        [{:swap_at, k}] ++
        writes(:mem_after_swap, {elem(m1, 1), elem(m1, 0), nil}, Enum.map(fa, &(-&1)))

    for {vp, rp, seed} <- @traffic do
      assert {:ok, res} =
               Verilator.run_stream(
                 sim,
                 [Enum.map(flat, &elem(&1, 0))],
                 [],
                 valid_pct: vp,
                 ready_pct: rp,
                 seed: seed,
                 tlast: Enum.map(flat, &b(elem(&1, 2))),
                 pc: pc
               )

      assert res.outputs == [y1 ++ y2, c1 ++ c2], "traffic #{inspect({vp, rp, seed})}"
      assert Enum.all?(res.tlast, &(&1 == 1))
    end
  end
end
