defmodule ExHdl.DVBT.GnuRadioTest do
  @moduledoc """
  ExHdl's DVB-T implementation against GNU Radio's gr-dtv (reference data
  from scripts/dvbt_golden.sh; 2k, QPSK, rate 1/2, GI 1/32, 6 superframes).

    * transmitter stages: bit-exact (SHA-256 over every stage's stream)
    * OFDM modulation and TPS: equal to float32 precision / exact signs
    * receiver back end: decodes gr-dtv's receiver input to the source TS,
      starting at the same packet as gr-dtv
    * receiver front end: equalised carriers vs the ideal constellation,
      hard decisions equal to gr-dtv's

  Run with `mix test --only dvbt` (tens of seconds).
  """
  use ExUnit.Case, async: true

  alias ExHdl.DVBT.{
    Convolutional,
    EnergyDispersal,
    Inner,
    OFDM,
    OuterInterleaver,
    Receiver,
    ReedSolomon,
    TestSignal,
    TPS
  }

  @moduletag :dvbt
  @moduletag timeout: 600_000

  @dir Path.expand("fixtures/dvbt/2k_qpsk_1_2", __DIR__)
  @manifest @dir |> Path.join("manifest.json") |> File.read!() |> JSON.decode!()
  @opts [constellation: :qpsk, code_rate: {1, 2}, guard_interval: {1, 32}, cell_id: 0]

  defp sha(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

  defp assert_stream(name, data) do
    s = @manifest["streams"][name]
    size = s["items"] * if(s["dtype"] == "complex64", do: 8, else: 1)

    assert byte_size(data) >= size,
           "#{name}: ExHdl produced #{byte_size(data)} bytes, gr-dtv #{size}"

    part = binary_part(data, 0, size)
    head = File.read!(Path.join(@dir, "#{name}.head"))

    unless sha(part) == s["sha256"] do
      diff = Enum.find(0..(byte_size(head) - 1), &(:binary.at(head, &1) != :binary.at(part, &1)))

      flunk(
        "#{name}: stream differs from gr-dtv (first difference in the stored head at byte #{inspect(diff)})"
      )
    end
  end

  defp c64(path),
    do: for(<<re::float-little-32, im::float-little-32 <- File.read!(path)>>, do: {re, im})

  setup_all do
    ts = TestSignal.ts_packets(@manifest["packets"])

    outer =
      ts
      |> EnergyDispersal.scramble()
      |> then(&for(<<p::binary-size(188) <- &1>>, into: <<>>, do: ReedSolomon.encode(p)))

    words =
      outer
      |> OuterInterleaver.interleave()
      |> then(&for(<<b::1 <- &1>>, do: b))
      |> Convolutional.encode({1, 2})
      |> Inner.group_bits(:qpsk)

    bit_interleaved = Inner.bit_interleave(words, :qpsk)
    h = Inner.symbol_permutation(:"2k")

    symbol_interleaved =
      bit_interleaved
      |> Enum.chunk_every(1512, 1512, :discard)
      |> Enum.with_index()
      |> Enum.flat_map(fn {s, k} -> Inner.symbol_interleave(s, h, rem(k, 68)) end)

    %{
      ts: ts,
      outer: outer,
      words: words,
      bit_interleaved: bit_interleaved,
      symbol_interleaved: symbol_interleaved
    }
  end

  describe "transmitter (bit-exact)" do
    test "energy dispersal, Reed-Solomon, outer interleaver", %{ts: ts, outer: outer} do
      assert_stream("tx_energy_dispersal", EnergyDispersal.scramble(ts))
      assert_stream("tx_reed_solomon", outer)
      assert_stream("tx_outer_interleaver", OuterInterleaver.interleave(outer))
    end

    test "inner coder, bit and symbol interleaver, mapper", ctx do
      assert_stream("tx_inner_coder", :binary.list_to_bin(ctx.words))
      assert_stream("tx_bit_interleaver", :binary.list_to_bin(ctx.bit_interleaved))
      assert_stream("tx_symbol_interleaver", :binary.list_to_bin(ctx.symbol_interleaved))

      n = @manifest["streams"]["tx_map"]["items"]

      mapped =
        for w <- Enum.take(ctx.symbol_interleaved, n), into: <<>> do
          {re, im} = Inner.map_symbol(w, :qpsk)
          <<re::float-little-32, im::float-little-32>>
        end

      assert_stream("tx_map", mapped)
    end

    test "TPS: DBPSK signs of all 17 TPS carriers over a superframe" do
      prbs = OFDM.prbs()

      {signs, _} =
        Enum.map_reduce(0..271, nil, fn j, state ->
          l = rem(j, 68)
          bits = TPS.bits(rem(div(j, 68), 4), @opts)

          state =
            if l == 0,
              do: Map.new(OFDM.tps_carriers(), &{&1, elem(prbs, &1)}),
              else: Map.new(state, fn {k, v} -> {k, Bitwise.bxor(v, Enum.at(bits, l))} end)

          {Enum.map_join(OFDM.tps_carriers(), &Integer.to_string(state[&1])), state}
        end)

      assert signs == @manifest["tps_signs_superframe1"]
    end

    test "OFDM modulation matches gr-dtv's samples to float32 precision", ctx do
      first = @manifest["rx_first_tx_symbol"]
      n = @manifest["window_symbols"]

      symbols =
        for j <- 0..(n - 1) do
          k = first + j
          words = Enum.slice(ctx.symbol_interleaved, k * 1512, 1512)
          {Enum.map(words, &Inner.map_symbol(&1, :qpsk)), rem(k, 68), rem(div(k, 68), 4)}
        end

      ours =
        OFDM.modulate(symbols, @opts)
        |> Nx.to_flat_list()
        |> Enum.map(&{Complex.real(&1), Complex.imag(&1)})

      gr = c64(Path.join(@dir, "window_tx_samples.c64"))
      assert snr_db(gr, ours) > 130
    end
  end

  describe "receiver" do
    test "back end: gr-dtv's receiver input decodes to the source TS, from the same packet as gr-dtv",
         ctx do
      first = @manifest["rx_first_tx_symbol"]

      rx_words =
        ctx.symbol_interleaved
        |> Enum.drop(first * 1512)
        |> Enum.take(@manifest["streams"]["rx_demap"]["items"])

      # proves that this is exactly what gr-dtv's receiver demapped
      assert sha(:binary.list_to_bin(rx_words)) == @manifest["streams"]["rx_demap"]["sha256"]

      out =
        Receiver.decode(Enum.take(rx_words, 340 * 1512), constellation: :qpsk, code_rate: {1, 2})

      assert :binary.list_to_bin(Enum.take(out.stages.symbol_deinterleaver, 4096)) ==
               File.read!(Path.join(@dir, "rx_symbol_deinterleaver.head"))

      assert :binary.list_to_bin(Enum.take(out.stages.bit_deinterleaver, 4096)) ==
               File.read!(Path.join(@dir, "rx_bit_deinterleaver.head"))

      start = @manifest["rx_ts_offset_in_tx"]
      assert {start, _} = :binary.match(ctx.ts, binary_part(out.ts, 0, 188 * 4))
      assert binary_part(ctx.ts, start, byte_size(out.ts)) == out.ts
      assert {out.rs_corrected, out.rs_failed} == {0, 0}
    end

    test "front end: equalised carriers at float precision, hard decisions equal to gr-dtv's" do
      first = @manifest["rx_first_tx_symbol"]
      n = @manifest["window_symbols"]

      samples =
        c64(Path.join(@dir, "window_tx_samples.c64"))
        |> Enum.map(fn {r, i} -> Complex.new(r, i) end)
        |> Nx.tensor(type: :c64)

      gr = c64(Path.join(@dir, "window_rx_equalised.c64")) |> Enum.chunk_every(1512)
      ours = OFDM.demodulate(samples, rem(first, 68))

      ideal = fn {a, b} ->
        s = 1 / :math.sqrt(2)
        {if(a > 0, do: s, else: -s), if(b > 0, do: s, else: -s)}
      end

      for {{data, _}, gr_data} <- Enum.zip(ours, gr) do
        # noise-free flat channel: the exact constellation point is known
        assert snr_db(Enum.map(data, ideal), data) > 130

        assert Enum.map(data, &Inner.demap_symbol(&1, :qpsk)) ==
                 Enum.map(gr_data, &Inner.demap_symbol(&1, :qpsk))
      end

      hard =
        ours
        |> Enum.flat_map(fn {d, _} -> Enum.map(d, &Inner.demap_symbol(&1, :qpsk)) end)
        |> Enum.take(4096)

      assert :binary.list_to_bin(hard) == File.read!(Path.join(@dir, "rx_demap.head"))
      assert length(ours) == n
    end
  end

  defp snr_db(ref, sig) do
    {p, e} =
      Enum.zip(ref, sig)
      |> Enum.reduce({0.0, 0.0}, fn {{a, b}, {c, d}}, {p, e} ->
        {p + a * a + b * b, e + (a - c) ** 2 + (b - d) ** 2}
      end)

    10 * :math.log10(p / max(e, 1.0e-30))
  end
end
