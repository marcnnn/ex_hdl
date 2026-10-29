defmodule ExHdl.RTL.StatefulTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias ExHdl.Backends.SystemVerilog.RTL, as: SV
  alias ExHdl.RTL.Sim
  alias ExHdl.Synth.Yosys

  # A stateful counter with enable and synchronous clear
  defmodule SimpleCounter do
    use ExHdl.Stateful

    ports do
      input :en, 1
      input :clear, 1
      output :count, 8
      output :overflow, 1
    end

    state do
      reg :count, 8, reset: 0
    end

    def step(inputs, state) do
      # Pure software & hardware multiplexer transition
      next_count =
        mux(
          inputs.clear == 1,
          0,
          mux(inputs.en == 1, add_wrap(state.count, 1, 8), state.count)
        )

      outputs = %{
        count: state.count,
        overflow: state.count == 255
      }

      next_state = %{state | count: next_count}
      {outputs, next_state}
    end
  end

  # Multi-state FSM using functional match/2
  defmodule BurstEngine do
    use ExHdl.Stateful

    ports do
      input :start, 1
      output :busy, 1
      output :done, 1
    end

    state do
      # 0: idle, 1: burst, 2: done
      reg :mode, 2, reset: 0
      reg :count, 4, reset: 0
    end

    def step(inputs, state) do
      is_last = state.count == 3

      next_mode =
        match(state.mode, [
          {0, mux(inputs.start == 1, 1, 0)},
          {1, mux(is_last, 2, 1)},
          {2, 0}
        ])

      next_count =
        match(state.mode, [
          {0, 0},
          {1, add_wrap(state.count, 1, 4)},
          {2, 0}
        ])

      outputs = %{
        busy: state.mode == 1,
        done: state.mode == 2
      }

      next_state = %{state | mode: next_mode, count: next_count}
      {outputs, next_state}
    end
  end

  test "simulates in pure Elixir on the BEAM" do
    # Stream of clock cycles
    stimulus = [
      %{en: 1, clear: 0},
      %{en: 1, clear: 0},
      %{en: 1, clear: 0},
      # count holds at 3
      %{en: 0, clear: 0},
      # count advances to 4
      %{en: 1, clear: 0},
      # clear takes effect for next cycle
      %{en: 1, clear: 1}
    ]

    {outputs, final_state} = SimpleCounter.simulate(stimulus)

    # Verify cycle-by-cycle outputs
    counts = Enum.map(outputs, & &1.count)
    assert counts == [0, 1, 2, 3, 3, 4]
    assert final_state.count == 0
  end

  test "elaborates to a valid ExHdl.RTL.Module" do
    m = SimpleCounter.build()

    assert m.name == "simple_counter"
    # clk, rst_n, en, clear, count, overflow
    assert length(m.ports) == 6
    assert Map.has_key?(m.signals, :count)

    # Generate SystemVerilog
    sources = SV.generate(m)
    assert Map.has_key?(sources, "simple_counter.sv")
    sv_code = sources["simple_counter.sv"]

    assert sv_code =~ "en"
    assert sv_code =~ "count"
    assert sv_code =~ "always_ff @(posedge clk"
  end

  test "synthesizes to FPGA hardware with Yosys" do
    m = SimpleCounter.build()
    sources = SV.generate(m)

    assert {:ok, u} = Yosys.utilization(sources, m.name)
    assert u.ff == 8
    assert u.lut > 0
    assert u.bram36 == 0.0
  end

  test "matches RTL simulator" do
    m = SimpleCounter.build()
    sim = Sim.new(m) |> Sim.reset()

    # Step through Sim
    sim = Sim.poke(sim, %{en: 1, clear: 0}) |> Sim.step()
    assert Sim.peek(sim, :count) == 1

    sim = Sim.poke(sim, %{en: 1, clear: 0}) |> Sim.step()
    assert Sim.peek(sim, :count) == 2

    sim = Sim.poke(sim, %{en: 0, clear: 0}) |> Sim.step()
    assert Sim.peek(sim, :count) == 2

    sim = Sim.poke(sim, %{en: 0, clear: 1}) |> Sim.step()
    assert Sim.peek(sim, :count) == 0
  end

  test "BurstEngine FSM works in software and synthesizes to hardware" do
    # 1. Pure BEAM simulation of 4-cycle burst
    stimulus = [
      %{start: 0},
      # begins burst
      %{start: 1},
      %{start: 0},
      %{start: 0},
      %{start: 0},
      %{start: 0},
      %{start: 0}
    ]

    {outputs, _} = BurstEngine.simulate(stimulus)
    busies = Enum.map(outputs, & &1.busy)
    dones = Enum.map(outputs, & &1.done)

    assert busies == [false, false, true, true, true, true, false]
    assert dones == [false, false, false, false, false, false, true]

    # 2. Hardware elaboration & Yosys synthesis
    m = BurstEngine.build()
    # clk, rst_n, start, busy, done
    assert length(m.ports) == 5

    sources = SV.generate(m)
    assert {:ok, u} = Yosys.utilization(sources, m.name)
    # 2-bit binary (6) or one-hot (7) state FFs
    assert u.ff in [6, 7]
    assert u.lut > 0
  end

  test "unpack and pack helpers work on integers and hardware expressions" do
    # Software integer unpacking
    # word = 1 (valid=1) << 56 | 0x1234 (tag) << 24 | 0x5678 (sample)
    word = 1 <<< 56 ||| 0x1234 <<< 24 ||| 0x5678
    %{valid: v, tag: tag, sample: s} = ExHdl.Stateful.unpack(word, sample: 24, tag: 32, valid: 1)
    assert v == 1
    assert tag == 0x1234
    assert s == 0x5678

    # Tuple form
    {sample_val, tag_val, valid_val} = ExHdl.Stateful.unpack(word, [24, 32, 1])
    assert sample_val == 0x5678
    assert tag_val == 0x1234
    assert valid_val == 1
  end
end
