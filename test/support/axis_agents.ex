defmodule ExHdl.Test.AxisSource do
  @moduledoc false
  # AXI4-Stream source for ExHdl.RTL.Bench: beats `{data, last}` (or data), offered with
  # probability p per cycle and held until taken. `prefix` names the port bundle.
  @behaviour ExHdl.RTL.Bench.Agent
  defstruct beats: [], p: 1.0, offer: false, sent: 0, prefix: "s_axis", user: nil

  def new(beats, opts \\ []), do: struct!(__MODULE__, [beats: beats] ++ opts)

  def drive(%{beats: [b | _]} = s, _cycle) do
    offer = s.offer or :rand.uniform() < s.p
    {data, last} = beat(b)

    ins =
      %{
        port(s, :tvalid) => if(offer, do: 1, else: 0),
        port(s, :tdata) => data,
        port(s, :tlast) => last
      }

    {ins, %{s | offer: offer}}
  end

  def drive(s, _cycle), do: {%{port(s, :tvalid) => 0}, %{s | offer: false}}

  def sample(%{offer: true, beats: [_ | rest]} = s, outs, _c) do
    if outs[port(s, :tready)] == 1,
      do: %{s | beats: rest, offer: false, sent: s.sent + 1},
      else: s
  end

  def sample(s, _outs, _c), do: s

  def done?(s), do: s.beats == []

  defp beat({_, _} = b), do: b
  defp beat(d), do: {d, 0}
  defp port(s, f), do: :"#{s.prefix}_#{f}"
end

defmodule ExHdl.Test.AxisSink do
  @moduledoc false
  # AXI4-Stream sink with random tready; collects `{tdata, tlast}` newest first.
  @behaviour ExHdl.RTL.Bench.Agent
  defstruct got: [], p: 1.0, ready: 0, prefix: "m_axis"

  def new(opts \\ []), do: struct!(__MODULE__, opts)

  def drive(s, _cycle) do
    r = if :rand.uniform() < s.p, do: 1, else: 0
    {%{:"#{s.prefix}_tready" => r}, %{s | ready: r}}
  end

  def sample(%{ready: 1} = s, outs, _c) do
    if outs[:"#{s.prefix}_tvalid"] == 1,
      do: %{s | got: [{outs[:"#{s.prefix}_tdata"], outs[:"#{s.prefix}_tlast"]} | s.got]},
      else: s
  end

  def sample(s, _outs, _c), do: s

  def count(s), do: length(s.got)
  def items(s), do: s.got |> Enum.reverse()
end

defmodule ExHdl.Test.Pulse do
  @moduledoc false
  # drives `port` high in cycle `at` only
  @behaviour ExHdl.RTL.Bench.Agent
  defstruct [:port, at: 3]
  def drive(s, cycle), do: {%{s.port => if(cycle == s.at, do: 1, else: 0)}, s}
  def sample(s, _outs, _c), do: s
end

defmodule ExHdl.Test.SoftFFT do
  @moduledoc false
  # Stands in for the FFT of a front end built with `fft: nil`: takes the
  # symbols the design sends to `fft_in`, transforms them with the software
  # FFT of FixedFrontEnd (`ExHdl.Test.OFDMRef.fft/2`), and offers the bins on
  # `fft_out`, random valid and ready.
  @behaviour ExHdl.RTL.Bench.Agent
  import Bitwise

  defstruct fft: 2048, p: 1.0, q: 1.0, collect: [], out: [], offer: false, ready: 0, symbols: 0

  def new(opts \\ []), do: struct!(__MODULE__, opts)

  def drive(s, _cycle) do
    ready = if :rand.uniform() < s.q, do: 1, else: 0
    offer = s.out != [] and (s.offer or :rand.uniform() < s.p)
    {data, last} = if s.out == [], do: {0, 0}, else: hd(s.out)

    ins = %{
      fft_in_tready: ready,
      fft_out_tvalid: if(offer, do: 1, else: 0),
      fft_out_tdata: data,
      fft_out_tlast: last
    }

    {ins, %{s | ready: ready, offer: offer}}
  end

  def sample(s, outs, _c) do
    s =
      if s.offer and outs[:fft_out_tready] == 1,
        do: %{s | out: tl(s.out), offer: false},
        else: s

    if s.ready == 1 and outs[:fft_in_tvalid] == 1 do
      beat = outs[:fft_in_tdata]
      collect = [beat | s.collect]

      if length(collect) == s.fft do
        1 = outs[:fft_in_tlast]

        %{
          s
          | collect: [],
            out: s.out ++ transform(Enum.reverse(collect), s.fft),
            symbols: s.symbols + 1
        }
      else
        %{s | collect: collect}
      end
    else
      s
    end
  end

  defp signed(x), do: if(x >= 0x8000, do: x - 0x10000, else: x)

  defp transform(beats, n) do
    f = NxFixed.Num.q(16, 12)
    col = fn fun -> %NxFixed.Fixed{t: Nx.tensor([Enum.map(beats, fun)], type: :s16), frac: 12} end
    x = {col.(&signed(&1 &&& 0xFFFF)), col.(&signed(&1 >>> 16 &&& 0xFFFF))}
    _ = f
    {re, im} = ExHdl.Test.OFDMRef.fft(x)

    Enum.zip(Nx.to_flat_list(re.t), Nx.to_flat_list(im.t))
    |> Enum.with_index()
    |> Enum.map(fn {{r, i}, k} ->
      {(i &&& 0xFFFF) <<< 16 ||| (r &&& 0xFFFF), if(k == n - 1, do: 1, else: 0)}
    end)
  end
end
