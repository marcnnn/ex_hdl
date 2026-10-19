# DVB-T full chain: ExHdl transmitter -> AWGN -> ExHdl receiver and gr-dtv
# receiver (podman image exhdl-gnuradio-dtv) on the identical samples.
#   MIX_ENV=test mix run scripts/dvbt_compare.exs [snr_db ...]   (default: none = noise-free)
alias ExHdl.DVBT.{Channel, Receiver, TestSignal, Transmitter}
Nx.default_backend(EXLA.Backend)

opts = [constellation: :qpsk, code_rate: {1, 2}, guard_interval: {1, 32}, cell_id: 0]
packets = 1008
ts = TestSignal.ts_packets(packets)
src_packets = for <<p::binary-size(188) <- ts>>, do: p
work = System.get_env("DVBT_WORK", "/tmp/dvbt_run")
File.mkdir_p!(work)

{t, clean} = :timer.tc(fn -> Transmitter.transmit(ts, opts) end)
IO.puts("ExHdl TX: #{packets} packets -> #{Nx.size(clean)} samples in #{div(t, 1000)} ms")

# Packet-level scoring: the alignment between output and source packets is
# the most common offset among packets that match some source packet
# (packets repeat only every 768), so broken early packets do not hide
# correct later ones. Also reports correct packets per 252 (one superframe).
index = src_packets |> Enum.with_index() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
score = fn out ->
  outp = for <<p::binary-size(188) <- out>>, do: p
  offsets = for {p, i} <- Enum.with_index(outp), j <- Map.get(index, p, []), do: j - i
  case Enum.frequencies(offsets) |> Enum.max_by(&elem(&1, 1), fn -> nil end) do
    nil -> %{first: nil, packets: length(outp), correct: 0, per_superframe: []}
    {offset, _} ->
      ok = for {p, i} <- Enum.with_index(outp), do: Enum.at(src_packets, i + offset) == p
      per = ok |> Enum.chunk_every(252) |> Enum.map(&Enum.count(&1, fn x -> x end))
      %{first: offset, packets: length(outp), correct: Enum.count(ok, & &1), per_superframe: per}
  end
end

snrs = case System.argv() do
  [] -> [:clean]
  args -> Enum.map(args, &String.to_float/1)
end

for snr <- snrs do
  samples = if snr == :clean, do: clean, else: Channel.awgn(clean, snr, 42)
  file = Path.join(work, "samples.c64")
  File.write!(file, samples |> Nx.as_type(:c64) |> Nx.to_binary())

  {t1, ours} = :timer.tc(fn -> Receiver.receive(Nx.backend_copy(samples, Nx.BinaryBackend), opts) end)
  {t2, {log, status}} = :timer.tc(fn ->
    System.cmd("podman", ["run", "--rm", "-v", "#{work}:/w:Z", "-v", "#{File.cwd!()}/test/gnuradio:/g:ro,Z", "exhdl-gnuradio-dtv",
      "python3", "/g/dvbt_rx.py", "/w/samples.c64", "/w/gr.ts"], stderr_to_stdout: true)
  end)
  if status != 0, do: IO.puts(log)
  gr = File.read!(Path.join(work, "gr.ts"))

  label = if snr == :clean, do: "noise-free", else: "SNR #{snr} dB (C/N #{Float.round(snr + 10 * :math.log10(2048 / 1705), 1)} dB)"
  so = score.(ours.ts)
  sg = score.(gr)
  IO.puts("#{label}:")
  IO.puts("  ExHdl : #{so.correct}/#{so.packets} packets correct #{inspect(so.per_superframe)} from source packet #{inspect(so.first)}, RS corrected #{ours.rs_corrected} bytes, failed #{ours.rs_failed} (#{div(t1, 1000)} ms)")
  IO.puts("  gr-dtv: #{sg.correct}/#{sg.packets} packets correct #{inspect(sg.per_superframe)} from source packet #{inspect(sg.first)} (#{div(t2, 1000)} ms incl. container start)")
end
