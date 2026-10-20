defmodule ExHdl.ProtocolChainCosimTest do
  @moduledoc """
  Layer chains (Ethernet, VLAN stack, IPv4 with options, UDP) through the
  generated parser -> emitter loopback in Verilator: good packets come out
  canonical (padding removed, computed fields recomputed), packets with
  header errors are dropped and counted, truncated packets and bad UDP
  checksums are forwarded with tuser set, on 8, 32 and 64-bit buses under
  random tvalid gaps and backpressure.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExHdl.Protocol.{Codec, Layout}
  alias ExHdl.Sim.Verilator
  alias ExHdl.Test.ChainGen
  alias ExHdl.Test.NetProtocols, as: N

  @moduletag :verilator
  @moduletag timeout: 600_000

  @tables %{{:udp, :dst_port} => [5004, 319]}
  @packets [:udp8, :udp32, :udp64, :eth_iq]

  setup_all do
    sims =
      @packets
      |> Task.async_stream(
        fn name ->
          spec = apply(N, name, [])
          {:ok, sim} = Verilator.build_loopback(spec, match: @tables)
          {:ok, rx} = Verilator.build_loopback(spec, match: @tables, top: :rx)
          {name, %{loopback: sim, rx: rx}}
        end,
        timeout: :infinity
      )
      |> Map.new(fn {:ok, r} -> r end)

    %{sims: sims}
  end

  for name <- @packets do
    @name name

    property "#{name}: RTL loopback matches the Elixir codec under random backpressure", %{
      sims: sims
    } do
      spec = apply(N, @name, [])

      check all(
              cases <-
                list_of(ChainGen.loopback_case(spec, @tables), min_length: 1, max_length: 16),
              valid_pct <- integer(10..100),
              ready_pct <- integer(10..100),
              seed <- integer(0..0xFFFF_FFFF),
              max_runs: 100
            ) do
        opts = [seed: seed, valid_pct: valid_pct, ready_pct: ready_pct]
        assert_loopback(sims[@name].loopback, cases, opts)
        assert_rx(spec, sims[@name].rx, cases, opts)
      end
    end

    test "#{name}: 1500 packets in one stream", %{sims: sims} do
      spec = apply(N, @name, [])
      cases = Enum.take(ChainGen.loopback_case(spec, @tables), 1500)
      assert_loopback(sims[@name].loopback, cases, seed: 7, valid_pct: 80, ready_pct: 70)
      assert_rx(spec, sims[@name].rx, cases, seed: 8, valid_pct: 90, ready_pct: 80)
    end

    test "#{name}: line rate without backpressure", %{sims: sims} do
      spec = apply(N, @name, [])
      bytes = div(spec.bus_width, 8)

      packets =
        spec
        |> ChainGen.loopback_case(@tables)
        |> Stream.filter(&match?({:good, {:good, _, _}}, &1))
        |> Enum.take(200)
        |> Enum.map(fn {_, {:good, bin, _}} -> bin end)

      {:ok, res} = Verilator.run_axis(sims[@name].loopback, packets)

      # Per packet: the input beats, plus the emitter's header beats (the
      # parser is stalled while they go out) and at most one flush beat.
      max_header = spec |> Layout.paths() |> Layout.max_header_bytes()

      bound =
        packets
        |> Enum.map(&(div(byte_size(&1) + bytes - 1, bytes) + div(max_header, bytes) + 2))
        |> Enum.sum()

      assert res.cycles <= bound + 64 + 4
      assert length(res.packets) == 200

      # The parser alone takes one beat per cycle, flush beats included.
      {:ok, rx} = Verilator.run_axis(sims[@name].rx, packets)
      beats = packets |> Enum.map(&div(byte_size(&1) + bytes - 1, bytes)) |> Enum.sum()
      assert rx.cycles <= beats + 64 + 2
      assert length(rx.packets) == 200
    end
  end

  test "hand-made packets: VLAN stack too deep, unknown EtherType, IHL below 5", %{sims: sims} do
    h = %{
      eth: %{dst: 1, src: 2},
      vlan: [%{pcp: 0, dei: false, vid: 1}, %{pcp: 7, dei: true, vid: 2}],
      ipv4: %{
        dscp: 0,
        ecn: 0,
        id: 1,
        reserved: 0,
        df: false,
        mf: false,
        frag_offset: 0,
        ttl: 1,
        src: 3,
        dst: 4
      },
      udp: %{src_port: 1, dst_port: 319}
    }

    for name <- [:udp8, :udp32, :udp64] do
      good = apply(N, :"encode_#{name}", [h, "payload"])
      <<pre::binary-size(20), post::binary>> = good
      three_tags = pre <> <<0x81, 0x00, 0x00, 0x03>> <> post
      ipv6 = ChainGen.put_bits(good, 20 * 8, 16, 0x86DD)
      short_ihl = ChainGen.put_bits(good, 22 * 8 + 4, 4, 4)

      for bad <- [three_tags, ipv6, short_ihl],
          do: assert({:error, _} = apply(N, :"decode_#{name}", [bad]))

      input = [good, three_tags, good, ipv6, short_ihl, good]
      {:ok, res} = Verilator.run_axis(sims[name].rx, input, valid_pct: 70, ready_pct: 50)
      assert res.packets == ["payload", "payload", "payload"]
      assert res.dropped == 3
    end
  end

  # The parser alone: payloads (trimmed, realigned), tuser flags, drops.
  defp assert_rx(spec, sim, cases, opts) do
    input = Enum.map(cases, fn {_, c} -> elem(c, 1) end)

    expected =
      for {_, c} <- cases, elem(c, 0) != :drop do
        {:ok, _, payload} = Codec.decode_header(spec, elem(c, 2))
        {payload, elem(c, 0) == :flag}
      end

    dropped = Enum.count(cases, fn {_, c} -> elem(c, 0) == :drop end)

    assert {:ok, res} = Verilator.run_axis(sim, input, opts)
    assert Enum.zip(res.packets, res.flags) == expected
    assert res.dropped == dropped
  end

  defp assert_loopback(sim, cases, opts) do
    input = Enum.map(cases, fn {_, c} -> elem(c, 1) end)

    expected =
      for {_, c} <- cases, elem(c, 0) != :drop, do: {elem(c, 2), elem(c, 0) == :flag}

    dropped = Enum.count(cases, fn {_, c} -> elem(c, 0) == :drop end)

    assert {:ok, res} = Verilator.run_axis(sim, input, opts)
    assert Enum.zip(res.packets, res.flags) == expected
    assert res.dropped == dropped
  end
end
