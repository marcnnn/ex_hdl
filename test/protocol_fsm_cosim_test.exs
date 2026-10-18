defmodule ExHdl.ProtocolFsmCosimTest do
  @moduledoc """
  Generated AXI4-Stream parser + emitter (Verilator RTL) against the Elixir
  codec: valid packets must come out byte-identical, every invalid packet must
  be dropped and counted, under random tvalid gaps and random backpressure.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExHdl.Protocol.Spec
  alias ExHdl.Sim.Verilator
  alias ExHdl.Test.Gen
  alias ExHdl.Test.Protocols, as: P

  @moduletag :verilator
  @moduletag timeout: 300_000

  @packets [
    {:iq_frame, &P.encode_iq_frame/2},
    {:be_frame, &P.encode_be_frame/2}
  ]

  setup_all do
    sims =
      Map.new(@packets, fn {name, _} ->
        {:ok, sim} = Verilator.build_loopback(apply(P, name, []))
        {name, sim}
      end)

    %{sims: sims}
  end

  for {name, encode} <- @packets do
    @name name
    @encode encode

    property "#{name}: RTL loopback matches the Elixir codec under random backpressure", %{
      sims: sims
    } do
      spec = apply(P, @name, [])

      check all(
              cases <- list_of(Gen.packet_case(spec, @encode), min_length: 1, max_length: 20),
              valid_pct <- integer(10..100),
              ready_pct <- integer(10..100),
              seed <- integer(0..0xFFFF_FFFF),
              max_runs: 200
            ) do
        assert_loopback(sims[@name], cases,
          seed: seed,
          valid_pct: valid_pct,
          ready_pct: ready_pct
        )
      end
    end

    test "#{name}: 2000 packets in one stream", %{sims: sims} do
      spec = apply(P, @name, [])
      cases = Enum.take(Gen.packet_case(spec, @encode), 2000)
      assert_loopback(sims[@name], cases, seed: 1, valid_pct: 70, ready_pct: 60)
    end

    test "#{name}: no bubbles without backpressure", %{sims: sims} do
      spec = apply(P, @name, [])

      packets =
        spec
        |> Gen.packet_case(@encode)
        |> Stream.filter(&match?({:good, _}, &1))
        |> Enum.take(200)

      bytes = div(spec.bus_width, 8)

      {:ok, res} = Verilator.run_axis(sims[@name], Enum.map(packets, &elem(&1, 1)))

      # Parser and emitter each run at line rate; chained, the header is
      # consumed and then re-emitted, so a packet costs beats + header words.
      ideal =
        packets
        |> Enum.map(fn {:good, bin} ->
          div(byte_size(bin) + bytes - 1, bytes) + Spec.header_words(spec)
        end)
        |> Enum.sum()

      # 64 idle drain cycles plus pipeline fill.
      assert res.cycles <= ideal + 64 + 4
    end
  end

  defp assert_loopback(sim, cases, opts) do
    input = Enum.map(cases, &elem(&1, 1))
    expected = for {:good, bin} <- cases, do: bin
    bad = Enum.count(cases, &match?({:bad, _}, &1))

    assert {:ok, res} = Verilator.run_axis(sim, input, opts)
    assert res.packets == expected
    assert res.dropped == bad
  end
end
