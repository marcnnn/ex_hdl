# DVB-T receiver speed against real time (2k, QPSK 1/2, 9.14 Msamples/s).
#   MIX_ENV=test mix run scripts/dvbt_realtime.exs
# Uses the signal written by scripts/dvbt_compare.exs if present, otherwise
# generates one (4 superframes, unknown start, frequency offset, C/N 8.8 dB).
alias ExHdl.DVBT.{Channel, Convolutional, Fast, FastJit, Receiver, Sync, TestSignal, Transmitter}
alias ExHdl.SIMD.NIF
Nx.default_backend(EXLA.Backend)

file = Path.join(System.get_env("DVBT_WORK", "/tmp/dvbt_run"), "samples.c64")
x =
  if File.exists?(file) do
    Nx.from_binary(File.read!(file), :c64)
  else
    opts = [constellation: :qpsk, code_rate: {1, 2}, guard_interval: {1, 32}, cell_id: 0]
    TestSignal.ts_packets(1008) |> Transmitter.transmit(opts) |> Channel.delay(3333, 3) |> Channel.frequency_offset(1.37) |> Channel.awgn(8.0, 42)
  end
  |> Nx.backend_transfer(EXLA.Backend)

signal_ms = Nx.size(x) / 9142.857
time = fn label, f ->
  f.()
  us = for(_ <- 1..5, do: elem(:timer.tc(f), 0)) |> Enum.sort() |> Enum.at(2)
  IO.puts("#{String.pad_trailing(label, 34)} #{:erlang.float_to_binary(us / 1000, decimals: 1)} ms")
  f.()
end

IO.puts("signal: #{Float.round(signal_ms)} ms (#{Nx.size(x)} samples), medians of 5 runs")
{:ok, s} = time.("acquisition (once per stream)", fn -> Sync.acquire(x) end)
y = Nx.slice(x, [s.start], [Nx.size(x) - s.start])
bits = time.("front end (compiled defn)", fn -> FastJit.run(y, s.freq_offset, :qpsk) end)
rx = Convolutional.depunctured_binary(bits, {1, 2})
time.("Viterbi, scalar kernel", fn -> NIF.viterbi_dvbt(rx, true) end)
dec = time.("Viterbi, SIMD kernel", fn -> NIF.viterbi_dvbt_simd(rx, true) end)
bytes = Fast.pack(dec)
de = time.("Forney deinterleaver", fn -> NIF.forney_deinterleave(bytes) end)
payload = binary_part(de, 2244, div(byte_size(de) - 2244, 204) * 204)
time.("Reed-Solomon", fn -> NIF.rs_decode_packets(payload) end)

opts = [constellation: :qpsk, code_rate: {1, 2}, start: s.start, freq_offset: s.freq_offset]
Receiver.receive_fast(x, opts)
runs = for(_ <- 1..7, do: elem(:timer.tc(fn -> Receiver.receive_fast(x, opts) end), 0) / 1000) |> Enum.sort()
IO.puts("whole receiver (after acquisition): best #{Float.round(hd(runs), 1)} ms, median #{Float.round(Enum.at(runs, 3), 1)} ms -> #{Float.round(signal_ms / Enum.at(runs, 3), 2)}x real time (median)")
