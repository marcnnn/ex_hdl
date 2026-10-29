# RFC / Issue: Idiomatic Functional RTL via State Transformations & Binary Pattern Matching

## Summary

Refactor the `ExHdl.RTL` hardware description layer from its current imperative, Verilog-style syntax (`reg`, `wire`, `sync do`, `<~`, and nested `if/else` ladders) to an idiomatic Elixir architecture based on **Pure State Transformations (`step(inputs, state) -> {outputs, next_state}`)**, **Binary Pattern Matching with the Pin Operator (`^`)**, and **Declarative Structural Schemas (Spark-style)**.

This allows complex hardware blocks with dual-port memories, arbitration, and control flow—such as [`ExAes67.RTL.JitterBuffer`](https://github.com/marcnnn/ex_aes67/blob/main/lib/ex_aes67/rtl/jitter_buffer.ex)—to be written as clean, idiomatic functional Elixir while compiling to both zero-overhead BEAM simulators and synthesizable, bit-identical SystemVerilog.

---

## Background & Problem Statement

Currently, clocked hardware modules in `ExHdl.RTL` are written using an imperative, mutable-feeling DSL. A prime example is `ExAes67.RTL.JitterBuffer.build/1`:

```elixir
# Current approach in lib/ex_aes67/rtl/jitter_buffer.ex
def build(opts \\ []) do
  # ...
  module name do
    # 40+ flat local scalar variables
    wr_valid = input(:wr_valid, 1)
    wr_ready = output(:wr_ready, 1)
    # ...
    w_busy = reg(:w_busy, 1)
    w_ch = reg(:w_ch, 11)
    w_ts = reg(:w_ts, 32)
    # ...
    bad = wire(:bad, w_ch >= n)
    late = wire(:late, d < 0)
    over = wire(:over, d >= depth)
    dup = wire(:dup, sv == 1 and stag == trunc(w_ts, tag))
    ok = wire(:ok, w_busy and not bad and not late and not over and not dup)
    # ...
    sync do
      w_busy <~ accept
      # ...
      # 5-level nested if/else pyramid ("Arrow Anti-pattern")
      if w_busy do
        if bad do
          st.bad_channel <~ add_wrap(st.bad_channel, 1)
        else
          if late do
            st.late <~ add_wrap(st.late, 1)
          else
            if over do
              st.overrun <~ add_wrap(st.overrun, 1)
            else
              if dup,
                do: st.duplicate <~ add_wrap(st.duplicate, 1),
                else: st.written <~ add_wrap(st.written, 1)
            end
          end
        end
      end
      # ...
    end
  end
end
```

### Limitations of Current Approach

1. **Anti-Idiomatic for Elixir Developers**:
   - The `<~` operator mimics Verilog non-blocking assignments (`<=`), creating cognitive dissonance with Elixir's immutable semantics.
   - Deeply nested `if/else` ladders are used instead of pattern matching or guard clauses.
   - 40+ scalar variables pollute a single monolithic function scope.
2. **Boolean Flag Arithmetic instead of Pattern Matching**:
   Memory slot validity, tags, and sample fields are unpacked through helper tuples and compared with separate equality wires (`hit = wire(:hit, bv == 1 and btag == trunc(play_ts, tag))`) instead of native bitstring matching.
3. **Implicit State Machines**:
   Control sequences (like stepping through playout channels) are manually managed with arithmetic on integer registers (`scan`, `ptr`, `s1_valid`) rather than tagged state transitions (`:idle`, `{:scanning, ptr, play_ts}`).
4. **Testing Friction**:
   Testing requires full RTL elaboration and simulation engines (BEAM RTL interpreter or Verilator) rather than simply running an Elixir function with `Enum.reduce/3` or `Stream.scan/3`.

---

## Proposed Architecture & Design

We propose an idiomatic hardware design model combining three pillars:

```
┌────────────────────────────────────────────────────────────────────────┐
│ 1. SPARK-STYLE DECLARATIVE SCHEMA: Ports, Memories, Topologies, Config │
├────────────────────────────────────────────────────────────────────────┤
│ 2. BINARY PATTERN MATCHING: Slot & Packet Layouts with Pin Operator (^)│
├────────────────────────────────────────────────────────────────────────┤
│ 3. PURE STATE TRANSFORMATION: step(inputs, state) -> {outputs, next}   │
└────────────────────────────────────────────────────────────────────────┘
```

### Pillar 1: Pure State Transformations (`step(inputs, state)`)

Mathematically, any synchronous digital circuit is a Mealy Machine:
$$\text{step}(\text{inputs}, \text{state}) \to \{\text{outputs}, \text{next\_state}\}$$

* **State**: A typed Elixir `defstruct` where fields map to hardware registers (flip-flops).
* **Inputs**: A map/struct mapping to input ports.
* **Outputs**: A map/struct mapping to output ports for the current clock cycle.
* **Next State**: The state values that latch into registers on the next rising clock edge.

### Pillar 2: Binary Pattern Matching with the Pin Operator (`^`)

Instead of manual field slicing and equality checks, memory words and packed fields are unpacked directly via Elixir bitstrings:

```elixir
# Check slot validity, compare tag, and extract sample in a single match:
case {state.s1_valid, slot_word} do
  {1, <<1::1, ^play_tag::32, sample::signed-24>>} ->
    {:hit, sample}

  {1, _stale_or_empty} ->
    {:underrun, 0}

  {0, _idle} ->
    {:idle, 0}
end
```

### Pillar 3: Tagged State Atoms & Event-Driven Reductions

Replace numeric flags and pointer arithmetic with tagged state tuples:
* Playout state: `:idle` | `{:scanning, ptr, play_ts}`.
* Write state: `:idle` | `{:evaluating, ch, ts, data}`.
* Event Counters: Unrolled via compile-time declarative reduction over event maps.

---

## Concrete Refactored Example: `ExAes67.RTL.JitterBuffer`

Below is the complete, proposed refactoring of `ExAes67.RTL.JitterBuffer`:

```elixir
defmodule ExAes67.RTL.JitterBuffer do
  @moduledoc """
  Timestamp-addressed jitter buffer synthesizing ExAes67.Model.JitterBuffer.
  Expressed as an idiomatic functional state transformation.
  """
  use ExHdl.Stateful

  # =========================================================================
  # Declarative Architecture & Structural Schema
  # =========================================================================

  config do
    param :channels, :pos_integer, default: 1024
    param :depth, :pos_integer, default: 64, validator: &ExHdl.Check.power_of_two/1
    param :tag_bits, :pos_integer, default: 32
    param :style, :atom, default: :block
  end

  ports do
    slave :wr,    ExHdl.Interface.ChannelWrite, ch_w: 11, ts_w: 32, data_w: s(24)
    slave :media, ExHdl.Interface.MediaClock
    master :out,  ExHdl.Interface.TdmStream,    ch_w: 10, data_w: s(24)
    input :latency, width: auto
  end

  memory :slots do
    style :block
    depth 64
    # Slot bitfield layout
    layout <<valid::1, tag::size(tag_bits), sample::signed-24>>
  end

  metrics do
    counter :written
    counter :late
    counter :overrun
    counter :duplicate
    counter :bad_channel
    counter :underrun
    counter :played
    counter :tick_overrun
  end

  # =========================================================================
  # State Definition (Circuit Registers)
  # =========================================================================

  defstruct [
    # Write stage: :idle | {:evaluating, ch, ts, data}
    write_stage: :idle,

    # Playout scan stage: :idle | {:scanning, ptr, play_ts}
    scan_stage: :idle,

    # Playout S1 pipeline stage: :idle | {:valid, ch, play_ts}
    s1_stage: :idle,

    # Dual-port RAM handle
    slots: %ExHdl.Memory{depth: 64, width: 72},

    # 32-bit Diagnostic counters
    stats: %{}
  ]

  # =========================================================================
  # Pure Step Function (Clock Edge Transition)
  # =========================================================================

  @doc "Evaluates one clock cycle given current inputs and current register state."
  def step(inputs, %__MODULE__{} = state) do
    # 1. Evaluate Playout Pipeline (Port B)
    {playout_out, next_playout, slots_b, playout_events} = 
      eval_playout(inputs, state)

    # 2. Evaluate Write Ingestion & Validation (Port A)
    {write_out, next_write, slots_a, write_events} = 
      eval_write(inputs, state, next_playout)

    # 3. Resolve RAM Port Access & Merge Memory
    slots = ExHdl.Memory.merge(slots_a, slots_b)

    # 4. Assemble Combinational Outputs for Current Cycle
    outputs = Map.merge(playout_out, write_out)

    # 5. Advance Register State for Next Clock Edge
    next_state = %__MODULE__{
      write_stage: next_write,
      scan_stage:  next_playout.scan,
      s1_stage:    next_playout.s1,
      slots:       slots,
      stats:       update_metrics(state.stats, playout_events ++ write_events)
    }

    {outputs, next_state}
  end

  # =========================================================================
  # Playout Pipeline Sub-functions
  # =========================================================================

  defp eval_playout(inputs, state) do
    t_now = sub_wrap(inputs.media.rtp_ts, inputs.latency)

    # Decode S1 stage memory output from previous cycle using bitstring matching
    {out_data, out_event} =
      case {state.s1_stage, ExHdl.Memory.read(state.slots, :port_b)} do
        {{:valid, _ch, play_ts}, <<1::1, ^play_ts::32, sample::signed-24>>} ->
          {sample, :played}

        {{:valid, _ch, _play_ts}, _stale_or_empty} ->
          {0, :underrun}

        {:idle, _} ->
          {0, nil}
      end

    # Advance scan pointer using pattern matching on the current scan state
    {next_scan, issue, scan_event} =
      case {state.scan_stage, inputs.media.tick} do
        {:idle, 1} ->
          {{:scanning, 0, t_now}, true, nil}

        {{:scanning, ptr, _ts}, 1} ->
          # Tick while scan running -> tick_overrun
          {{:scanning, ptr, t_now}, true, :tick_overrun}

        {{:scanning, ptr, play_ts}, 0} when ptr == @channels - 1 ->
          {:idle, true, nil}

        {{:scanning, ptr, play_ts}, 0} ->
          {{:scanning, ptr + 1, play_ts}, true, nil}

        {:idle, 0} ->
          {:idle, false, nil}
      end

    # S1 pipeline delay stage
    next_s1 =
      case {issue, state.scan_stage} do
        {true, {:scanning, ptr, play_ts}} -> {:valid, ptr, play_ts}
        _ -> :idle
      end

    out_ch = case state.s1_stage do
      {:valid, ch, _} -> trunc(ch, 10)
      :idle -> 0
    end

    outputs = %{
      out_valid: match?({:valid, _, _}, state.s1_stage),
      out_ch:    out_ch,
      out_first: match?({:valid, 0, _}, state.s1_stage),
      out_last:  match?({:valid, @channels - 1, _}, state.s1_stage),
      out_data:  out_data
    }

    events = Enum.reject([out_event, scan_event], &is_nil/1)
    {outputs, %{scan: next_scan, s1: next_s1}, state.slots, events}
  end

  # =========================================================================
  # Write Pipeline Sub-functions
  # =========================================================================

  defp eval_write(inputs, state, playout) do
    wr_ready = match?(:idle, state.write_stage)
    accept   = inputs.wr.valid and wr_ready

    {next_write, slots, write_event} =
      case state.write_stage do
        :idle ->
          next = if accept, do: {:evaluating, inputs.wr.ch, inputs.wr.ts, inputs.wr.data}, else: :idle
          {next, state.slots, nil}

        {:evaluating, ch, ts, data} ->
          # Validate candidate write
          case validate_write(ch, ts, state.slots, playout) do
            :ok ->
              # Commit write to Port A
              new_slots = ExHdl.Memory.write(state.slots, :port_a, slot_addr(ts, ch), <<1::1, ts::32, data::24>>)
              {:idle, new_slots, :written}

            {:rejected, reason} ->
              # reason is :bad_channel | :late | :overrun | :duplicate
              {:idle, state.slots, reason}
          end
      end

    outputs = %{wr_ready: wr_ready}
    {outputs, next_write, slots, List.wrap(write_event)}
  end

  defp validate_write(ch, ts, slots, playout) do
    floor = playout_floor(playout)
    d = as_signed(sub_wrap(ts, floor))

    cond do
      ch >= @channels -> {:rejected, :bad_channel}
      d < 0           -> {:rejected, :late}
      d >= @depth     -> {:rejected, :overrun}
      duplicate?(slots, ch, ts) -> {:rejected, :duplicate}
      true            -> :ok
    end
  end

  defp duplicate?(slots, ch, ts) do
    tag = trunc(ts, @tag_bits)
    case ExHdl.Memory.read(slots, :port_a, slot_addr(ts, ch)) do
      <<1::1, ^tag::size(@tag_bits), _::24>> -> true
      _ -> false
    end
  end

  defp update_metrics(stats, events) do
    Enum.reduce(events, stats, fn event, acc ->
      Map.update(acc, event, 1, &add_wrap(&1, 1))
    end)
  end
end
```

---

## Compilation & Synthesis Semantics (AST to RTL)

How the compiler (`ExHdl.Stateful.Compiler`) translates `step/2` into synthesizable SystemVerilog:

1. **State Registers**:
   Each key in `%__MODULE__{}` is mapped to a hardware register (`reg`). Tagged atoms (`:idle`, `{:scanning, ptr, ts}`) are encoded as standard one-hot or binary state variables.
2. **Ports**:
   `inputs` and `outputs` map directly to module top-level ports.
3. **Combinational Cloud**:
   The pure body of `step/2` is evaluated symbolically to build a Directed Acyclic Graph (DAG) of multiplexers, adders, and comparators.
4. **Binary Pattern Matches**:
   Matches such as `<<1::1, ^tag::32, sample::signed-24>>` compile directly to:
   - Bit slicing: `word[56:33]` for tag, `word[23:0]` for sample.
   - Equality comparators: `(word[57] == 1'b1) && (word[56:33] == tag)`.
   - Multi-way multiplexers for `case` branches.
5. **Next State Latches**:
   Values assigned in `next_state` connect to the `D` input of each respective register, driven by the clock edge:
   ```systemverilog
   always_ff @(posedge clk or negedge rst_n) begin
     if (!rst_n) begin
       write_stage <= IDLE;
       scan_stage  <= IDLE;
     end else begin
       write_stage <= next_write_stage;
       scan_stage  <= next_scan_stage;
     end
   end
   ```

---

## Verification & Acceptance Criteria

1. **BEAM Simulation without Toolchains**:
   Any stateful module can be simulated in pure Elixir using `Enum.map_reduce/3` over an input stream, producing 100% bit-accurate results against the model.
2. **SystemVerilog Emission**:
   `ExHdl.Stateful.emit_sv/1` generates synthesizable, lint-clean SystemVerilog (`verilator --lint-only -Wall`).
3. **Verilator Co-simulation Parity**:
   Co-simulation runs (`ExHdl.RTL.Cosim.check_model/4`) verify that the generated SystemVerilog produces output cycle-by-cycle bit-identical to the Elixir `step/2` reference.
4. **Zero Performance Penalty**:
   Resource utilization (LUTs, FFs, BRAMs) reported by Yosys for the refactored `JitterBuffer` matches or improves upon the original imperative `jitter_buffer.ex`.
