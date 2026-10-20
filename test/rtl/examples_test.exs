defmodule ExHdl.RTL.ExamplesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  alias ExHdl.RTL.{Cosim, DomainError, Examples, Interface, Sim}

  doctest ExHdl.RTL.Examples

  defp random_stimulus(mod, n, seed, fixed \\ %{}) do
    :rand.seed(:exsss, {seed, 1, 2})

    inputs = ExHdl.RTL.Module.data_inputs(mod)

    for i <- 0..(n - 1) do
      base = Map.new(inputs, fn p -> {p.name, rand_in(p.type)} end)

      resets =
        for p <- mod.ports, p.role == :reset, into: %{}, do: {p.name, if(i < 2, do: 0, else: 1)}

      base |> Map.merge(resets) |> Map.merge(fixed)
    end
  end

  defp rand_in({:u, w}), do: :rand.uniform(1 <<< w) - 1
  defp rand_in({:s, w}), do: :rand.uniform(1 <<< w) - 1 - (1 <<< (w - 1))

  describe "counter" do
    test "counts while enabled and wraps" do
      {_, out} =
        Examples.counter(2)
        |> Sim.new()
        |> Sim.run([%{rst_n: 0}, %{rst_n: 1, en: 1}, %{}, %{}, %{}, %{}, %{en: 0}, %{}])

      assert Enum.map(out, & &1.count) == [0, 0, 1, 2, 3, 0, 1, 1]
    end

    @tag :verilator
    test "co-simulates" do
      m = Examples.counter(8)
      Cosim.assert_equivalent(m, random_stimulus(m, 300, 1))
    end
  end

  describe "crc32" do
    setup do
      %{sim: Examples.crc32() |> Sim.new() |> Sim.reset()}
    end

    defp crc_frames(sim, frames) do
      Enum.map_reduce(frames, sim, fn frame, sim ->
        sim =
          frame
          |> :binary.bin_to_list()
          |> Enum.with_index()
          |> Enum.reduce(sim, fn {b, i}, sim ->
            sim |> Sim.poke(%{data: b, valid: 1, clear: if(i == 0, do: 1, else: 0)}) |> Sim.step()
          end)
          |> Sim.poke(%{valid: 0, clear: 0})

        {Sim.peek(sim, :crc), sim}
      end)
      |> elem(0)
    end

    test "matches :erlang.crc32/1 on known frames", %{sim: sim} do
      frames = [
        "123456789",
        "The quick brown fox jumps over the lazy dog",
        <<0>>,
        <<255, 255, 255, 255>>
      ]

      assert crc_frames(sim, frames) == Enum.map(frames, &:erlang.crc32/1)
      assert hd(crc_frames(sim, ["123456789"])) == 0xCBF43926
    end

    property "matches :erlang.crc32/1 on random back-to-back frames", %{sim: sim} do
      check all(
              frames <-
                list_of(binary(min_length: 1, max_length: 40), min_length: 1, max_length: 4),
              max_runs: 40
            ) do
        assert crc_frames(sim, frames) == Enum.map(frames, &:erlang.crc32/1)
      end
    end

    test "clear without valid restarts" do
      sim = Examples.crc32() |> Sim.new() |> Sim.reset()

      sim =
        sim
        |> Sim.poke(%{data: 7, valid: 1})
        |> Sim.step()
        |> Sim.poke(%{valid: 0, clear: 1})
        |> Sim.step()

      assert Sim.poke(sim, :clear, 0) |> Sim.peek(:crc) == :erlang.crc32(<<>>)
    end

    @tag :verilator
    test "co-simulates" do
      m = Examples.crc32()
      Cosim.assert_equivalent(m, random_stimulus(m, 400, 2))
    end
  end

  describe "skid buffer" do
    # Drives AXI4-Stream traffic (tvalid held until accepted) and checks
    # data integrity, output stability under backpressure and throughput.
    defp drive(m, beats, valid_pct, ready_pct, seed) do
      :rand.seed(:exsss, {seed, 3, 4})
      sim = m |> Sim.new() |> Sim.reset()

      Enum.reduce_while(1..(length(beats) * 20 + 50), {sim, beats, [], nil, 0}, fn _,
                                                                                   {sim, todo,
                                                                                    got,
                                                                                    last_stall,
                                                                                    cycles} ->
        offer = todo != [] and :rand.uniform(100) <= valid_pct
        ready = :rand.uniform(100) <= ready_pct
        {data, last} = if todo != [], do: hd(todo), else: {0, 0}

        sim =
          Sim.poke(sim, %{
            s_axis_tvalid: if(offer, do: 1, else: 0),
            s_axis_tdata: data,
            s_axis_tkeep: 15,
            s_axis_tlast: last,
            m_axis_tready: if(ready, do: 1, else: 0)
          })

        out = Sim.outputs(sim)
        stall = if out.m_axis_tvalid == 1 and not ready, do: {out.m_axis_tdata, out.m_axis_tlast}

        if last_stall do
          assert out.m_axis_tvalid == 1
          assert {out.m_axis_tdata, out.m_axis_tlast} == last_stall
        end

        got =
          if out.m_axis_tvalid == 1 and ready,
            do: [{out.m_axis_tdata, out.m_axis_tlast} | got],
            else: got

        todo = if offer and out.s_axis_tready == 1, do: tl(todo), else: todo
        sim = Sim.step(sim)

        if todo == [] and length(got) == length(beats),
          do: {:halt, {Enum.reverse(got), cycles + 1}},
          else: {:cont, {sim, todo, got, stall, cycles + 1}}
      end)
    end

    property "passes every beat once, in order, holding outputs under backpressure" do
      m = Examples.skid_buffer()

      check all(
              beats <-
                list_of(tuple({integer(0..0xFFFF_FFFF), integer(0..1)}),
                  min_length: 1,
                  max_length: 30
                ),
              valid_pct <- integer(20..100),
              ready_pct <- integer(20..100),
              seed <- integer(0..1000),
              max_runs: 60
            ) do
        assert {^beats, _} = drive(m, beats, valid_pct, ready_pct, seed)
      end
    end

    test "full throughput: one beat per cycle without backpressure" do
      beats = for i <- 1..50, do: {i, 0}
      assert {^beats, cycles} = drive(Examples.skid_buffer(), beats, 100, 100, 1)
      assert cycles == 51
    end

    test "works for other stream interfaces" do
      m = Examples.skid_buffer(Interface.axi_stream(data: 12, keep: false, user: 3))
      assert m.name == "axis_skid_data12_last1_user3"
    end

    @tag :verilator
    test "co-simulates" do
      m = Examples.skid_buffer()
      Cosim.assert_equivalent(m, random_stimulus(m, 400, 3))
    end
  end

  describe "pulse counter (two domains)" do
    @clocks [a: [period: 10], b: [period: 7, phase: 3]]

    test "every pulse from :a is counted once in :b" do
      sim = Examples.pulse_counter() |> Sim.new(clocks: @clocks)

      sim =
        Sim.poke(sim, %{rst_a_n: 0, rst_b_n: 0})
        |> Sim.step(4)
        |> Sim.poke(%{rst_a_n: 1, rst_b_n: 1})

      sim =
        Enum.reduce(0..59, sim, fn k, sim ->
          sim |> Sim.poke(:fire, if(rem(k, 6) == 0, do: 1, else: 0)) |> Sim.cycle(:a)
        end)

      sim = sim |> Sim.poke(:fire, 0) |> Sim.cycle(:b, 10)
      assert Sim.peek(sim, :seen) == 10
      assert Sim.peek(sim, :count) == 10
    end

    test "using an :a signal in :b logic is rejected" do
      assert_raise DomainError,
                   ~r/register count \(domain b\) samples fire from domain a.*CDC/,
                   fn ->
                     use ExHdl.RTL

                     module "bad_crossing" do
                       domain(:a, clock: :clk_a, reset: :rst_a_n)
                       domain(:b, clock: :clk_b, reset: :rst_b_n)
                       fire = input(:fire, 1, domain: :a)
                       count = output(:count, 8, reset: 0, domain: :b)

                       sync :b do
                         if fire, do: count <~ add_wrap(count, 1)
                       end
                     end
                   end
    end

    @tag :verilator
    test "co-simulates with two clocks" do
      m = Examples.pulse_counter()

      stim =
        random_stimulus(m, 600, 4)
        |> Enum.map(&Map.put(&1, :fire, if(:rand.uniform(4) == 1, do: 1, else: 0)))

      Cosim.assert_equivalent(m, stim, clocks: @clocks)
    end
  end

  describe "burst FSM" do
    test "busy for n + 1 cycles, done in the last" do
      {_, out} =
        Examples.burst_fsm(3)
        |> Sim.new()
        |> Sim.run([%{rst_n: 0}, %{rst_n: 1, start: 1}, %{start: 0}] ++ List.duplicate(%{}, 6))

      assert Enum.map(out, &{&1.busy, &1.done}) ==
               [{0, 0}, {0, 0}, {1, 0}, {1, 0}, {1, 0}, {1, 1}, {0, 0}, {0, 0}, {0, 0}]
    end

    test "SV uses the state names" do
      src = ExHdl.Backends.SystemVerilog.RTL.module_source(Examples.burst_fsm(3))
      assert src =~ "localparam logic [1:0] CTRL_RUN = 2'd1;"
      assert src =~ "CTRL_RUN: begin"
      assert src =~ "ctrl_state <= CTRL_DONE;"
    end

    @tag :verilator
    test "co-simulates" do
      m = Examples.burst_fsm(5)
      Cosim.assert_equivalent(m, random_stimulus(m, 300, 5))
    end
  end

  describe "ram" do
    defp ram_ref(ops) do
      Enum.map_reduce(ops, {%{}, 0}, fn op, {mem, rdata} ->
        rdata_next = if op.re == 1, do: Map.get(mem, op.raddr, 0), else: rdata

        mem =
          if op.we == 1 do
            mask =
              Enum.reduce(0..3, 0, fn i, acc ->
                if (op.be >>> i &&& 1) == 1, do: acc ||| 0xFF <<< (8 * i), else: acc
              end)

            old = Map.get(mem, op.waddr, 0)
            Map.put(mem, op.waddr, (old &&& ~~~mask) ||| (op.wdata &&& mask))
          else
            mem
          end

        {rdata, {mem, rdata_next}}
      end)
      |> elem(0)
    end

    defp ram_ops(n, seed) do
      :rand.seed(:exsss, {seed, 5, 6})

      for _ <- 1..n do
        %{
          we: :rand.uniform(2) - 1,
          be: :rand.uniform(16) - 1,
          waddr: :rand.uniform(8) - 1,
          wdata: :rand.uniform(1 <<< 32) - 1,
          re: :rand.uniform(2) - 1,
          raddr: :rand.uniform(8) - 1
        }
      end
    end

    test "byte enables and read-first sync reads match a reference" do
      ops = ram_ops(500, 1)
      {_, out} = Examples.ram(depth: 16) |> Sim.new() |> Sim.run(ops)
      assert Enum.map(out, & &1.rdata) == ram_ref(ops)
    end

    test "SV follows the inference template" do
      src = ExHdl.Backends.SystemVerilog.RTL.module_source(Examples.ram())
      assert src =~ ~s|(* ram_style = "block" *)\n  logic [31:0] mem [0:1023];|
      assert src =~ "if (be[1]) mem[waddr][15:8] <= wdata[15:8];"
      assert src =~ "mem_rd0 <= mem[raddr];"
    end

    @tag :verilator
    test "co-simulates" do
      ops = ram_ops(500, 2)
      Cosim.assert_equivalent(Examples.ram(depth: 16), ops)
    end

    @tag :yosys
    @tag timeout: 300_000
    test "infers block RAM, URAM and LUTRAM" do
      util = fn m, family ->
        {:ok, u} =
          ExHdl.Synth.Yosys.utilization(ExHdl.Backends.SystemVerilog.RTL.generate(m), m.name,
            family: family
          )

        u
      end

      assert %{bram18: 2, lutram: 0} = util.(Examples.ram(), "xc7")
      assert %{bram18: 2} = util.(Examples.ram(), "xcup")

      assert %{uram: 1, bram18: 0} =
               util.(Examples.ram(style: :ultra, width: 64, depth: 4096), "xcup")

      assert %{bram18: 0, uram: 0, lutram: lutram} =
               util.(Examples.ram(style: :distributed, width: 16, depth: 64), "xc7")

      assert lutram > 0
      assert %{bram18: 1, lutram: 0} = util.(ExHdl.Test.RTLDesigns.tdp_ram(), "xcup")
    end
  end
end
