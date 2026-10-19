# DVB-T full chain, fair comparison: ExHdl transmitter -> unknown start,
# carrier frequency offset, AWGN -> ExHdl receiver (own acquisition) and
# gr-dtv receiver (podman image exhdl-gnuradio-dtv) on the identical samples.
#   MIX_ENV=test mix run scripts/dvbt_compare.exs [snr_db ...]   (no args: noise-free)
# Environment: DVBT_CFO (subcarriers, default 1.37), DVBT_DELAY (samples, default 3333)
alias ExHdl.DVBT.{Channel, Receiver, TestSignal, Transmitter}
Nx.default_backend(EXLA.Backend)

opts = [constellation: :qpsk, code_rate: {1, 2}, guard_interval: {1, 32}, cell_id: 0]
packets = 1008
cfo = String.to_float(System.get_env("DVBT_CFO", "1.37"))
delay = String.to_integer(System.get_env("DVBT_DELAY", "3333"))
ts = TestSignal.ts_packets(packets)
src_packets = for <<p::binary-size(188) <- ts>>, do: p
work = System.get_env("DVBT_WORK", "/tmp/dvbt_run")
File.mkdir_p!(work)

clean = Transmitter.transmit(ts, opts) |> Channel.delay(delay, 3) |> Channel.frequency_offset(cfo)
IO.puts("signal: #{packets} packets, #{Nx.size(clean)} samples, start unknown (#{delay} samples of noise), CFO #{cfo} subcarriers (#{round(cfo * 4464)} Hz)")

# Packets are scored against the source with the most common offset among
# matching packets (packets repeat only every 768).
index = src_packets |> Enum.with_index() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
score = fn out ->
  outp = for <<p::binary-size(188) <- out>>, do: p
  offsets = for {p, i} <- Enum.with_index(outp), j <- Map.get(index, p, []), do: j - i
  case Enum.frequencies(offsets) |> Enum.max_by(&elem(&1, 1), fn -> nil end) do
    nil -> %{first: nil, packets: length(outp), correct: 0}
    {offset, _} ->
      correct = Enum.with_index(outp) |> Enum.count(fn {p, i} -> Enum.at(src_packets, i + offset) == p end)
      %{first: offset, packets: length(outp), correct: correct}
  end
end

pct = fn s -> if s.packets == 0, do: "0 packets", else: "#{s.correct}/#{s.packets} (#{Float.round(100 * s.correct / s.packets, 1)} %)" end

snrs = case System.argv() do
  [] -> [:clean]
  args -> Enum.map(args, &String.to_float/1)
end

for snr <- snrs do
  samples = if snr == :clean, do: clean, else: Channel.awgn(clean, snr, 42)
  File.write!(Path.join(work, "samples.c64"), samples |> Nx.as_type(:c64) |> Nx.to_binary())

  {t1, ours} = :timer.tc(fn -> Receiver.receive_sync(samples, opts) end)

  {log, status} =
    System.cmd("podman", ["run", "--rm", "-v", "#{work}:/w:Z", "-v", "#{File.cwd!()}/test/gnuradio:/g:ro,Z", "exhdl-gnuradio-dtv",
      "python3", "/g/dvbt_rx_timed.py", "/w/samples.c64", "/w/gr.ts"], stderr_to_stdout: true)

  gr_time = case Regex.run(~r/in ([0-9.]+) s/, log) do [_, s] -> s <> " s"; _ -> "?" end
  if status != 0, do: IO.puts(log)
  gr = File.read!(Path.join(work, "gr.ts"))

  label = if snr == :clean, do: "noise-free", else: "SNR #{snr} dB (C/N #{Float.round(snr + 10 * :math.log10(2048 / 1705), 1)} dB)"
  {so, sync} = case ours do
    {:error, reason} -> {%{first: nil, packets: 0, correct: 0}, "acquisition failed: #{inspect(reason)}"}
    out -> {score.(out.ts), "CFO est #{Float.round(out.sync.freq_offset, 3)}, RS corrected #{out.rs_corrected} bytes, failed #{out.rs_failed}"}
  end
  sg = score.(gr)
  IO.puts("#{label}:")
  IO.puts("  ExHdl : #{pct.(so)} from source packet #{inspect(so.first)}, #{sync}, #{Float.round(t1 / 1.0e6, 2)} s")
  IO.puts("  gr-dtv: #{pct.(sg)} from source packet #{inspect(sg.first)}, #{gr_time}")
end
