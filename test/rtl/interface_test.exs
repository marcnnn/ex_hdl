defmodule ExHdl.RTL.InterfaceTest do
  use ExUnit.Case, async: true
  use ExHdl.RTL

  alias ExHdl.RTL.{ElaborationError, Examples, Sim}

  test "AXI4-Stream fields follow the options" do
    names = fn i -> Enum.map(i.fields, &elem(&1, 0)) end
    assert names.(Interface.axi_stream()) == [:tdata, :tkeep, :tlast, :tvalid, :tready]

    i = Interface.axi_stream(data: 64, user: 4, id: 2, dest: 3, strb: true)
    assert names.(i) == [:tdata, :tkeep, :tstrb, :tlast, :tid, :tdest, :tuser, :tvalid, :tready]
    assert {:tkeep, {:u, 8}, :fwd} in i.fields
    assert {:tready, {:u, 1}, :bwd} in i.fields
    assert names.(Interface.axi_stream(data: 12, last: false, ready: false)) == [:tdata, :tvalid]
  end

  test "AXI4-Lite and memory ports" do
    l = Interface.axi_lite(addr: 12)
    assert {:awaddr, {:u, 12}, :fwd} in l.fields
    assert {:rdata, {:u, 32}, :bwd} in l.fields
    assert {:bready, {:u, 1}, :fwd} in l.fields
    assert length(l.fields) == 19

    mp = Interface.mem_port(addr: 10, data: 32, be: true)
    assert Enum.map(mp.fields, &elem(&1, 0)) == [:en, :we, :addr, :wdata, :be, :rdata]
    assert {:be, {:u, 4}, :fwd} in mp.fields
    assert Interface.flip(Interface.flip(mp)) == mp
    assert {:rdata, {:u, 32}, :fwd} in Interface.flip(mp).fields
  end

  test "master and slave ports have opposite directions" do
    axis = Interface.axi_stream(data: 8)

    m =
      module "dirs" do
        s = slave(:s_axis, axis)
        m = master(:m_axis, axis)
        connect(s, m)
      end

    dir = fn n -> Enum.find(m.ports, &(&1.name == n)).dir end
    assert dir.(:s_axis_tdata) == :input
    assert dir.(:s_axis_tready) == :output
    assert dir.(:m_axis_tdata) == :output
    assert dir.(:m_axis_tready) == :input
    assert [%{name: :s_axis, role: :slave}, %{name: :m_axis, role: :master}] = m.bundles
    assert m.comb_paths[:s_axis_tready] == [:m_axis_tready]
  end

  test "instance bundles connect in one call" do
    axis = Interface.axi_stream(data: 32)

    m =
      module "chain" do
        s = slave(:s_axis, axis)
        m = master(:m_axis, axis)
        a = instance(:a, Examples.skid_buffer(axis))
        b = instance(:b, Examples.skid_buffer(axis))
        connect(s, a.s_axis)
        connect(a.m_axis, b.s_axis)
        connect(b.m_axis, m)
      end

    sim = m |> Sim.new() |> Sim.reset()

    sim =
      Sim.poke(sim, %{
        s_axis_tvalid: 1,
        s_axis_tdata: 42,
        s_axis_tkeep: 15,
        s_axis_tlast: 1,
        m_axis_tready: 1
      })

    assert Sim.peek(sim, :m_axis_tvalid) == 0
    sim = sim |> Sim.step() |> Sim.poke(:s_axis_tvalid, 0) |> Sim.step()
    assert Sim.peek(sim, :m_axis_tvalid) == 1
    assert Sim.peek(sim, :m_axis_tdata) == 42
  end

  test "connect rejects different interfaces" do
    assert_raise ElaborationError, ~r/interfaces differ/, fn ->
      module "mismatch" do
        s = slave(:s_axis, Interface.axi_stream(data: 8))
        m = master(:m_axis, Interface.axi_stream(data: 16))
        connect(s, m)
      end
    end
  end

  test "custom interfaces" do
    i = Interface.new(:pair, [{:x, 8, :fwd}, {:ack, 1, :bwd}])

    m =
      module "custom" do
        s = slave(:in, i)
        w = bundle(:mid, i)
        o = master(:out, i)
        connect(s, w)
        connect(w, o)
      end

    assert Enum.map(m.ports, & &1.name) == [:in_x, :in_ack, :out_x, :out_ack]
    assert_raise ArgumentError, fn -> Interface.new(:bad, [{:x, 8, :sideways}]) end
  end
end
