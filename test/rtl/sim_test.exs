defmodule ExHdl.RTL.SimTest do
  use ExUnit.Case, async: true
  use ExHdl.RTL

  alias ExHdl.RTL.{Cosim, ElaborationError, Examples, Sim}
  alias ExHdl.Test.RTLDesigns

  test "poke, step, peek, reset and cycles" do
    sim = Examples.counter(4) |> Sim.new() |> Sim.reset()
    assert Sim.cycles(sim) == 2
    sim = sim |> Sim.poke(:en, 1) |> Sim.step(17)
    assert Sim.peek(sim, :count) == 1
    assert Sim.peek(sim, "count") == 1
    assert Sim.time(sim) == 180
    assert_raise ArgumentError, ~r/does not fit u1/, fn -> Sim.poke(sim, :en, 2) end
    assert_raise ArgumentError, ~r/not a drivable input/, fn -> Sim.poke(sim, :clk, 1) end
    assert_raise ArgumentError, ~r/no signal/, fn -> Sim.peek(sim, :nope) end
  end

  test "run/2 samples outputs before each edge" do
    {_sim, out} =
      Examples.counter(8)
      |> Sim.new()
      |> Sim.run([%{rst_n: 0}, %{rst_n: 1, en: 1}, %{}, %{}, %{en: 0}, %{}])

    assert Enum.map(out, & &1.count) == [0, 0, 1, 2, 3, 3]
  end

  test "registers without reset keep running during reset; sync vs async reset" do
    build = fn kind ->
      module "rst_#{kind}" do
        domain(:sys, reset_kind: kind)
        d = input(:d, 4)
        r = output(:r, 4, reset: 9)
        n = output(:n, 4, reg: true, reset: nil)

        sync do
          r <~ d
          n <~ d
        end
      end
    end

    sim = build.(:sync) |> Sim.new() |> Sim.poke(%{rst_n: 1, d: 5}) |> Sim.step()
    assert {Sim.peek(sim, :r), Sim.peek(sim, :n)} == {5, 5}
    sim = Sim.poke(sim, %{rst_n: 0, d: 6})
    assert Sim.peek(sim, :r) == 5
    sim = Sim.step(sim)
    assert {Sim.peek(sim, :r), Sim.peek(sim, :n)} == {9, 6}

    sim = build.(:async) |> Sim.new() |> Sim.poke(%{rst_n: 1, d: 5}) |> Sim.step()
    sim = Sim.poke(sim, :rst_n, 0)
    assert Sim.peek(sim, :r) == 9
    sim = sim |> Sim.poke(:d, 7) |> Sim.step()
    assert {Sim.peek(sim, :r), Sim.peek(sim, :n)} == {9, 7}
  end

  test "clocks with periods and phases give a merged, deterministic event schedule" do
    m = Examples.pulse_counter()

    events = Sim.schedule(m, 6, clocks: [a: [period: 10], b: [period: 15, phase: 5]])

    assert events == [
             {0, [:clk_a]},
             {5, [:clk_b]},
             {10, [:clk_a]},
             {20, [:clk_a, :clk_b]},
             {30, [:clk_a]},
             {35, [:clk_b]}
           ]

    sim = Sim.new(m, clocks: [a: [period: 10], b: [period: 15, phase: 5]])
    sim = Sim.step(sim, 4)
    assert {Sim.cycles(sim, :a), Sim.cycles(sim, :b)} == {3, 2}
    assert Sim.next_edges(sim) == [:clk_a]
    sim = Sim.cycle(sim, :b, 2)
    assert Sim.cycles(sim, :b) == 4
  end

  test "trace and VCD" do
    sim =
      Examples.counter(4)
      |> Sim.new(trace: true)
      |> Sim.reset()
      |> Sim.poke(:en, 1)
      |> Sim.step(3)

    trace = Sim.trace(sim)
    assert {_, _, %{"count" => 3}} = List.last(trace)
    vcd = sim |> Sim.vcd() |> IO.iodata_to_binary()
    assert vcd =~ "$timescale 1ns $end"
    assert vcd =~ ~r/\$var wire 4 \S+ count \$end/
    assert vcd =~ ~r/\$var wire 1 \S+ clk \$end/
    assert vcd =~ "#45\n"
    assert vcd =~ "b11 "

    path =
      Path.join(System.tmp_dir!(), "ex_hdl_sim_test_#{System.unique_integer([:positive])}.vcd")

    Sim.write_vcd(sim, path)
    assert File.read!(path) == vcd
    File.rm!(path)

    assert_raise ArgumentError, ~r/trace: true/, fn ->
      Examples.counter(4) |> Sim.new() |> Sim.trace()
    end
  end

  test "hierarchical peek and memories" do
    sim = Examples.pulse_counter() |> Sim.new()
    assert Sim.peek(sim, "ps.toggle") == 0

    sim =
      Examples.ram(width: 16, depth: 16, init: [1, 2, 3])
      |> Sim.new()
      |> Sim.poke(%{we: 1, be: 3, waddr: 5, wdata: 77})
      |> Sim.step()

    assert Sim.peek_memory(sim, "mem", 5) == 77
    assert Sim.peek_memory(sim, "mem", 2) == 3
  end

  test "black boxes simulate with their model and raise without one" do
    sim = RTLDesigns.delay_top(3) |> Sim.new()
    {_, out} = Sim.run(sim, Enum.map([10, 20, 30, 40, 50], &%{d: &1}))
    assert Enum.map(out, & &1.q) == [1, 1, 1, 11, 21]

    no_model =
      black_box "opaque" do
        input(:a, 1)
        output(:y, 1)
      end

    top =
      module "uses_opaque" do
        a = input(:a, 1)
        y = output(:y, 1)
        u = instance(:u, no_model, connect: [a: a])
        y <~ u.y
      end

    assert_raise ElaborationError, ~r/black box opaque \(u\) has no simulation model/, fn ->
      Sim.new(top)
    end
  end

  @tag :verilator
  test "a modelled black box with its SV source co-simulates" do
    stim = for d <- [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5], do: %{d: d}
    Cosim.assert_equivalent(RTLDesigns.delay_top(3), stim)
  end
end
