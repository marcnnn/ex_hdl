defmodule ExHdl.Regs.SimDriver do
  @moduledoc """
  AXI4-Lite master for the BEAM simulator (`ExHdl.RTL.Sim`), for testing
  a register slave or anything with an AXI4-Lite slave bundle.

      d = SimDriver.new(Sim.new(Mixer.Regs.rtl()), delays: 0..3, seed: 1)
      {:okay, d} = SimDriver.write(d, Mixer.Regs.offset(:ctrl), 0x5)
      {0x5, :okay, d} = SimDriver.read(d, Mixer.Regs.offset(:ctrl))
      Cosim.assert_equivalent(module, SimDriver.stimulus(d))

  Every simulated event goes through the driver, which records the input
  map it applied, so `stimulus/1` replays the same run in Verilator
  (`ExHdl.RTL.Cosim`). The driver follows the protocol: a valid stays
  high until its handshake, payload is stable meanwhile, and it checks
  that the slave keeps `bvalid`/`rvalid` high until accepted.

  Options of `new/2`: `prefix:` bundle prefix (default `:s_axil`),
  `delays:` range of random idle cycles before raising each valid and
  between `bvalid`/`rvalid` and the ready (default `0..0`), `seed:`,
  `timeout:` cycles per channel before raising (default 200), `reset:`.
  """

  alias ExHdl.RTL.Sim

  defstruct [:sim, :prefix, :delays, :timeout, :rand, trace: [], held: %{}]

  @type t :: %__MODULE__{}

  @doc """
  Wraps a simulator. The AXI inputs are driven idle from the first cycle,
  and the resets are asserted for `reset:` cycles (default 2, 0 to skip),
  recorded like every other cycle.
  """
  def new(%Sim{} = sim, opts \\ []) do
    d = %__MODULE__{
      sim: sim,
      prefix: Keyword.get(opts, :prefix, :s_axil),
      delays: Keyword.get(opts, :delays, 0..0),
      timeout: Keyword.get(opts, :timeout, 200),
      rand: :rand.seed_s(:exsss, {Keyword.get(opts, :seed, 1), 17, 42})
    }

    idle = for f <- ~w(awvalid wvalid bready arvalid rready)a, into: %{}, do: {port(d, f), 0}

    resets =
      for dom <- sim.module.domains, dom.reset && dom.reset_port, uniq: true do
        {hd(dom.reset.args), if(dom.reset_active == :low, do: 0, else: 1)}
      end

    case Keyword.get(opts, :reset, 2) do
      0 ->
        %{d | held: idle}

      n ->
        %{d | held: Map.merge(idle, Map.new(resets))}
        |> idle(n)
        |> poke(Enum.map(resets, fn {r, v} -> {r, 1 - v} end))
    end
  end

  @doc "The simulator."
  def sim(%__MODULE__{sim: s}), do: s

  @doc "One input map per simulated event, for `ExHdl.RTL.Cosim`."
  def stimulus(%__MODULE__{trace: t}), do: Enum.reverse(t)

  @doc "Sets other inputs (held for the following cycles)."
  def poke(%__MODULE__{} = d, inputs), do: %{d | held: Map.merge(d.held, Map.new(inputs))}

  @doc "Runs `n` idle cycles."
  def idle(%__MODULE__{} = d, n),
    do: Enum.reduce(1..n//1, d, fn _, d -> cycle(d, %{}) |> elem(1) end)

  @doc "Value of an output (or any signal) now."
  def peek(%__MODULE__{sim: s}, name), do: Sim.peek(s, name)

  @doc """
  Writes `data` to byte address `addr` with byte strobes `strb`. Returns
  `{resp, driver}`, `resp` one of `:okay`, `:exokay`, `:slverr`, `:decerr`.
  """
  def write(%__MODULE__{} = d, addr, data, strb \\ 0xF) do
    d = poke(d, %{port(d, :awaddr) => addr, port(d, :wdata) => data, port(d, :wstrb) => strb})
    {aw_wait, d} = delay(d)
    {w_wait, d} = delay(d)
    d = handshake(d, [{:awvalid, :awready, aw_wait}, {:wvalid, :wready, w_wait}])
    {b_wait, d} = delay(d)
    {d, _} = response(d, :bvalid, :bready, b_wait)
    resp = Sim.peek(d.sim, port(d, :bresp))
    {_, d} = cycle(d, %{port(d, :bready) => 1})
    {resp(resp), poke(d, %{port(d, :bready) => 0})}
  end

  @doc "Reads byte address `addr`. Returns `{data, resp, driver}`."
  def read(%__MODULE__{} = d, addr) do
    d = poke(d, %{port(d, :araddr) => addr})
    {ar_wait, d} = delay(d)
    d = handshake(d, [{:arvalid, :arready, ar_wait}])
    {r_wait, d} = delay(d)
    {d, _} = response(d, :rvalid, :rready, r_wait)
    data = Sim.peek(d.sim, port(d, :rdata))
    resp = Sim.peek(d.sim, port(d, :rresp))
    {_, d} = cycle(d, %{port(d, :rready) => 1})
    {data, resp(resp), poke(d, %{port(d, :rready) => 0})}
  end

  # Raises each valid after its wait, holds it until valid && ready at a
  # clock edge.
  defp handshake(d, chans), do: handshake(d, chans, 0)

  defp handshake(d, [], _n), do: d

  defp handshake(d, chans, n) do
    if n > d.timeout, do: raise("AXI4-Lite handshake timed out on #{inspect(chans)}")

    inputs =
      for {v, _r, wait} <- chans, into: %{}, do: {port(d, v), if(n >= wait, do: 1, else: 0)}

    {sampled, d} = cycle(d, inputs)

    left =
      Enum.reject(chans, fn {v, r, wait} ->
        n >= wait and sampled[port(d, r)] == 1 and inputs[port(d, v)] == 1
      end)

    d = poke(d, for({v, _, _} <- chans -- left, into: %{}, do: {port(d, v), 0}))
    handshake(d, left, n + 1)
  end

  # Waits for `valid`, keeps ready low for `wait` more cycles (checking
  # that valid stays high), then returns; the caller's next cycle raises
  # ready and completes the handshake.
  defp response(d, valid, ready, wait), do: response(d, valid, ready, wait, 0, false)

  defp response(d, valid, ready, wait, n, seen) do
    if n > d.timeout, do: raise("AXI4-Lite: no #{valid} after #{d.timeout} cycles")
    d = poke(d, %{port(d, ready) => 0})
    v = d.sim |> Sim.poke(d.held) |> Sim.peek(port(d, valid))

    cond do
      seen and v != 1 -> raise "AXI4-Lite: #{valid} dropped before #{ready}"
      v == 1 and wait == 0 -> {d, :ok}
      v == 1 -> d |> cycle(%{}) |> elem(1) |> response(valid, ready, wait - 1, n + 1, true)
      true -> d |> cycle(%{}) |> elem(1) |> response(valid, ready, wait, n + 1, false)
    end
  end

  # One event: apply held inputs plus `inputs`, sample outputs, step.
  defp cycle(d, inputs) do
    applied = Map.merge(d.held, inputs)
    sim = Sim.poke(d.sim, applied)
    sampled = Sim.outputs(sim)
    {sampled, %{d | sim: Sim.step(sim), trace: [applied | d.trace]}}
  end

  defp delay(%{delays: a..b//_} = d) do
    {x, r} = :rand.uniform_s(b - a + 1, d.rand)
    {a + x - 1, %{d | rand: r}}
  end

  defp port(d, f), do: :"#{d.prefix}_#{f}"

  defp resp(0), do: :okay
  defp resp(1), do: :exokay
  defp resp(2), do: :slverr
  defp resp(3), do: :decerr
end
