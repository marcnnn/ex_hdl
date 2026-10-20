defmodule ExHdl.RTL.SessionTest do
  @moduledoc """
  Closed-loop Verilator sessions (`ExHdl.RTL.Cosim.Session`) against the
  BEAM simulator, the agent bench on both, internal clocks, VCD dumps.
  """
  use ExUnit.Case, async: true
  use ExHdl.RTL

  alias ExHdl.RTL.{Bench, Cosim, Examples, Sim}
  alias ExHdl.RTL.Cosim.Session
  alias ExHdl.Test.RTLDesigns

  @moduletag :verilator
  @moduletag timeout: 600_000

  defmodule Source do
    @moduledoc false
    # AXI4-Stream source: offers the next beat with probability p, holds it until taken
    @behaviour ExHdl.RTL.Bench.Agent
    defstruct beats: [], p: 0.5, offer: false, sent: 0

    def drive(%{beats: [b | _]} = s, _cycle) do
      offer = s.offer or :rand.uniform() < s.p
      {%{s_axis_tvalid: if(offer, do: 1, else: 0), s_axis_tdata: b}, %{s | offer: offer}}
    end

    def drive(s, _cycle), do: {%{s_axis_tvalid: 0}, %{s | offer: false}}

    def sample(%{offer: true, beats: [_ | rest]} = s, %{s_axis_tready: 1}, _c),
      do: %{s | beats: rest, offer: false, sent: s.sent + 1}

    def sample(s, _outs, _c), do: s
  end

  defmodule Sink do
    @moduledoc false
    # random tready, collects beats
    @behaviour ExHdl.RTL.Bench.Agent
    defstruct got: [], p: 0.5, ready: 0

    def drive(s, _cycle) do
      r = if :rand.uniform() < s.p, do: 1, else: 0
      {%{m_axis_tready: r}, %{s | ready: r}}
    end

    def sample(%{ready: 1} = s, %{m_axis_tvalid: 1, m_axis_tdata: d}, _c),
      do: %{s | got: [d | s.got]}

    def sample(s, _outs, _c), do: s
  end

  test "a session follows the Sim API: poke, peek, step, reset, time, cycles" do
    m = Examples.counter(8)
    {:ok, s} = Cosim.open(m)
    sim = Sim.new(m)

    for {f, args} <- [
          {:reset, []},
          {:poke, [:en, 1]},
          {:step, [10]},
          {:poke, [%{en: 0}]},
          {:step, [3]},
          {:poke, [:en, 1]},
          {:step, [300]}
        ] do
      _ = apply(Session, f, [s | args])
    end

    sim = sim |> Sim.reset() |> Sim.poke(:en, 1) |> Sim.step(10) |> Sim.poke(%{en: 0})
    sim = sim |> Sim.step(3) |> Sim.poke(:en, 1) |> Sim.step(300)

    assert Session.peek(s, :count) == Sim.peek(sim, :count)
    assert Session.outputs(s) == Sim.outputs(sim)
    assert Session.time(s) == Sim.time(sim)
    assert Session.cycles(s) == Sim.cycles(sim)
    assert Session.peek(s, :en) == 1

    assert_raise ArgumentError, ~r/does not fit u1/, fn -> Session.poke(s, :en, 2) end
    assert_raise ArgumentError, ~r/not a drivable input/, fn -> Session.poke(s, :clk, 1) end
    assert_raise ArgumentError, ~r/no port/, fn -> Session.peek(s, :nope) end

    # step_until stops before the edge at which count reaches the value
    {s, k} = Session.step_until(s, :count, 7, 1000)
    assert Session.peek(s, :count) == 7
    assert k > 0
    assert Cosim.close(s) == :ok
  end

  test "two clocks: events, cycle/3 and run/2 agree with the BEAM" do
    m = Examples.pulse_counter()
    clocks = [a: [period: 10], b: [period: 15, phase: 5]]
    {:ok, s} = Session.open(m, clocks: clocks)
    sim = Sim.new(m, clocks: clocks)

    s = s |> Session.reset(3) |> Session.cycle(:b, 5)
    sim = sim |> Sim.reset(3) |> Sim.cycle(:b, 5)

    assert {Session.time(s), Session.cycles(s, :a), Session.cycles(s, :b)} ==
             {Sim.time(sim), Sim.cycles(sim, :a), Sim.cycles(sim, :b)}

    stim = for i <- 1..400, do: %{fire: rem(i * 7, 5) |> div(4)}
    {_, a} = Session.run(s, stim)
    {_, b} = Sim.run(sim, stim)
    assert a == b
    Session.close(s)
  end

  test "run/2 equals Cosim.run/3 and the BEAM, wide and signed ports" do
    m =
      module "sess_wide" do
        a = input(:a, 97)
        b = input(:b, s(12))
        y = output(:y, 97, reset: 0)
        z = output(:z, s(13))

        sync do
          y <~ add_wrap(y, a)
        end

        z <~ (b - 1)
      end

    :rand.seed(:exsss, {1, 2, 3})

    stim =
      for i <- 0..299,
          do: %{
            rst_n: if(i < 2, do: 0, else: 1),
            a: :rand.uniform(Bitwise.bsl(1, 97)) - 1,
            b: :rand.uniform(4096) - 2049
          }

    {:ok, s} = Session.open(m)
    {_, from_session} = Session.run(s, stim)
    Session.close(s)
    {:ok, c} = Cosim.build(m)
    assert {:ok, ^from_session} = Cosim.run(c, stim)
    {_, beam} = m |> Sim.new() |> Sim.run(stim)
    assert from_session == beam
  end

  test "an agent bench runs on the BEAM and in Verilator with the same result" do
    m = Examples.skid_buffer()
    beats = Enum.to_list(1..200)

    run = fn sim ->
      :rand.seed(:exsss, {7, 8, 9})

      sim
      |> Bench.new(src: %Source{beats: beats, p: 0.7}, sink: %Sink{p: 0.6})
      |> Bench.run_until(&(length(Bench.agent(&1, :sink).got) == 200), 5_000)
    end

    beam = run.(Sim.new(m))
    {:ok, s} = Cosim.open(m)
    ver = run.(s)
    Session.close(s)

    assert Enum.reverse(Bench.agent(beam, :sink).got) == beats
    assert Bench.agent(ver, :sink).got == Bench.agent(beam, :sink).got
    assert Bench.stimulus(ver) == Bench.stimulus(beam)
    assert beam.cycle == ver.cycle
    assert Bench.compare(beam) == :ok
  end

  test "Bench.drive/4 and reset for a module without registers" do
    m =
      module "sess_comb" do
        a = input(:a, 8)
        b = input(:b, 8)
        y = output(:y, 9)
        y <~ (a + b)
      end

    assert Sim.reset_inputs(m) == %{}

    loop = fn sim ->
      {_, events, outs, acc} =
        sim
        |> then(fn %mod{} = s -> mod.reset(s) end)
        |> Bench.drive(0, 20, fn acc, i -> {%{a: i, b: rem(acc, 256)}, &(&1.y + acc)} end)

      {events, outs, acc}
    end

    {:ok, s} = Session.open(m)
    assert loop.(Sim.new(m)) == loop.(s)
    Session.close(s)

    bench = m |> Sim.new() |> Bench.new([], idle: %{a: 3}) |> Bench.run(5)
    assert Bench.output(bench, :y) == 3
    assert Bench.compare(bench) == :ok
  end

  defmodule ClockGen do
    @moduledoc false
    @behaviour ExHdl.RTL.Model
    def init(_params), do: 0
    def outputs(_state, _inputs), do: %{CLKOUT0: 0, LOCKED: 1}
    def clock(:sys, state, _inputs), do: state
  end

  defp clock_gen do
    src = """
    module clock_gen (
      input  logic clk,
      output logic CLKOUT0,
      output logic LOCKED
    );
      assign CLKOUT0 = clk;
      assign LOCKED = 1'b1;
    endmodule
    """

    black_box "clock_gen", sources: %{"clock_gen.sv" => src}, model: ClockGen do
      domain(:sys, reset: nil)
      output(:CLKOUT0, 1, comb_from: :none)
      output(:LOCKED, 1, comb_from: :none)
    end
  end

  test "internal clocks (an MMCM-like black box) are substituted by harness clocks" do
    m =
      module "sess_intclk" do
        domain(:sys, reset: :rst_n)
        domain(:fast, clock: :clk_fast, clock_port: false, reset: :rst_fast_n, reset_port: false)
        q = output(:q, 8)
        n = output(:n, 8, reset: 0)
        r = reg(:r, 8, domain: :fast, reset: 0)
        u = instance(:u, clock_gen())
        signal(:clk_fast) <~ u[:CLKOUT0]
        signal(:rst_fast_n) <~ u[:LOCKED]

        sync :fast do
          r <~ add_wrap(r, 1)
        end

        sync do
          n <~ add_wrap(n, 1)
        end

        q <~ r
      end

    clocks = [sys: [period: 10], fast: [period: 4, phase: 1]]
    stim = for i <- 0..99, do: %{rst_n: if(i < 2, do: 0, else: 1)}
    assert Cosim.compare(m, stim, clocks: clocks) == :ok

    sub = Cosim.substitute_clocks(m)
    assert Enum.any?(sub.ports, &(&1.name == :clk_fast and &1.role == :clock))
    {_, out} = m |> Sim.new(clocks: clocks) |> Sim.run(stim)
    # 100 events over two clocks with periods 10 and 4: the fast clock rose about 2.5x as often
    assert List.last(out).q > 2 * List.last(out).n
  end

  test "a replayed trace and a session dump a Verilator VCD" do
    dir = Path.join(System.tmp_dir!(), "ex_hdl_vcd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    m = Examples.counter(4)
    stim = [%{rst_n: 0}, %{rst_n: 0}] ++ List.duplicate(%{rst_n: 1, en: 1}, 20)
    path = Path.join(dir, "replay.vcd")
    assert Cosim.compare(m, stim, vcd: path) == :ok
    vcd = File.read!(path)
    assert vcd =~ "$timescale 100ps $end"
    assert vcd =~ ~r/\$var wire\s+4 \S+ count \[3:0\] \$end/
    # rising edges at 10 * t
    assert vcd =~ "#100\n"

    {:ok, s} = Session.open(RTLDesigns.delay_top(3), vcd: Path.join(dir, "s.vcd"))
    s |> Session.poke(:d, 5) |> Session.step(4) |> Session.close()
    assert File.read!(Path.join(dir, "s.vcd")) =~ ~r/\$var wire\s+32 \S+ DEPTH/
    File.rm_rf!(dir)
  end

  test "Verilator flags are passed through and keyed in the cache" do
    m = Examples.counter(3)
    {:ok, a} = Cosim.build(m)
    {:ok, b} = Cosim.build(m, flags: ["-O3"])
    assert a.path != b.path
    stim = [%{rst_n: 0}] ++ List.duplicate(%{rst_n: 1, en: 1}, 10)
    assert Cosim.run(a, stim) == Cosim.run(b, stim)
  end
end
