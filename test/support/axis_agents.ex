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
