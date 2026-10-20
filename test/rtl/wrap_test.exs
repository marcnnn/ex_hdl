defmodule ExHdl.RTL.WrapTest do
  use ExUnit.Case, async: true
  use ExHdl.RTL
  import Bitwise

  alias ExHdl.RTL.{Cosim, ElaborationError, Examples, Sim, Wrap}
  alias ExHdl.Test.DSP, as: K
  alias ExHdl.Test.Protocols, as: P

  test "protocol blocks become black boxes with bundles and their SV attached" do
    parser = Wrap.protocol(P.iq_frame(), :parser)
    assert parser.kind == :black_box
    assert parser.name == "iq_frame_parser"

    assert Map.keys(parser.sources) |> Enum.sort() ==
             ~w(iq_frame_emitter.sv iq_frame_loopback.sv iq_frame_parser.sv)

    assert Enum.map(parser.bundles, & &1.name) == [:s_axis, :m_axis]
    assert %{type: {:s, 16}, dir: :output} = Enum.find(parser.ports, &(&1.name == :meta_gain_q15))

    emitter = Wrap.protocol(P.iq_frame(), :emitter)
    assert Enum.find(emitter.ports, &(&1.name == :meta_seq_num)).dir == :input
    refute Enum.find(emitter.ports, &(&1.name == :meta_magic))
  end

  test "layer chains: match tables, counts and tuser" do
    spec = ExHdl.Test.NetProtocols.udp64()
    parser = Wrap.protocol(spec, :parser)
    port = fn mod, name -> Enum.find(mod.ports, &(&1.name == name)) end

    assert %{type: {:u, 64}, dir: :input} = port.(parser, :match_udp_dst_port)
    assert %{type: {:u, 4}, dir: :input} = port.(parser, :match_udp_dst_port_en)
    assert %{type: {:u, 2}, dir: :output} = port.(parser, :meta_vlan_count)
    assert %{type: {:u, 320}, dir: :output} = port.(parser, :meta_ipv4_options)
    assert %{dir: :output} = port.(parser, :meta_payload_bytes)
    assert Enum.any?(hd(tl(parser.bundles)).iface.fields, &(elem(&1, 0) == :tuser))

    emitter = Wrap.protocol(spec, :emitter)
    assert port.(emitter, :meta_vlan1_vid)
    refute port.(emitter, :meta_ipv4_checksum)
    refute port.(emitter, :meta_ipv4_total_length)
    assert %{dir: :input} = port.(emitter, :meta_udp_checksum)
    assert %{dir: :input} = port.(emitter, :payload_bytes)
  end

  test "without a model the BEAM simulator refuses the black box" do
    top = rom_top(P.be_frame(), [<<0>>])

    assert_raise ElaborationError,
                 ~r/black box be_frame_loopback \(lb\) has no simulation model/,
                 fn -> Sim.new(top) end
  end

  # A ROM of AXI4-Stream beats feeding the wrapped loopback, closed-loop on
  # tready, then a skid buffer: packets in, packets out.
  defp rom_top(spec, packets) do
    bytes = div(spec.bus_width, 8)

    beats =
      for p <- packets, {chunk, keep, last} <- chunks(p, bytes) do
        chunk ||| keep <<< spec.bus_width ||| last <<< (spec.bus_width + bytes)
      end

    n = length(beats)
    iw = ExHdl.RTL.Builder.ceil_log2(n + 1)
    axis = Interface.axi_stream(data: spec.bus_width)

    module "rom_#{spec.name}" do
      m = master(:m_axis, axis)
      dropped = output(:dropped, 32)

      rom =
        memory(:rom,
          width: spec.bus_width + bytes + 1,
          depth: max(1 <<< iw, 2),
          init: beats,
          style: :distributed
        )

      idx = reg(:idx, iw)
      word = read_port(rom, kind: :async, addr: idx)
      lb = instance(:lb, Wrap.protocol(spec, :loopback))
      sk = instance(:sk, Examples.skid_buffer(axis))
      src = lb.s_axis
      src.tdata <~ word[0..(spec.bus_width - 1)]
      src.tkeep <~ word[spec.bus_width..(spec.bus_width + bytes - 1)]
      src.tlast <~ word[spec.bus_width + bytes]
      src.tvalid <~ (idx < n)

      sync do
        if src.tvalid and src.tready, do: idx <~ add_wrap(idx, 1)
      end

      connect(lb.m_axis, sk.s_axis)
      connect(sk.m_axis, m)
      dropped <~ lb.dropped_packets
    end
  end

  defp chunks(packet, bytes) do
    pad = rem(bytes - rem(byte_size(packet), bytes), bytes)
    words = for <<c::binary-size(bytes) <- packet <> :binary.copy(<<0>>, pad)>>, do: c
    last_len = rem(byte_size(packet) - 1, bytes) + 1
    n = length(words)

    words
    |> Enum.with_index(1)
    |> Enum.map(fn {w, i} ->
      keep = if i == n, do: (1 <<< last_len) - 1, else: (1 <<< bytes) - 1
      {:binary.decode_unsigned(w, :little), keep, if(i == n, do: 1, else: 0)}
    end)
  end

  @tag :verilator
  @tag timeout: 300_000
  test "the wrapped protocol loopback runs inside an RTL design in Verilator" do
    spec = P.be_frame()
    h = %{tclass: 1, flow: 0xABCDE, len: 5, next: 17, hops: -3}

    good = [
      P.encode_be_frame(h, [1, 2, 3, 4, 5]),
      P.encode_be_frame(%{h | len: 9}, Enum.to_list(1..20))
    ]

    bad = <<0x10, 0, 0, 0, 0, 0, 0, 0, 9, 9>>
    top = rom_top(spec, [hd(good), bad, List.last(good)])

    {:ok, c} = Cosim.build(top)

    stim =
      [%{rst_n: 0}, %{rst_n: 0}] ++
        for(i <- 1..120, do: %{rst_n: 1, m_axis_tready: if(rem(i, 3) == 0, do: 0, else: 1)})

    {:ok, out} = Cosim.run(c, stim)

    beats =
      for {o, s} <- Enum.zip(out, stim),
          o.m_axis_tvalid == 1,
          s[:m_axis_tready] == 1,
          do: {o.m_axis_tdata, o.m_axis_tkeep, o.m_axis_tlast}

    assert beats == Enum.flat_map(good, &chunks(&1, 8))
    assert List.last(out).dropped == 1
  end

  test "stream kernels become black boxes with static parameter ports" do
    t = Nx.template({}, :s16)

    {:ok, d} =
      ExHdl.DSP.scan_to_sv(&K.one_pole_step/3, [t, t, t],
        state: 1,
        ii: :auto,
        name: "op_k",
        param_names: ["a"]
      )

    bb = Wrap.scan(d)

    assert %{dir: :input, domain: :static, type: {:u, 16}} =
             Enum.find(bb.ports, &(&1.name == :p_a))

    assert Map.keys(bb.sources) == ["op_k.sv"]
  end

  @tag :verilator
  test "a wrapped stream kernel lints inside an RTL design" do
    t = Nx.template({}, :s16)

    {:ok, d} =
      ExHdl.DSP.scan_to_sv(&K.one_pole_step/3, [t, t, t],
        state: 1,
        ii: :auto,
        name: "op_k",
        param_names: ["a"]
      )

    axis = Interface.axi_stream(data: d.in_width, keep: false, last: false)
    out = Interface.axi_stream(data: d.out_width, keep: false, last: false)

    top =
      module "op_top" do
        a = input(:a, 16, domain: :static)
        s = slave(:s_axis, axis)
        m = master(:m_axis, out)
        load = input(:load, 1)
        k = instance(:k, Wrap.scan(d), connect: [p_a: a, p_load: load])
        connect(s, k.s_axis)
        connect(k.m_axis, m)
      end

    dir = Path.join(System.tmp_dir!(), "ex_hdl_wrap_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    files =
      for {f, src} <- ExHdl.Backends.SystemVerilog.RTL.generate(top) do
        File.write!(Path.join(dir, f), src)
        Path.join(dir, f)
      end

    {log, status} =
      System.cmd("verilator", ["--lint-only", "-Wall", "--top-module", "op_top" | files],
        stderr_to_stdout: true
      )

    File.rm_rf!(dir)
    assert status == 0, log
  end
end
