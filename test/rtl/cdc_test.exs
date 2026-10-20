defmodule ExHdl.RTL.CDCTest do
  use ExUnit.Case, async: true
  use ExHdl.RTL

  alias ExHdl.RTL.{CDC, Cosim, DomainError, Sim}
  alias ExHdl.Test.RTLDesigns

  @two [src: [period: 10], dst: [period: 7, phase: 2]]

  test "sync_ff: two-stage latency, ASYNC_REG on every stage" do
    m = CDC.sync_ff(width: 3)
    assert Enum.find(m.ports, &(&1.name == :d)).domain == :async
    assert Enum.all?([:s0, :s1], &m.signals[&1].attrs[:async_reg])
    src = ExHdl.Backends.SystemVerilog.RTL.module_source(m)
    assert src =~ ~s|(* ASYNC_REG = "TRUE" *) logic [2:0] s0;|

    {_, out} = m |> Sim.new() |> Sim.run([%{d: 5}, %{d: 6}, %{d: 7}, %{}, %{}])
    assert Enum.map(out, & &1.q) == [0, 0, 5, 6, 7]
  end

  test "reset_sync: asynchronous assertion, synchronous deassertion" do
    sim = CDC.reset_sync() |> Sim.new() |> Sim.poke(:arst_n, 1) |> Sim.step(3)
    assert Sim.peek(sim, :rst_n) == 1
    sim = Sim.poke(sim, :arst_n, 0)
    assert Sim.peek(sim, :rst_n) == 0
    sim = sim |> Sim.step() |> Sim.poke(:arst_n, 1)
    assert Sim.peek(sim, :rst_n) == 0
    sim = Sim.step(sim)
    assert Sim.peek(sim, :rst_n) == 0
    assert sim |> Sim.step() |> Sim.peek(:rst_n) == 1
  end

  test "handshake moves every word across clocks" do
    m = CDC.handshake(16)
    words = [0xBEEF, 1, 2, 0xFFFF, 1234]
    sim = Sim.new(m, clocks: @two)

    sim =
      sim
      |> Sim.poke(%{rst_src_n: 0, rst_dst_n: 0})
      |> Sim.step(6)
      |> Sim.poke(%{rst_src_n: 1, rst_dst_n: 1})

    {_, got, _} =
      Enum.reduce(1..400, {sim, [], words}, fn _, {sim, got, todo} ->
        sim =
          Sim.poke(sim, %{s_valid: if(todo == [], do: 0, else: 1), s_data: List.first(todo, 0)})

        accepted = todo != [] and Sim.peek(sim, :s_ready) == 1 and :clk_src in Sim.next_edges(sim)

        got =
          if Sim.peek(sim, :d_valid) == 1 and :clk_dst in Sim.next_edges(sim),
            do: [Sim.peek(sim, :d_data) | got],
            else: got

        {Sim.step(sim), got, if(accepted, do: tl(todo), else: todo)}
      end)

    assert Enum.reverse(got) == words
  end

  test "gray/ungray round trip" do
    m =
      module "gray5" do
        x = input(:x, 5)
        g = output(:g, 5)
        b = output(:b, 5)
        g <~ CDC.gray(x)
        b <~ CDC.ungray(CDC.gray(x))
      end

    sim = Sim.new(m)

    for x <- 0..31 do
      s = Sim.poke(sim, :x, x)
      assert Sim.peek(s, :b) == x
      assert Sim.peek(s, :g) == Bitwise.bxor(x, Bitwise.bsr(x, 1))
    end
  end

  describe "the domain check" do
    test "rejects combinational logic mixing domains" do
      assert_raise DomainError, ~r/y combines .* combinationally; cross clock domains/, fn ->
        module "mix" do
          domain(:a)
          domain(:b)
          x = input(:x, 1, domain: :a)
          z = input(:z, 1, domain: :b)
          y = output(:y, 1)
          y <~ (x and z)
        end
      end
    end

    test "rejects instance inputs driven from the wrong domain" do
      assert_raise DomainError,
                   ~r/input pulse_in of instance p is in domain a, driven from x/,
                   fn ->
                     module "wrong_inst" do
                       domain(:a)
                       domain(:b)
                       x = input(:x, 1, domain: :b)
                       p = instance(:p, CDC.pulse_sync(), domains: [src: :a, dst: :b])
                       p.pulse_in <~ x
                     end
                   end
    end

    test "accepts static inputs and domains sharing a clock" do
      m =
        module "ok" do
          domain(:a)
          domain(:a2, clock: :clk_a, reset: :rst_a2_n)
          cfg = input(:cfg, 4, domain: :static)
          x = input(:x, 4, domain: :a)
          r = reg(:r, 4, domain: :a2)
          y = output(:y, 4)
          sync(:a2, do: r <~ bxor(x, cfg))
          y <~ r
        end

      assert Enum.find(m.ports, &(&1.name == :y)).domain == :a
    end
  end

  test "async FIFO from the primitives keeps order across clocks" do
    m = RTLDesigns.async_fifo(8, 3)
    clocks = [wr: [period: 10], rd: [period: 13, phase: 4]]
    sim = Sim.new(m, clocks: clocks)

    sim =
      sim
      |> Sim.poke(%{rst_wr_n: 0, rst_rd_n: 0})
      |> Sim.step(6)
      |> Sim.poke(%{rst_wr_n: 1, rst_rd_n: 1})

    data = Enum.to_list(1..40)
    :rand.seed(:exsss, {1, 2, 3})

    {_, got, _} =
      Enum.reduce(1..1500, {sim, [], data}, fn _, {sim, got, todo} ->
        wr = todo != [] and :rand.uniform(2) == 1
        rd = :rand.uniform(3) == 1

        sim =
          Sim.poke(sim, %{
            wr_en: if(wr, do: 1, else: 0),
            wr_data: List.first(todo, 0),
            rd_en: if(rd, do: 1, else: 0)
          })

        edges = Sim.next_edges(sim)
        pushed = wr and Sim.peek(sim, :full) == 0 and :clk_wr in edges
        popped = rd and Sim.peek(sim, :empty) == 0 and :clk_rd in edges
        got = if popped, do: [Sim.peek(sim, :rd_data) | got], else: got
        {Sim.step(sim), got, if(pushed, do: tl(todo), else: todo)}
      end)

    assert Enum.reverse(got) == data
  end

  describe "Verilator" do
    @describetag :verilator
    @describetag timeout: 300_000

    defp stim(m, n, seed) do
      :rand.seed(:exsss, {seed, 9, 9})

      for i <- 0..(n - 1) do
        resets =
          for p <- m.ports, p.role == :reset, into: %{}, do: {p.name, if(i < 4, do: 0, else: 1)}

        m
        |> ExHdl.RTL.Module.data_inputs()
        |> Map.new(fn p -> {p.name, :rand.uniform(Bitwise.bsl(1, elem(p.type, 1))) - 1} end)
        |> Map.merge(resets)
      end
    end

    test "CDC cells co-simulate" do
      for {m, clocks} <- [
            {CDC.sync_ff(width: 4, stages: 3, reset: true), []},
            {CDC.pulse_sync(), @two},
            {CDC.reset_sync(), []},
            {CDC.handshake(8), @two}
          ] do
        Cosim.assert_equivalent(m, stim(m, 400, 1), clocks: clocks)
      end
    end

    test "async FIFO co-simulates with two clocks" do
      m = RTLDesigns.async_fifo(8, 3)

      Cosim.assert_equivalent(m, stim(m, 800, 2),
        clocks: [wr: [period: 10], rd: [period: 13, phase: 4]]
      )
    end
  end
end
