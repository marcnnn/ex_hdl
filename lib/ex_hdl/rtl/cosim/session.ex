defmodule ExHdl.RTL.Cosim.Session do
  @moduledoc """
  A running Verilator simulation of an `ExHdl.RTL` module, driven
  interactively: the closed-loop counterpart of `ExHdl.RTL.Cosim.run/3`.

  The API mirrors `ExHdl.RTL.Sim` (`poke/3`, `peek/2`, `outputs/1`,
  `step/2`, `cycle/3`, `run/2`, `reset/2`, `time/1`, `cycles/2`) with the
  same event model: every top-level clock has a period and a phase
  (`clocks:` as in `ExHdl.RTL.Sim.new/2`), an event raises all clocks due
  at that time, inputs apply immediately and outputs are read settled. A
  testbench written against `Sim` runs unchanged against a session
  (`ExHdl.RTL.Bench` works with both).

      {:ok, s} = Session.open(Counter.build(8))
      s = s |> Session.reset() |> Session.poke(:en, 1) |> Session.step(10)
      Session.peek(s, :count)    #=> 10
      Session.close(s)

  Unlike a `Sim`, a session is a handle on an OS process: the functions
  return the same handle, and old copies see the current state. Only
  top-level ports can be peeked, and only the process that opened the
  session may use it.

  The simulator process speaks a binary protocol over a pipe (one framed
  message per call, replies only for queries). `poke/3` and `step/2` do
  not wait for the process (they are sent with the next query), so a
  loop of poke, peek, step costs one round trip per cycle; `run/2` sends a whole stimulus in large batches and
  runs at Verilator speed, as do `step/2`, `cycle/3` and `step_until/4`
  for any number of events.

  Options of `open/2`:

    * `clocks:` - periods and phases, as in `ExHdl.RTL.Sim.new/2`.
    * `vcd: path` - write a VCD of the whole run (builds with `--trace`).
      Time in the VCD is 10 times the simulation time (clocks rise at
      `10 * t`, fall half a period later, inputs poked after a fall
      appear just before the next rise); `vcd_timescale:` (default
      `"100ps"`, for a simulation time unit of 1 ns) sets its header.
    * `flags:`, `cache_dir:` - passed to `ExHdl.Sim.Verilator.build/3`.

  Designs whose clocks come from inside (`domain(..., clock_port: false)`
  driven by an MMCM or BUFG black box) are opened with those clocks as
  top-level inputs, see `ExHdl.RTL.Cosim.substitute_clocks/1`.
  """

  alias ExHdl.Backends.SystemVerilog.RTL, as: SV
  alias ExHdl.RTL.{Cosim, Expr, Module, Sim}
  alias ExHdl.RTL.Sim.Flat

  defstruct [:port, :module, :exe, :inputs, :outputs, :index, :clocks, :domain_clock]

  @type t :: %__MODULE__{}

  @batch 4096

  @doc "Builds (cached) and starts the simulation."
  @spec open(Module.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(%Module{} = mod, opts \\ []) do
    with {:ok, mod, extra_flags} <- Cosim.prepare(mod) do
      clocks = for p <- mod.ports, p.role == :clock, do: p.name
      inputs = for p <- mod.ports, p.dir == :input, p.role != :clock, do: p
      outputs = Module.outputs(mod)
      periods = Sim.clock_periods(mod, Keyword.take(opts, [:clocks]))
      vcd = Keyword.get(opts, :vcd)

      build_opts =
        opts
        |> Keyword.take([:cache_dir, :verilator])
        |> Keyword.put(:flags, Keyword.get(opts, :flags, []) ++ extra_flags)
        |> Keyword.put(:trace, vcd != nil)

      with {:ok, exe} <- build(mod, inputs, outputs, clocks, build_opts) do
        args =
          Enum.flat_map(clocks, fn c ->
            {p, ph} = Map.fetch!(periods, Atom.to_string(c))
            [Integer.to_string(p), Integer.to_string(ph)]
          end)

        args =
          if vcd,
            do:
              args ++
                [
                  "--vcd",
                  Path.expand(vcd),
                  "--timescale",
                  Keyword.get(opts, :vcd_timescale, "100ps")
                ],
            else: args

        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            {:packet, 4},
            :nouse_stdio,
            :exit_status,
            args: args
          ])

        index =
          Map.new(
            Enum.with_index(inputs, fn p, i -> {p.name, {:in, i, p}} end) ++
              Enum.with_index(outputs, fn p, i -> {p.name, {:out, length(inputs) + i, p}} end)
          )

        domain_clock =
          Map.new(Flat.domain_clocks(mod), fn {d, c} ->
            {d, Enum.find_index(clocks, &(Atom.to_string(&1) == c))}
          end)

        {:ok,
         %__MODULE__{
           port: port,
           module: mod,
           exe: exe,
           inputs: inputs,
           outputs: outputs,
           index: index,
           clocks: clocks,
           domain_clock: domain_clock
         }}
      end
    end
  end

  @doc "Like `open/2`, raising on errors."
  @spec open!(Module.t(), keyword()) :: t()
  def open!(mod, opts \\ []) do
    case open(mod, opts) do
      {:ok, s} -> s
      {:error, reason} -> raise ArgumentError, "co-simulation failed: #{format_error(reason)}"
    end
  end

  defp format_error(r) when is_binary(r), do: r
  defp format_error(r), do: inspect(r)

  @doc "Stops the simulation process (flushes the VCD)."
  @spec close(t()) :: :ok
  def close(%__MODULE__{port: port}) do
    if Port.info(port) do
      send_cmd(port, [take_buffer(port), "Q"])

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        10_000 -> Port.close(port)
      end
    end

    :ok
  end

  # -- inputs and outputs ------------------------------------------------------------------

  @doc "Drives a top-level input (or several, from a map or keyword list)."
  def poke(%__MODULE__{} = s, name, value), do: poke(s, [{name, value}])

  def poke(%__MODULE__{} = s, values) do
    cmd = for {name, v} <- values, do: poke_cmd(s, name, v)
    if cmd != [], do: buffer(s.port, cmd)
    s
  end

  defp poke_cmd(s, name, v) do
    case Map.get(s.index, name) do
      {:in, i, p} ->
        v = if is_boolean(v), do: if(v, do: 1, else: 0), else: v

        unless is_integer(v) and v in Expr.range(p.type),
          do: raise(ArgumentError, "#{name}: #{inspect(v)} does not fit #{Expr.fmt(p.type)}")

        [?P, <<i::16>>, words(v, p.type)]

      {:out, _, _} ->
        raise ArgumentError, "#{name} is not a drivable input"

      nil ->
        if name in s.clocks,
          do:
            raise(
              ArgumentError,
              "#{name} is not a drivable input (clocks are driven by the simulator)"
            ),
          else: raise(ArgumentError, "no port #{inspect(name)}")
    end
  end

  @doc "Value of a top-level port (outputs settled, inputs as last poked)."
  def peek(%__MODULE__{} = s, name) do
    {_, i, p} = Map.get(s.index, name) || raise(ArgumentError, "no port #{inspect(name)}")
    n = nwords(p.type) * 32
    <<v::little-size(n)>> = query(s.port, [?G, <<i::16>>])
    Expr.wrap(v, p.type)
  end

  @doc "All top-level outputs as a map."
  def outputs(%__MODULE__{} = s), do: decode_outputs(query(s.port, "O"), s.outputs)

  defp decode_outputs(bin, outputs) do
    {map, <<>>} =
      Enum.reduce(outputs, {%{}, bin}, fn p, {acc, bin} ->
        n = nwords(p.type) * 32
        <<v::little-size(n), rest::binary>> = bin
        {Map.put(acc, p.name, Expr.wrap(v, p.type)), rest}
      end)

    map
  end

  # -- time --------------------------------------------------------------------------------

  @doc "Advances `n` edge events (default 1)."
  def step(%__MODULE__{} = s, n \\ 1) when is_integer(n) and n >= 0 do
    if n > 0, do: buffer(s.port, [?S, <<n::64>>])
    s
  end

  @doc "Advances until the clock of `domain` has risen `n` more times."
  def cycle(%__MODULE__{} = s, domain \\ nil, n \\ 1) do
    domain = domain || s.module.default_domain

    c =
      Map.get(s.domain_clock, domain) || raise(ArgumentError, "no domain #{inspect(domain)}")

    if n > 0, do: buffer(s.port, [?C, <<c::8, n::64>>])
    s
  end

  @doc """
  Steps until output `port` equals `value` (checked before every event,
  like a `run_until`), at most `max` events. Returns `{session, events}`;
  `events == max` with the condition still false means it timed out.
  """
  def step_until(%__MODULE__{} = s, port, value, max) do
    {:out, i, p} =
      case Map.get(s.index, port) do
        {:out, _, _} = o -> o
        _ -> raise ArgumentError, "#{inspect(port)} is not an output"
      end

    <<k::64>> = query(s.port, [?U, <<max::64, i::16>>, words(value, p.type)])
    {s, k}
  end

  @doc """
  Runs a stimulus as `ExHdl.RTL.Sim.run/2` does: for each element (a map
  or keyword list of inputs) pokes it, samples all outputs, then advances
  one event. Returns `{session, samples}`.
  """
  def run(%__MODULE__{} = s, stimulus) do
    samples =
      stimulus
      |> Stream.chunk_every(@batch)
      |> Enum.flat_map(fn chunk ->
        body =
          Enum.map(chunk, fn ins ->
            pokes = Enum.map(ins, fn {k, v} -> s |> poke_cmd(k, v) |> tl() end)
            [<<length(pokes)::16>> | pokes]
          end)

        bin = query(s.port, [?R, <<length(chunk)::32>> | body])
        split_samples(bin, s.outputs, out_bytes(s.outputs), [])
      end)

    {s, samples}
  end

  defp out_bytes(outputs), do: outputs |> Enum.map(&(nwords(&1.type) * 4)) |> Enum.sum()

  defp split_samples(<<>>, _outputs, _n, acc), do: Enum.reverse(acc)

  defp split_samples(bin, outputs, n, acc) do
    <<one::binary-size(n), rest::binary>> = bin
    split_samples(rest, outputs, n, [decode_outputs(one, outputs) | acc])
  end

  @doc "Holds every top-level reset asserted for `cycles` events, then releases them (as `Sim.reset/2`)."
  def reset(%__MODULE__{} = s, cycles \\ 2) do
    resets = Sim.reset_inputs(s.module, :asserted)
    s = s |> poke(resets) |> step(cycles)
    poke(s, Sim.reset_inputs(s.module, :released))
  end

  @doc "Current simulation time."
  def time(%__MODULE__{} = s), do: s |> times() |> elem(0)

  @doc "Rising edges so far of the clock of `domain`."
  def cycles(%__MODULE__{} = s, domain \\ nil) do
    domain = domain || s.module.default_domain
    c = Map.get(s.domain_clock, domain) || raise(ArgumentError, "no domain #{inspect(domain)}")
    s |> times() |> elem(1) |> Enum.at(c)
  end

  defp times(s) do
    <<t::signed-64, rest::binary>> = query(s.port, "T")
    {t, for(<<e::64 <- rest>>, do: e)}
  end

  # -- protocol ----------------------------------------------------------------------------

  defp nwords(type), do: max(div(Expr.width(type) + 31, 32), 1)

  defp words(v, type) do
    n = nwords(type) * 32
    <<Expr.raw(v, type)::little-size(n)>>
  end

  defp send_cmd(port, iodata) do
    try do
      Port.command(port, iodata)
    rescue
      ArgumentError -> raise ArgumentError, "the co-simulation session is closed"
    end
  end

  # Commands without a reply wait in the owner's process dictionary and go
  # out with the next query (one pipe write per round trip).
  @max_buffered 512

  defp buffer(port, iodata) do
    key = {__MODULE__, port}
    {buf, n} = Process.get(key, {[], 0})

    if n + 1 >= @max_buffered do
      Process.delete(key)
      send_cmd(port, [buf, iodata])
    else
      Process.put(key, {[buf, iodata], n + 1})
    end

    :ok
  end

  defp take_buffer(port) do
    case Process.delete({__MODULE__, port}) do
      {buf, _} -> buf
      nil -> []
    end
  end

  defp query(port, iodata) do
    send_cmd(port, [take_buffer(port), iodata])

    receive do
      {^port, {:data, bin}} ->
        bin

      {^port, {:exit_status, status}} ->
        raise "co-simulation process exited with status #{status}"
    end
  end

  # -- harness -----------------------------------------------------------------------------

  defp build(mod, inputs, outputs, clocks, opts) do
    harness = harness(mod.name, inputs, outputs, clocks)
    dir = Keyword.get_lazy(opts, :cache_dir, &Cosim.cache_dir/0)
    File.mkdir_p!(dir)
    hash = :crypto.hash(:sha256, harness) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    path = Path.join(dir, "rtl_session_#{mod.name}_#{hash}.cpp")
    unless File.exists?(path), do: File.write!(path, harness)
    opts = opts |> Keyword.put(:harness, path) |> Keyword.put_new(:cache_dir, dir)
    ExHdl.Sim.Verilator.build(SV.generate(mod, sim: true), mod.name, opts)
  end

  @doc false
  def harness(name, inputs, outputs, clocks) do
    w = fn p -> Expr.width(p.type) end
    nw = fn p -> nwords(p.type) end

    set_in =
      inputs
      |> Enum.with_index()
      |> Enum.map(fn {p, i} ->
        "    case #{i}: set_port(top->#{p.name}, #{w.(p)}, w); break;\n"
      end)

    get_all =
      (inputs ++ outputs)
      |> Enum.with_index()
      |> Enum.map(fn {p, i} ->
        "    case #{i}: get_port(top->#{p.name}, #{w.(p)}, w); break;\n"
      end)

    nwords_list = Enum.map_join(inputs ++ outputs, ", ", &Integer.to_string(nw.(&1)))

    set_clk =
      clocks
      |> Enum.with_index()
      |> Enum.map(fn {c, i} -> "    case #{i}: top->#{c} = v; break;\n" end)

    """
    // Generated by ExHdl.RTL.Cosim.Session for module #{name}. Do not edit.
    // Interactive simulation: framed commands on fd 3, replies on fd 4
    // (4-byte big-endian length, then the message). See session.ex.
    #include <cstdint>
    #include <cstdio>
    #include <cstdlib>
    #include <cstring>
    #include <memory>
    #include <string>
    #include <type_traits>
    #include <vector>
    #include <unistd.h>

    #include "Vtop.h"
    #include "verilated.h"
    #ifdef EXHDL_TRACE
    #include "verilated_vcd_c.h"
    #endif

    static const int NIN = #{length(inputs)};
    static const int NPORT = #{length(inputs) + length(outputs)};
    static const int NCLK = #{length(clocks)};
    static const int NWORDS[] = {#{nwords_list}#{if inputs ++ outputs == [], do: "0", else: ""}};

    static std::unique_ptr<VerilatedContext> ctx;
    static std::unique_ptr<Vtop> top;
    #ifdef EXHDL_TRACE
    static VerilatedVcdC* tfp = nullptr;
    #endif
    static bool dirty = true;
    static int64_t now = 0;
    static int64_t period[NCLK + 1], next_t[NCLK + 1];
    static uint64_t edges[NCLK + 1];
    static uint64_t last_dump = 0;
    static bool dumped = false, pending = true;

    template <typename T>
    static void set_port(T& port, int width, const uint32_t* w) {
        if constexpr (std::is_integral<T>::value) {
            uint64_t v = w[0];
            if (width > 32) v |= (uint64_t)w[1] << 32;
            port = (T)v;
        } else {
            int n = (width + 31) / 32;
            for (int i = 0; i < n; i++) port[i] = w[i];
        }
    }

    template <typename T>
    static void get_port(const T& port, int width, uint32_t* w) {
        if constexpr (std::is_integral<T>::value) {
            uint64_t v = (uint64_t)port;
            if (width < 64) v &= (1ull << width) - 1;
            w[0] = (uint32_t)v;
            if (width > 32) w[1] = (uint32_t)(v >> 32);
        } else {
            int n = (width + 31) / 32;
            for (int i = 0; i < n; i++) {
                uint32_t x = port[i];
                if (i == n - 1 && width % 32) x &= (1u << (width % 32)) - 1;
                w[i] = x;
            }
        }
    }

    static void set_in(int i, const uint32_t* w) {
        switch (i) {
    #{set_in}    default: break;
        }
        dirty = true;
        pending = true;
    }

    static void get_val(int i, uint32_t* w) {
        switch (i) {
    #{get_all}    default: break;
        }
    }

    static void set_clk(int i, int v) {
        switch (i) {
    #{set_clk}    default: (void)v; break;
        }
    }

    static void settle() {
        if (dirty) { top->eval(); dirty = false; }
    }

    static void dump_at(uint64_t t) {
    #ifdef EXHDL_TRACE
        if (tfp && (!dumped || t > last_dump)) { tfp->dump(t); last_dump = t; dumped = true; }
    #else
        (void)t;
    #endif
    }

    // One event: raise every clock due at the earliest time, settle, lower them.
    static void event() {
        settle();
        if (NCLK == 0) return;
        int64_t t = next_t[0];
        for (int c = 1; c < NCLK; c++) if (next_t[c] < t) t = next_t[c];
        int64_t half = 0;
        if (pending) { if (t > 0) dump_at((uint64_t)(10 * t - 1)); pending = false; }
        bool fire[NCLK + 1];
        for (int c = 0; c < NCLK; c++) {
            fire[c] = next_t[c] == t;
            if (fire[c]) {
                set_clk(c, 1);
                int64_t h = period[c] / 2 > 0 ? period[c] / 2 : 1;
                if (half == 0 || h < half) half = h;
            }
        }
        top->eval();
        dump_at((uint64_t)(10 * t));
        for (int c = 0; c < NCLK; c++) {
            if (fire[c]) { set_clk(c, 0); next_t[c] += period[c]; edges[c]++; }
        }
        top->eval();
        int64_t tn = next_t[0];
        for (int c = 1; c < NCLK; c++) if (next_t[c] < tn) tn = next_t[c];
        if (10 * (t + half) < 10 * tn - 1) dump_at((uint64_t)(10 * (t + half)));
        else pending = true;
        now = t;
    }

    // -- framing --------------------------------------------------------------------------
    static bool read_exact(void* buf, size_t n) {
        char* p = (char*)buf;
        while (n > 0) {
            ssize_t r = read(3, p, n);
            if (r <= 0) return false;
            p += r; n -= (size_t)r;
        }
        return true;
    }

    static void write_exact(const void* buf, size_t n) {
        const char* p = (const char*)buf;
        while (n > 0) {
            ssize_t r = write(4, p, n);
            if (r <= 0) std::exit(3);
            p += r; n -= (size_t)r;
        }
    }

    static std::vector<uint8_t> reply;
    static void put32(uint32_t v) { for (int i = 0; i < 4; i++) reply.push_back((uint8_t)(v >> (8 * i))); }
    static void put64be(uint64_t v) { for (int i = 7; i >= 0; i--) reply.push_back((uint8_t)(v >> (8 * i))); }
    static void put_val(int i) {
        uint32_t w[NWORDS[i] > 0 ? NWORDS[i] : 1];
        std::memset(w, 0, sizeof w);
        get_val(i, w);
        for (int k = 0; k < NWORDS[i]; k++) put32(w[k]);
    }
    static void put_outputs() { settle(); for (int i = NIN; i < NPORT; i++) put_val(i); }

    struct Reader {
        const uint8_t* p; const uint8_t* end;
        uint8_t u8() { return *p++; }
        uint16_t u16() { uint16_t v = (uint16_t)((p[0] << 8) | p[1]); p += 2; return v; }
        uint32_t u32() { uint32_t v = 0; for (int i = 0; i < 4; i++) v = (v << 8) | p[i]; p += 4; return v; }
        uint64_t u64() { uint64_t v = 0; for (int i = 0; i < 8; i++) v = (v << 8) | p[i]; p += 8; return v; }
        void words(uint32_t* w, int n) {
            for (int k = 0; k < n; k++) { w[k] = (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; p += 4; }
        }
    };

    static bool equal_out(int i, const uint32_t* v) {
        uint32_t w[NWORDS[i] > 0 ? NWORDS[i] : 1];
        get_val(i, w);
        for (int k = 0; k < NWORDS[i]; k++) if (w[k] != v[k]) return false;
        return true;
    }

    int main(int argc, char** argv) {
        if (argc < 1 + 2 * NCLK) { std::fprintf(stderr, "usage: %s (period phase)*\\n", argv[0]); return 1; }
        for (int c = 0; c < NCLK; c++) {
            period[c] = std::atoll(argv[1 + 2 * c]);
            next_t[c] = std::atoll(argv[2 + 2 * c]);
            edges[c] = 0;
        }
        const char* vcd = nullptr;
        const char* timescale = "100ps";
        for (int a = 1 + 2 * NCLK; a + 1 < argc; a += 2) {
            if (!std::strcmp(argv[a], "--vcd")) vcd = argv[a + 1];
            if (!std::strcmp(argv[a], "--timescale")) timescale = argv[a + 1];
        }
        ctx = std::make_unique<VerilatedContext>();
    #ifdef EXHDL_TRACE
        if (vcd) ctx->traceEverOn(true);
    #endif
        top = std::make_unique<Vtop>(ctx.get());
    #ifdef EXHDL_TRACE
        if (vcd) {
            tfp = new VerilatedVcdC;
            top->trace(tfp, 99);
            tfp->set_time_unit(timescale);
            tfp->set_time_resolution(timescale);
            tfp->open(vcd);
        }
    #else
        (void)vcd; (void)timescale;
    #endif
        for (int c = 0; c < NCLK; c++) set_clk(c, 0);
        top->eval();
        dirty = false;

        std::vector<uint8_t> msg;
        uint32_t wbuf[4096];
        for (;;) {
            uint8_t hdr[4];
            if (!read_exact(hdr, 4)) break;
            uint32_t len = (uint32_t)hdr[0] << 24 | (uint32_t)hdr[1] << 16 | (uint32_t)hdr[2] << 8 | hdr[3];
            msg.resize(len);
            if (len && !read_exact(msg.data(), len)) break;
            Reader r{msg.data(), msg.data() + len};
            reply.clear();
            bool quit = false;
            while (r.p < r.end && !quit) {
                switch (r.u8()) {
                    case 'P': { int i = r.u16(); r.words(wbuf, NWORDS[i]); set_in(i, wbuf); break; }
                    case 'S': { uint64_t n = r.u64(); for (uint64_t k = 0; k < n; k++) event(); break; }
                    case 'C': {
                        int c = r.u8(); uint64_t n = r.u64();
                        uint64_t target = edges[c] + n;
                        while (edges[c] < target) event();
                        break;
                    }
                    case 'U': {
                        uint64_t max = r.u64(); int i = r.u16(); r.words(wbuf, NWORDS[i]);
                        uint64_t k = 0;
                        for (; k < max; k++) { settle(); if (equal_out(i, wbuf)) break; event(); }
                        put64be(k);
                        break;
                    }
                    case 'G': { int i = r.u16(); settle(); put_val(i); break; }
                    case 'O': put_outputs(); break;
                    case 'R': {
                        uint32_t n = r.u32();
                        for (uint32_t e = 0; e < n; e++) {
                            int k = r.u16();
                            for (int j = 0; j < k; j++) { int i = r.u16(); r.words(wbuf, NWORDS[i]); set_in(i, wbuf); }
                            put_outputs();
                            event();
                        }
                        break;
                    }
                    case 'T': {
                        put64be((uint64_t)now);
                        for (int c = 0; c < NCLK; c++) put64be(edges[c]);
                        break;
                    }
                    case 'Q': quit = true; break;
                    default: std::fprintf(stderr, "bad command\\n"); return 2;
                }
            }
            if (!reply.empty()) {
                uint32_t n = (uint32_t)reply.size();
                uint8_t h[4] = {(uint8_t)(n >> 24), (uint8_t)(n >> 16), (uint8_t)(n >> 8), (uint8_t)n};
                write_exact(h, 4);
                write_exact(reply.data(), reply.size());
            }
            if (quit) break;
        }
        if (pending) dump_at((uint64_t)(10 * now + 1));
        top->final();
    #ifdef EXHDL_TRACE
        if (tfp) { tfp->close(); delete tfp; }
    #endif
        return 0;
    }
    """
  end
end
