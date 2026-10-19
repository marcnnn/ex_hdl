defmodule ExHdl.DVBT.EndToEndTest do
  @moduledoc """
  DVB-T end to end (2k, QPSK, 1/2, GI 1/32): ExHdl's transmitter, a channel
  with unknown start, carrier frequency offset and AWGN, and ExHdl's
  receiver with its own acquisition. The live test runs gr-dtv's receiver
  on the identical samples (podman image exhdl-gnuradio-dtv).

  `mix test --only dvbt` / `mix test --only dvbt_live`.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ExHdl.DVBT.{Channel, Convolutional, Fast, Inner, OFDM, Receiver, TestSignal, Transmitter}

  @moduletag timeout: 900_000

  @opts [constellation: :qpsk, code_rate: {1, 2}, guard_interval: {1, 32}, cell_id: 0]
  @packets 1008
  @delay 3333
  @cfo 1.37

  setup_all do
    ts = TestSignal.ts_packets(@packets)
    clean = Transmitter.transmit(ts, @opts)
    # C/N 8.8 dB: comfortably above both receivers' threshold
    impaired =
      clean |> Channel.delay(@delay, 3) |> Channel.frequency_offset(@cfo) |> Channel.awgn(8.0, 42)

    %{ts: ts, clean: clean, impaired: impaired}
  end

  defp assert_source(ts, out_ts) do
    assert byte_size(out_ts) >= 188 * 600, "only #{div(byte_size(out_ts), 188)} packets"
    assert {start, _} = :binary.match(ts, binary_part(out_ts, 0, 188 * 4))
    assert binary_part(ts, start, byte_size(out_ts)) == out_ts
    start
  end

  @tag :dvbt
  test "fast path makes the same hard decisions as the reference front end", %{impaired: x} do
    {:ok, sync} = ExHdl.DVBT.Sync.acquire(x)
    symbols = Nx.slice(x, [sync.start], [68 * 2112])
    shifted = Channel.frequency_offset(symbols, -sync.freq_offset)

    reference =
      shifted
      |> OFDM.demodulate(0)
      |> Enum.flat_map(fn {d, _} -> Enum.map(d, &Inner.demap_symbol(&1, :qpsk)) end)

    fast =
      symbols
      |> Fast.carriers(68, sync.freq_offset)
      |> Fast.equalise(0)
      |> Fast.demap(:qpsk)
      |> Nx.to_flat_list()

    # the frequency correction starts at a different sample, which only
    # rotates all carriers by a constant phase; allow a handful of decisions
    # right at a boundary to flip
    differing = Enum.zip(reference, fast) |> Enum.count(fn {a, b} -> a != b end)
    assert differing <= 5, "#{differing} of #{length(fast)} decisions differ"
  end

  @tag :dvbt
  property "native Viterbi is bit-identical to the Elixir reference" do
    check all rate <- member_of([{1, 2}, {2, 3}, {3, 4}, {5, 6}, {7, 8}]),
              start <- member_of([:zero, :unknown]),
              bits <- list_of(integer(0..1), length: 600),
              flips <- list_of(integer(0..900), max_length: 30),
              max_runs: 40 do
      coded = Convolutional.encode(bits, rate)
      flips = MapSet.new(flips)

      noisy =
        coded |> Enum.with_index() |> Enum.map(fn {b, i} -> if i in flips, do: 1 - b, else: b end)

      assert Convolutional.decode(noisy, rate, start: start) ==
               Convolutional.decode_reference(noisy, rate, start: start)
    end
  end

  @tag :dvbt
  property "SIMD Viterbi is bit-identical to the scalar kernel and the Elixir reference" do
    check all rate <- member_of([{1, 2}, {2, 3}, {3, 4}, {5, 6}, {7, 8}]),
              start <- member_of([:zero, :unknown]),
              len <- integer(1..1500),
              seed <- integer(1..10_000),
              max_runs: 40 do
      :rand.seed(:exsss, {seed, 2, 3})
      bits = for _ <- 1..len, do: :rand.uniform(2) - 1
      # a few percent bit errors; partial puncturing periods at the end
      noisy =
        bits
        |> Convolutional.encode(rate)
        |> Enum.map(fn b -> if :rand.uniform() < 0.04, do: 1 - b, else: b end)

      rx = noisy |> :binary.list_to_bin() |> Convolutional.depunctured_binary(rate)
      unknown = start == :unknown

      simd = ExHdl.SIMD.NIF.viterbi_dvbt_simd(rx, unknown)
      assert simd == ExHdl.SIMD.NIF.viterbi_dvbt(rx, unknown)

      assert :binary.bin_to_list(simd) ==
               Convolutional.decode_reference(noisy, rate, start: start)
    end
  end

  @tag :dvbt
  test "native RS decoder equals the Elixir reference on DVB codewords" do
    alias ExHdl.DVBT.ReedSolomon
    :rand.seed(:exsss, {5, 6, 7})

    # 0..12 byte errors per codeword: corrected, and failed ones
    codewords =
      for _ <- 1..200 do
        cw = ReedSolomon.encode(:crypto.strong_rand_bytes(188))

        Enum.reduce(Enum.take_random(0..203, :rand.uniform(13) - 1), cw, fn p, acc ->
          <<a::binary-size(p), b, c::binary>> = acc
          <<a::binary, Bitwise.bxor(b, :rand.uniform(255)), c::binary>>
        end)
      end

    {ref, corrected, failed} =
      Enum.reduce(codewords, {[], 0, 0}, fn cw, {o, c, f} ->
        case ReedSolomon.decode(cw) do
          {:ok, p, n} -> {[p | o], c + n, f}
          {:error, _, p} -> {[p | o], c, f + 1}
        end
      end)

    assert failed > 0 and corrected > 0

    assert ReedSolomon.decode_all(IO.iodata_to_binary(codewords)) ==
             {ref |> Enum.reverse() |> IO.iodata_to_binary(), corrected, failed}
  end

  @tag :dvbt
  test "noise-free: receiver decodes the source TS from the first superframe", %{
    ts: ts,
    clean: clean
  } do
    out = Receiver.receive_sync(clean, @opts)
    assert out.sync.start == 0
    assert assert_source(ts, out.ts) == 0
    assert {out.rs_corrected, out.rs_failed} == {0, 0}
  end

  @tag :dvbt
  test "unknown start, frequency offset, AWGN (C/N 8.8 dB): acquisition and error-free TS", %{
    ts: ts,
    impaired: x
  } do
    out = Receiver.receive_sync(x, @opts)
    assert out.sync.start == @delay
    assert_in_delta out.sync.freq_offset, @cfo, 0.01
    assert out.sync.scattered_phase_ok
    assert_source(ts, out.ts)
    assert out.rs_failed == 0
  end

  @tag :dvbt_live
  test "gr-dtv decodes the identical impaired signal to the same source TS", %{
    ts: ts,
    impaired: x
  } do
    dir = Path.join(System.tmp_dir!(), "exhdl_dvbt_live_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "samples.c64"), x |> Nx.as_type(:c64) |> Nx.to_binary())
    gr_dir = Path.expand("gnuradio", __DIR__)

    {log, status} =
      System.cmd(
        "podman",
        [
          "run",
          "--rm",
          "-v",
          "#{dir}:/w:Z",
          "-v",
          "#{gr_dir}:/g:ro,Z",
          "exhdl-gnuradio-dtv",
          "python3",
          "/g/dvbt_rx.py",
          "/w/samples.c64",
          "/w/gr.ts"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, log
    gr = File.read!(Path.join(dir, "gr.ts"))
    File.rm_rf!(dir)

    ours = Receiver.receive_sync(x, @opts)
    gr_start = assert_source(ts, gr)
    our_start = assert_source(ts, ours.ts)
    # ExHdl starts at the first complete superframe; gr-dtv locks during it
    assert our_start <= gr_start
  end
end
