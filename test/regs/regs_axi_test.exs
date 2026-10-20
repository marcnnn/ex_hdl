defmodule ExHdl.RegsAxiTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  use ExHdl.Regs

  alias ExHdl.Regs.SimDriver
  alias ExHdl.RTL.{Cosim, Sim}
  alias ExHdl.Test.MixerRegs, as: R
  alias ExHdl.Test.RegsTB

  defp driver(opts \\ []) do
    tb = RegsTB.bench(R.regmap(), Keyword.take(opts, [:unmapped]))
    {tb, SimDriver.new(Sim.new(tb), opts)}
  end

  # Per-event outputs of a recorded driver run, replayed from the start.
  defp replay(tb, d) do
    {_, out} = tb |> Sim.new() |> Sim.run(SimDriver.stimulus(d))
    out
  end

  test "reads constants, inputs and reset values" do
    {_, d} = driver()
    d = SimDriver.poke(d, %{id_channels: 64})
    {id, :okay, d} = SimDriver.read(d, R.offset(:id))
    assert R.decode(:id, id) == %{version: 0x0102, channels: 64}
    {ctrl, :okay, d} = SimDriver.read(d, R.offset(:ctrl))
    assert ctrl == R.reset_value(:ctrl)
    {lvl, :okay, _} = SimDriver.read(d, R.offset(:level, 2))
    assert lvl == 0x10
  end

  test "writes drive field outputs; byte strobes keep other lanes; wo reads 0" do
    {_, d} = driver(delays: 0..2, seed: 5)
    {:okay, d} = SimDriver.write(d, R.offset(:ctrl), R.encode(:ctrl, mode: :mono, gain: 0xABCD))
    assert SimDriver.peek(d, :ctrl_gain) == 0xABCD
    assert SimDriver.peek(d, :ctrl_mode) == 1
    # lane 1 only: gain bits 4..7 keep, bits 8..15 of the word = gain bits 4..11
    {:okay, d} = SimDriver.write(d, R.offset(:ctrl), 0xFFFF_FFFF, 0b0010)
    assert SimDriver.peek(d, :ctrl_gain) == 0xAFFD
    assert SimDriver.peek(d, :ctrl_mode) == 1

    {:okay, d} =
      SimDriver.write(d, R.offset(:ctrl), R.encode(:ctrl, start: 1, gain: 0xAFFD, mode: :mono))

    assert SimDriver.peek(d, :ctrl_start) == 1
    {v, :okay, _} = SimDriver.read(d, R.offset(:ctrl))
    assert R.decode(:ctrl, v) == %{enable: 1, mode: :mono, gain: 0xAFFD}
    assert v < 0x8000_0000
  end

  test "array elements are independent" do
    {_, d} = driver()

    d =
      Enum.reduce(0..3, d, fn i, d ->
        {:okay, d} =
          SimDriver.write(
            d,
            R.offset(:level, i),
            R.encode(:level, value: 100 + i, mute: rem(i, 2))
          )

        d
      end)

    for i <- 0..3 do
      assert SimDriver.peek(d, :"level_#{i}_value") == 100 + i
      assert SimDriver.peek(d, :"level_#{i}_mute") == rem(i, 2)
    end

    {v, :okay, _} = SimDriver.read(d, R.offset(:level, 1))
    assert R.decode(:level, v) == %{value: 101, mute: 1}
  end

  test "w1c: hardware sets, software clears, a set in the same cycle wins" do
    {_, d} = driver()
    d = d |> SimDriver.poke(%{irq_underrun_set: 0b101}) |> SimDriver.idle(1)
    d = d |> SimDriver.poke(%{irq_underrun_set: 0}) |> SimDriver.idle(1)
    {v, :okay, d} = SimDriver.read(d, R.offset(:irq))
    assert R.decode(:irq, v).underrun == 0b101
    {:okay, d} = SimDriver.write(d, R.offset(:irq), R.encode(:irq, underrun: 0b001))
    assert SimDriver.peek(d, :irq_underrun) == 0b100
    # set held high through a clearing write: stays set
    d = SimDriver.poke(d, %{irq_overflow_set: 1})
    {:okay, d} = SimDriver.write(d, R.offset(:irq), R.encode(:irq, overflow: 1))
    assert SimDriver.peek(d, :irq_overflow) == 1
    d = SimDriver.poke(d, %{irq_overflow_set: 0})
    {:okay, d} = SimDriver.write(d, R.offset(:irq), R.encode(:irq, overflow: 1, underrun: 7))
    assert SimDriver.peek(d, :irq_overflow) == 0
    assert SimDriver.peek(d, :irq_underrun) == 0
  end

  test "w1s and rc" do
    {_, d} = driver()
    {:okay, d} = SimDriver.write(d, R.offset(:irq), R.encode(:irq, arm: 0b10))
    assert SimDriver.peek(d, :irq_arm) == 0b10
    {:okay, d} = SimDriver.write(d, R.offset(:irq), R.encode(:irq, arm: 0b01))
    assert SimDriver.peek(d, :irq_arm) == 0b11

    d =
      d
      |> SimDriver.poke(%{irq_arm_clr: 0b10})
      |> SimDriver.idle(1)
      |> SimDriver.poke(%{irq_arm_clr: 0})

    assert SimDriver.peek(d, :irq_arm) == 0b01

    d = d |> SimDriver.poke(%{irq_events_set: 0x81}) |> SimDriver.idle(1)
    d = d |> SimDriver.poke(%{irq_events_set: 0}) |> SimDriver.idle(1)
    {v, :okay, d} = SimDriver.read(d, R.offset(:irq))
    assert R.decode(:irq, v).events == 0x81
    {v, :okay, d} = SimDriver.read(d, R.offset(:irq))
    assert R.decode(:irq, v).events == 0
    # a set held through the read survives it
    d = SimDriver.poke(d, %{irq_events_set: 0x04})
    {_, :okay, d} = SimDriver.read(d, R.offset(:irq))
    assert SimDriver.peek(d, :irq_events) == 0x04
  end

  test "strobes pulse once, the write strobe with the new value" do
    {tb, d} = driver(delays: 0..3, seed: 9)
    d = SimDriver.idle(d, 3)
    {:okay, d} = SimDriver.write(d, R.offset(:ctrl), R.encode(:ctrl, gain: 0x1111))
    {_, :okay, d} = SimDriver.read(d, R.offset(:irq))
    {:okay, d} = SimDriver.write(d, R.offset(:irq), 0)
    out = replay(tb, d)

    wr = for {o, i} <- Enum.with_index(out), o.ctrl_wr == 1, do: i
    assert [i] = wr
    assert Enum.at(out, i).ctrl_gain == 0x1111
    assert Enum.at(out, i - 1).ctrl_gain == 0x4000
    assert Enum.count(out, &(&1.irq_rd == 1)) == 1
    assert Enum.count(out, &(&1.irq_wr == 1)) == 1
  end

  test "windows read and write the RAMs with their latencies" do
    {_, d} = driver(delays: 0..2, seed: 2)
    {:okay, d} = SimDriver.write(d, R.window_offset(:coeffs, 3), 0xDEADBEEF)
    {:okay, d} = SimDriver.write(d, R.window_offset(:coeffs, 3), 0x0000_5500, 0b0010)
    {:okay, d} = SimDriver.write(d, R.window_offset(:lut, 7), 0x1234_5678)
    {v, :okay, d} = SimDriver.read(d, R.window_offset(:coeffs, 3))
    assert v == 0xDEAD55EF
    {v, :okay, d} = SimDriver.read(d, R.window_offset(:lut, 7))
    assert v == 0x1234_5678
    {v, :okay, _} = SimDriver.read(d, R.window_offset(:lut, 6))
    assert v == 0
  end

  test "unmapped addresses read 0 with OKAY or SLVERR" do
    {_, d} = driver()
    {0, :okay, d} = SimDriver.read(d, 0x1FC)
    {:okay, _} = SimDriver.write(d, 0x1FC, 1)
    {_, d} = driver(unmapped: :slverr)
    {0, :slverr, d} = SimDriver.read(d, 0x1FC)
    {:slverr, d} = SimDriver.write(d, 0x1FC, 1)
    {_, :okay, _} = SimDriver.read(d, R.offset(:ctrl))
  end

  property "random transactions with random delays match the reference model" do
    map = R.regmap()

    check all(seed <- integer(1..10_000), n <- integer(5..40), max_runs: 15) do
      cmds = RegsTB.random_cmds(map, n, seed)
      {_, d} = driver(delays: 0..3, seed: seed)
      d = SimDriver.poke(d, %{id_channels: 7})

      {got, _} =
        Enum.map_reduce(cmds, d, fn
          {:write, a, v, s}, d ->
            {resp, d} = SimDriver.write(d, a, v, s)
            {{0, 0, resp}, d}

          {:read, a}, d ->
            {v, resp, d} = SimDriver.read(d, a)
            {{1, v, resp}, d}
        end)

      assert got == RegsTB.model_run(RegsTB.model_new(map, %{id_channels: 7}), cmds)
    end
  end

  test "RTL master bench: every command completes and matches the model" do
    map = R.regmap()
    cmds = RegsTB.random_cmds(map, 80, 11)
    {out, _} = master_run(map, cmds, 2500, 4)
    assert List.last(out).done == 1
    assert results(out) == RegsTB.model_run(RegsTB.model_new(map), cmds)
  end

  @tag :verilator
  test "co-simulates the driver run" do
    {tb, d} = driver(delays: 0..3, seed: 21)
    d = SimDriver.poke(d, %{id_channels: 3, irq_events_set: 1})

    d =
      Enum.reduce(RegsTB.random_cmds(R.regmap(), 60, 4), d, fn
        {:write, a, v, s}, d -> SimDriver.write(d, a, v, s) |> elem(1)
        {:read, a}, d -> SimDriver.read(d, a) |> elem(2)
      end)

    Cosim.assert_equivalent(tb, SimDriver.stimulus(d))
  end

  @tag :verilator
  test "co-simulates the RTL master bench with random stalls and hardware events" do
    map = R.regmap()
    cmds = RegsTB.random_cmds(map, 60, 12)
    {_, stim} = master_run(map, cmds, 2000, 5, hw: true)
    Cosim.assert_equivalent(RegsTB.bench(map, master: cmds), stim)
  end

  defp master_run(map, cmds, n, seed, opts \\ []) do
    :rand.seed(:exsss, {seed, 1, 1})
    bit = fn pct -> if :rand.uniform(100) <= pct, do: 1, else: 0 end

    stim =
      for i <- 1..n do
        base = %{
          rst_n: if(i <= 2, do: 0, else: 1),
          bstall: bit.(30),
          rstall: bit.(30),
          hold_aw: bit.(40),
          hold_w: bit.(40),
          hold_ar: bit.(40)
        }

        if opts[:hw] do
          Map.merge(base, %{
            id_channels: :rand.uniform(256) - 1,
            irq_overflow_set: bit.(5),
            irq_underrun_set: bit.(5) * 3,
            irq_arm_clr: bit.(5) * 2,
            irq_events_set: bit.(5) * 0x11
          })
        else
          base
        end
      end

    {_, out} = map |> RegsTB.bench(master: cmds) |> Sim.new() |> Sim.run(stim)
    {out, stim}
  end

  defp results(out) do
    for o <- out, o.res_valid == 1 do
      {o.res_read, o.res_data, Enum.at([:okay, :exokay, :slverr, :decerr], o.res_resp)}
    end
  end
end
