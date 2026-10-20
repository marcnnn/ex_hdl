defmodule ExHdl.RTL.Cosim.Mismatch do
  @moduledoc """
  First difference between an RTL module and its reference model
  (`ExHdl.RTL.Cosim.check_model/4`, `ExHdl.RTL.Cosim.check_trace/4`).

    * `module`, `backend` (`:beam` or `:verilator`)
    * `cycle` - the RTL event index; the model step is `cycle - latency`
    * `diffs` - `[{port, expected, actual}]` of every differing output at
      that event
    * `history` - `[{cycle, inputs, [{port, expected, actual}]}]` for the
      last cycles up to and including `cycle`

  `message/1` formats it for a test failure.
  """

  defstruct [:module, :backend, :cycle, :latency, :diffs, :history]

  @type t :: %__MODULE__{}

  @doc false
  def new(module, backend, cycle, latency, diffs, history),
    do: %__MODULE__{
      module: module,
      backend: backend,
      cycle: cycle,
      latency: latency,
      diffs: diffs,
      history: history
    }

  @doc "Human-readable report."
  @spec message(t()) :: String.t()
  def message(%__MODULE__{} = m) do
    step =
      if m.latency == 0,
        do: "",
        else: " (model step #{m.cycle - m.latency}, latency #{m.latency})"

    diffs =
      Enum.map(m.diffs, fn {p, e, a} -> "  #{p}: expected #{num(e)}, actual #{num(a)}\n" end)

    hist =
      Enum.map(m.history, fn {k, ins, outs} ->
        marker = if k == m.cycle, do: ">", else: " "
        ins = Enum.map_join(Enum.sort(ins), " ", fn {p, v} -> "#{p}=#{num(v)}" end)

        outs =
          Enum.map_join(outs, " ", fn
            {p, e, a} when e == a -> "#{p}=#{num(a)}"
            {p, e, a} -> "#{p}=#{num(a)} (expected #{num(e)})"
          end)

        outs = if outs == "", do: "", else: " | " <> outs
        "#{marker} #{String.pad_leading(Integer.to_string(k), 6)}: #{ins}#{outs}\n"
      end)

    IO.iodata_to_binary([
      "#{m.module} (#{m.backend}) differs from the model at cycle #{m.cycle}#{step}:\n",
      diffs,
      "last #{length(m.history)} cycle(s), inputs | compared outputs:\n",
      hist
    ])
  end

  defp num(nil), do: "nil"
  defp num(v) when is_integer(v) and v >= 0 and v < 10, do: Integer.to_string(v)
  defp num(v) when is_integer(v) and v < 0, do: "#{v}"
  defp num(v) when is_integer(v), do: "#{v} (0x#{Integer.to_string(v, 16)})"
  defp num(v), do: inspect(v)
end
