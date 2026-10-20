defmodule ExHdl.RTL.Examples do
  @moduledoc """
  Worked `ExHdl.RTL` examples, each tested in the BEAM simulator and
  against Verilator.

    * `counter/1` - enable counter.
    * `crc32/0` - Ethernet CRC-32 over one byte per cycle, the XOR network
      computed at elaboration time; matches `:erlang.crc32/1`.
    * `skid_buffer/1` - AXI4-Stream register slice: registered outputs,
      full throughput, any stream interface.
    * `pulse_counter/0` - two clock domains: pulses from `:a` counted in
      `:b` through `ExHdl.RTL.CDC.pulse_sync/1`.
    * `burst_fsm/1` - a small FSM: `start` begins a burst of `n` cycles,
      `busy` during it, `done` for one cycle after.
    * `ram/1` - simple dual-port RAM with byte enables and a synchronous
      read port (infers block RAM).
  """
  use ExHdl.RTL
  import Bitwise, only: [band: 2, bsl: 2, bsr: 2]

  alias ExHdl.RTL.CDC

  @doc """
  Counter: `count` increments while `en` is high, wrapping at `2^width`.

      iex> alias ExHdl.RTL.Sim
      iex> sim = ExHdl.RTL.Examples.counter(4) |> Sim.new() |> Sim.reset()
      iex> sim |> Sim.poke(:en, 1) |> Sim.step(3) |> Sim.peek(:count)
      3
  """
  def counter(width \\ 8) do
    module "counter_#{width}" do
      en = input(:en, 1)
      count = output(:count, width, reset: 0)

      sync do
        if en, do: count <~ add_wrap(count, 1)
      end
    end
  end

  @poly 0xEDB88320

  @doc """
  Ethernet CRC-32 (reflected polynomial `0xEDB88320`, init and final XOR
  `0xFFFFFFFF`), one byte per cycle. `clear` restarts (together with
  `valid` the byte is the first of a new frame); `crc` is the CRC of the
  bytes so far, i.e. `:erlang.crc32/1` of them.

  The next state is linear over GF(2) in state and data, so each next
  bit is the parity of a masked state word and a masked data byte. The
  masks come from running the bitwise algorithm on unit vectors in
  Elixir.
  """
  def crc32 do
    {state_masks, data_masks} = crc_masks()

    module "crc32_eth" do
      data = input(:data, 8)
      valid = input(:valid, 1)
      clear = input(:clear, 1)
      crc = output(:crc, 32)
      state = reg(:state, 32, reset: 0xFFFF_FFFF)
      fresh = wire(:fresh, mux(clear, const(0xFFFF_FFFF, 32), state))

      next =
        for j <- 31..0//-1 do
          bxor(
            reduce_xor(fresh &&& Enum.at(state_masks, j)),
            reduce_xor(data &&& Enum.at(data_masks, j))
          )
        end

      next = wire(:next, cat(next))

      sync do
        if valid do
          state <~ next
        else
          if clear, do: state <~ 0xFFFF_FFFF
        end
      end

      crc <~ ~~~state
    end
  end

  defp crc_masks do
    step = fn crc, byte ->
      Enum.reduce(1..8, Bitwise.bxor(crc, byte), fn _, c ->
        if band(c, 1) == 1, do: Bitwise.bxor(bsr(c, 1), @poly), else: bsr(c, 1)
      end)
    end

    mask = fn n, f ->
      for j <- 0..31 do
        Enum.reduce(0..(n - 1), 0, fn i, acc ->
          if band(bsr(f.(bsl(1, i)), j), 1) == 1, do: acc + bsl(1, i), else: acc
        end)
      end
    end

    {mask.(32, &step.(&1, 0)), mask.(8, &step.(0, &1))}
  end

  @doc """
  AXI4-Stream skid buffer (register slice) for any stream interface
  (default `ExHdl.RTL.Interface.axi_stream(data: 32)`): `s_axis` in,
  `m_axis` out, all `m_axis` outputs and `s_axis_tready` registered, one
  beat per cycle, no combinational path from `m_axis_tready` to
  `s_axis_tready`.
  """
  def skid_buffer(iface \\ Interface.axi_stream(data: 32)) do
    payload = for {f, t, :fwd} <- iface.fields, f != :tvalid, do: {f, t}

    name =
      Enum.map_join(payload, "_", fn {f, {_, w}} ->
        "#{String.replace_prefix("#{f}", "t", "")}#{w}"
      end)

    module "axis_skid_#{name}" do
      s = slave(:s_axis, iface)
      m = master(:m_axis, iface)

      out_valid = reg(:out_valid, 1)
      skid_valid = reg(:skid_valid, 1)
      out = Map.new(payload, fn {f, t} -> {f, reg(:"out_#{f}", t, reset: nil)} end)
      skid = Map.new(payload, fn {f, t} -> {f, reg(:"skid_#{f}", t, reset: nil)} end)

      s.tready <~ not skid_valid
      take = wire(:take, m.tready or not out_valid)

      sync do
        if take do
          if skid_valid do
            for {f, _} <- payload, do: out[f] <~ skid[f]
            skid_valid <~ 0
          else
            out_valid <~ s.tvalid
            for {f, _} <- payload, do: out[f] <~ s[f]
          end
        else
          if s.tvalid and not skid_valid do
            for {f, _} <- payload, do: skid[f] <~ s[f]
            skid_valid <~ 1
          end
        end
      end

      m.tvalid <~ out_valid
      for {f, _} <- payload, do: m[f] <~ out[f]
    end
  end

  @doc """
  Two clock domains. In `:a`, `fire` pulses `pulse` for one cycle; the
  pulse crosses to `:b` through `ExHdl.RTL.CDC.pulse_sync/1` and
  increments `count` (in `:b`). `seen` (in `:a`) counts the pulses sent.
  """
  def pulse_counter do
    module "pulse_counter" do
      domain(:a, clock: :clk_a, reset: :rst_a_n)
      domain(:b, clock: :clk_b, reset: :rst_b_n)
      fire = input(:fire, 1, domain: :a)
      seen = output(:seen, 8, reset: 0, domain: :a)
      count = output(:count, 8, reset: 0, domain: :b)

      ps = instance(:ps, CDC.pulse_sync(), domains: [src: :a, dst: :b])
      ps.pulse_in <~ fire

      sync :a do
        if fire, do: seen <~ add_wrap(seen, 1)
      end

      sync :b do
        if ps.pulse_out, do: count <~ add_wrap(count, 1)
      end
    end
  end

  @doc """
  FSM: `start` in `:idle` begins a burst of `n` cycles in `:run`
  (`busy` high), then one cycle in `:done` (`busy` and `done` high).
  `encoding:` as in `ExHdl.RTL.FSM` (`:binary` or `:one_hot`).
  """
  def burst_fsm(n \\ 4, opts \\ []) do
    encoding = Keyword.get(opts, :encoding, :binary)
    suffix = if encoding == :binary, do: "", else: "_#{encoding}"

    module "burst_fsm_#{n}#{suffix}" do
      start = input(:start, 1)
      _busy = output(:busy, 1)
      _done = output(:done, 1)
      left = reg(:left, max(ExHdl.RTL.Builder.ceil_log2(n + 1), 1))

      fsm :ctrl, reset: :idle, encoding: encoding do
        state :idle do
          if start do
            left <~ (n - 1)
            goto(:run)
          end
        end

        state :run, outputs: [busy: 1] do
          left <~ sub_wrap(left, 1)
          if left == 0, do: goto(:done)
        end

        state :done, outputs: [busy: 1, done: 1] do
          goto(:idle)
        end
      end
    end
  end

  @doc """
  Simple dual-port RAM: `we`/`waddr`/`wdata`/`be` write, `re`/`raddr`
  read; `rdata` is registered (one cycle latency, read-first). Infers
  block RAM with `style: :block` (default), URAM with `:ultra`.
  """
  def ram(opts \\ []) do
    width = Keyword.get(opts, :width, 32)
    depth = Keyword.get(opts, :depth, 1024)
    style = Keyword.get(opts, :style, :block)
    aw = ExHdl.RTL.Builder.ceil_log2(depth)

    module "ram_#{width}x#{depth}_#{style}" do
      we = input(:we, 1)
      be = input(:be, div(width, 8))
      waddr = input(:waddr, aw)
      wdata = input(:wdata, width)
      re = input(:re, 1)
      raddr = input(:raddr, aw)
      rdata = output(:rdata, width)

      mem = memory(:mem, width: width, depth: depth, style: style, init: Keyword.get(opts, :init))
      write_port(mem, addr: waddr, data: wdata, en: we, be: be)
      rdata <~ read_port(mem, addr: raddr, en: re)
    end
  end
end
