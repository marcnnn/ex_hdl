# ExHdl.RTL design note

`ExHdl.RTL` is the register-transfer layer of ExHdl: a small, strict
hardware description embedded in Elixir. MACs, PCS, PTP timestamping,
RTP datapaths, FIFOs and DMA engines in the sibling libraries are written
with it. This note is the contract; the moduledocs have the details.

## Model

A hardware module is the value returned by Elixir code. Generator
functions take parameters as ordinary arguments and use ordinary loops:

```elixir
defmodule MyLib.Counter do
  use ExHdl.RTL

  def build(width \\ 8) do
    module "counter_#{width}" do
      en = input :en, 1
      q = output :q, width
      count = reg :count, width, reset: 0

      sync do
        if en, do: count <~ add_wrap(count, 1)
      end

      q <~ count
    end
  end
end
```

`module/3` runs its body with an elaboration context, then checks the
result and returns a plain `%ExHdl.RTL.Module{}`. The SV backend, the
BEAM simulator and the co-simulation harness all read that struct.
Parameterised modules need distinct names (`"counter_#{width}"`); two
different modules with one name are rejected when emitting a hierarchy.

## Syntax

| Construct | Meaning |
|---|---|
| `input :a, 8` / `output :q, s(16)` | ports; a bare width is unsigned |
| `inout :sda, 1` | pad pin, only passed to instance inouts |
| `output :q, 8, reset: 0` | registered output |
| `reg :r, 8, reset: 0, domain: :sys` | register (`reset: nil` for none) |
| `wire :x, 8` / `wire :sum, a + b` | named combinational signal |
| `comb do ... end` | combinational block |
| `sync :dom do ... end` | register updates on the domain's clock |
| `x <~ expr` | assignment (module level: one-line `comb`) |
| `if c do ... else ... end` | conditional when `c` is hardware |
| `switch sel do 0 -> ...; [1, 2] -> ...; _ -> ... end` | case on constants |
| `domain :a, clock: :clk_a, reset: :rst_a_n` | clock domain |
| `instance :u, mod, connect: [en: x]` | child; `u.q`, `u.O`, `u[:O]`, `u.en <~ ...` |
| `memory :ram, width: 32, depth: 1024` | array; `read_port/2`, `write_port/2` |
| `master/slave/bundle :p, iface` | interface bundle; `connect(src, sink)` |
| `fsm :ctrl do state :idle do ... end end` | state machine (`encoding: :one_hot` optional) |
| `in_state(f, :idle)` / `in_state(:ctrl, :idle)` | state test, by handle or by name (may precede the FSM) |
| `black_box "IBUFDS" do ... end` | external module |
| `black_box_from("IBUFDS", ports, opts)` | the same from a port list `[{:input, :I, 1, opts}]` |

Inside `module/3`, `black_box/3` and `rtl/1` the operators `+ - * == !=
< <= > >= &&& ||| ~~~ <<< >>>` and `and or not && || !` build hardware
expressions when an operand is hardware and fall back to `Kernel`
otherwise. `if`/`unless` work the same way. XOR is `bxor/2` (Elixir 1.18
deprecates `^^^`). `cond` and `case` keep their Elixir meaning; use `if`,
`switch` and `mux` for hardware. Slices: `a[3]`, `a[0..7]` (ranges
ascend, low..high), `a[i]` with a signal index, `part(a, sel, w)` for
`w` bits from a signal start bit (SV `a[sel +: w]`).

`==` and `!=` with `nil` on either side stay Elixir comparisons, so a
fold over hardware values can test `acc == nil`. Any other use of `nil`
as an operand raises with a hint, as does a multi-bit hardware `if`
condition: inside `module/3` an `if` on a hardware value is a hardware
conditional, so elaboration-time decisions on generator values use
`case`, `is_nil/1` or `Kernel.if/2`.

Uppercase port names (vendor primitives) parse as aliases in `u.O`;
inside `module/3`, `black_box/3` and `rtl/1` the body is rewritten so
`u.O` means `pin(u, :O)`, the same as `u[:O]`.

`use ExHdl.RTL` imports the DSL and the `ExHdl.RTL.Expr` functions.
`use ExHdl.RTL, except: [:sync, :state]` (or `only:`; bare names or
`name: arity`) leaves names free for a library's own functions. The
statement macros `comb`, `sync`, `switch`, `fsm` and `state` called with
a `do` block always mean the DSL inside module bodies, imported or not;
other excluded functions are called qualified (`ExHdl.RTL.signal/1`).

`<~` is an Elixir operator with fixed precedence: it binds tighter than
comparisons, `and`/`or`, `&&&`, `|||`, `<<<` and `>>>`. Write
`full <~ (wptr == rptr)`. `<~` returns an `ExHdl.RTL.Assigned` marker
that every operator rejects, so a missing pair of parentheses raises
instead of building the wrong logic. Arithmetic (`x <~ a + b`) needs no
parentheses.

`Interface.axi_stream/1` has one `tkeep` bit per byte; `keep_unit: 32`
gives one per DWord (PCIe streams).

Registers take SV attributes with `attrs:` (`reg :r, 8, attrs:
[shreg_extract: "no"]`); `async_reg: true` adds `ASYNC_REG`.

## Types and widths

Every expression is `{:u, w}` or `{:s, w}` (two's complement), w >= 1.

1. Same signedness extends losslessly to the wider width; nothing else
   is implicit.
2. Signedness never changes implicitly. `as_signed/1`, `as_unsigned/1`
   reinterpret bits, `to_signed/1` adds a zero bit.
3. Nothing narrows implicitly. Assignments accept a right-hand side of
   the target's signedness that is not wider; `trunc/2`, `resize/2` or a
   slice narrow explicitly.
4. Integers adapt: the smallest fitting width in `+ - *` and comparisons,
   the other operand's type in bitwise ops, muxes and assignments. A
   constant that does not fit raises. A mux of integers only
   (`mux(c, 4, 3)`, `mux(sel, [1, 5, 2])`) takes the smallest type that
   holds all of them, signed if one is negative (`u3` here); an
   assignment then extends it to the target.

| Operation | Result |
|---|---|
| `a + b`, `a - b` | `max(wa, wb) + 1`; unsigned `-` wraps, top bit is the borrow |
| `add_wrap`, `sub_wrap` | `max(wa, wb)`, wrapping |
| `a * b` | `wa + wb` |
| `-a` (signed only) | `wa + 1` |
| `&&& ||| bxor` | `max(wa, wb)` |
| `~~~a` | `wa` |
| `a <<< n` / `a <<< b` | `wa + n` / `wa + 2^wb - 1` |
| `a >>> n`, `a >>> b` | `wa` (arithmetic if signed) |
| comparisons, `and or not`, `reduce_*` | `u1` (logic ops need `u1`) |
| `a[i]`, `a[lo..hi]` | `u1`, `u(hi - lo + 1)`; out-of-range dynamic index reads 0 |
| `part(a, sel, w)` | `uw`, bits `sel..sel + w - 1`, bits above `a` read 0 (a right shifter) |
| `cat([a, b])`, `rep(a, n)` | unsigned, sum of widths (first element in the MSBs); `nil` items skipped |
| `mux(c, a, b)` / `mux(sel, list)` | wider of the items |
| `zext`, `sext`, `trunc`, `resize` | as named |

There are no zero-width values. `slice(a, lo, 0)`, `a[lo..(lo - 1)//1]`,
`rep(a, 0)` and `cat([])` return `nil`, and `cat/1` skips `nil` items,
so generator code that builds an address from optional fields needs no
special case: `cat([bank, slice(slot, 0, group_bits), lane])` works
with `group_bits = 0`. Using `nil` anywhere else raises.

Violations raise `ExHdl.RTL.WidthError` at elaboration with both types
and the fix, e.g. `assignment to q: u9 value does not fit u8 (1 bit(s)
too wide); use trunc/2 or resize/2`.

Expressions fold at construction: operations on constants become
constants, a constant mux condition or index picks its operand, `x &&& 0`
and `x * 0` become 0, and comparisons that are constant over the other
operand's range (`u8 >= 0`) become 0 or 1. Generated SV therefore never
contains dead operands, which Verilator would report.

## Checks

At the end of `module/3`:

* names are SystemVerilog identifiers and not keywords (IEEE 1800-2017
  Annex B, checked when the signal is declared);
* every output, wire and instance input is driven exactly once (one comb
  block or one register domain);
* every comb target is assigned on every path (no latches);
* no combinational loops (across instances via their port paths);
* registers are assigned only in `sync` blocks of their own domain;
* clock domains: see below.

Errors are `ExHdl.RTL.ElaborationError` or `ExHdl.RTL.DomainError` and
name the signals involved.

## Simulation semantics

Combinational logic: in a `comb` block the last assignment to a signal
wins; a signal never reads itself. The block is a set of per-signal
equations, evaluated in dependency order.

Sequential logic: on a rising edge every register of that clock gets the
value its `sync` statements compute from the values before the edge
(nonblocking). Unassigned registers hold. If the domain's reset is
active, registers with a reset value take it instead (synchronous
resets at the edge, asynchronous resets as soon as they are asserted and
for as long as they are held). Registers without a reset ignore it.
State before any reset is 0, as in Verilator.

Memories: a write port writes `data` at `addr` when `en`, with byte
enables `be` (one bit per `byte:` bits). A synchronous read port
registers `mem[addr]` when `en`, reading the contents before that edge's
writes (read-first); an asynchronous port reads combinationally.
Out-of-range addresses read 0 and are not written. A synchronous read
of the word another port writes in the same cycle returns the old word
in the simulators; on block RAM in write-first or no-change mode and on
URAM288 the hardware result differs or is undefined, so designs that
read a word while the other port writes it need an address interlock
(the simulator does not flag the collision).

The BEAM simulator (`ExHdl.RTL.Sim`) is a value with `poke/3`,
`peek/2`, `step/2`, `cycle/3`, `run/2`, `reset/2`, `trace/1` and `vcd/2`.
Each top clock has a period and phase; an event is the set of clocks
rising at one time, and all of them update together. Black boxes run
their `ExHdl.RTL.Model`; without one, `Sim.new/2` raises.

`ExHdl.RTL.Cosim` compiles any module with a generated port-level
Verilator harness and runs the same stimulus (one input map per event).
`Cosim.assert_equivalent/3` checks BEAM and Verilator agree on every
output at every event. Ports and signals may have any width; values
wider than 64 bits are plain integers in the BEAM simulator and
`VlWide` words in the harness (tested at 65, 66, 72, 97, 128 and 512
bits).

## Reference models

`Cosim.check_model(module, stimulus, {state, step}, opts)` compares a
module cycle by cycle with an Elixir step function
`step.(state, inputs) -> {state, outputs}`, the form the reference
models of ex_net, ex_ptp and ex_aes67 have:

```elixir
model = {0, fn
  _count, %{rst_n: 0} -> {0, %{}}
  count, %{en: en} -> {rem(count + en, 256), %{count: count}}
end}

Cosim.assert_model(Counter.build(8), stimulus, model, backend: :both, latency: 0)
```

`inputs` is the full input map of the event (held values, resets
included). The returned outputs are compared with the RTL outputs of the
same event, sampled before the clock edge as in `Sim.run/2`; `nil` or a
missing port is "don't care", signed ports accept their raw bit pattern.
`latency: n` compares model step `i` with RTL event `i + n`; `backend:`
is `:beam`, `:verilator` or `:both`. `check_trace/4` takes a recorded
list of expected output maps instead of a step function. A mismatch
(`ExHdl.RTL.Cosim.Mismatch`) names the backend, the cycle, every
differing port with expected and actual values, and the last `history:`
cycles (default 8) of inputs and compared outputs:

```
counter_4 (beam) differs from the model at cycle 8:
  count: expected 7, actual 6
last 3 cycle(s), inputs | compared outputs:
       6: en=1 rst_n=1 | count=4
       7: en=1 rst_n=1 | count=5
>      8: en=1 rst_n=1 | count=6 (expected 7)
```

## Clock domains

A domain has a clock and an optional reset (`reset_kind: :sync | :async`,
`reset_active: :low | :high`). Defaults: `:sys` with `clk` and
synchronous active-low `rst_n`, created on first use when a module
declares none; other domains get `clk_<name>` / `rst_<name>_n`.
`clock_port: false` / `reset_port: false` make them internal wires
(driven by an MMCM black box or a reset synchroniser). Domains sharing a
clock signal are one clock group.

Every register and memory port belongs to a domain. Inputs default to the
only clock group; with several, inputs need `domain:`. A port may be
`:async` (any domain, CDC cells only) or `:static` (configuration that
changes only while idle; needs a timing exception in the constraints).

The check infers the domain of every combinational signal from its
inputs and rejects:

* combinational logic mixing two clock groups (or an async input with a
  clocked one);
* a register sampling another domain, unless it is `async_reg: true` or
  `cdc: true` (synchroniser stages);
* instance inputs, memory ports and declared outputs driven from the
  wrong domain.

`ExHdl.RTL.CDC.paths(top)` lists every crossing of a hierarchy for the
constraint generator: each `async_reg`/`cdc` register with the
registers, memories, black-box pins or top-level inputs of another clock
it samples, traced through comb logic and instance ports, with both
clocks named by their top-level clock signal. A Vivado flow emits
`set_max_delay -datapath_only` (or `set_false_path` for asynchronous
ports) per entry.

The crossings ExHdl provides (`ExHdl.RTL.CDC`): `sync_ff/1` (n-stage
synchroniser with `ASYNC_REG`), `pulse_sync/1`, `reset_sync/1`,
`handshake/2`, and `gray/1` / `ungray/1`. An asynchronous FIFO is a
dual-clock memory plus Gray pointers through `sync_ff(width: n)`; the
tests contain one.

## Mapping to SystemVerilog

`ExHdl.Backends.SystemVerilog.RTL.generate/1` returns one file per
module, `<name>.sv`, starting with `// Generated by ExHdl ... Do not
edit.`, wrapped in `` `default_nettype none ``. The output lints clean
under `verilator --lint-only -Wall`.

* Ports and signals keep their names and types (`logic signed [15:0]`).
  Instance ports are wires `<inst>_<port>`, sync read data
  `<mem>_rd<i>`, FSM states `localparam`s `<FSM>_<STATE>`, hoisted
  subexpressions `_t<n>`, forward state tests `<fsm>_in_<state>`. Inout
  ports are `inout wire` (a net, as `default_nettype none` requires).
* Instance port wires keep the plain `<inst>_<port>` names (stable for
  XDC and VCD paths). A parent signal with the same name is an error
  that names the instance and port; prefixing instances (`u_tx`) avoids
  it.
* Expressions carry explicit casts so SV's context-determined widths
  cannot change a result: operands are extended to the operation width
  (`9'(a) + 9'(b)`) and overflowing operations are wrapped in a size cast
  of their own width.
* A single unconditional assignment is an `assign`; other comb signals get
  one `always_comb` each. Each domain gets one `always_ff` for registers
  with reset (`if (!rst_n) ... else ...`, `or negedge rst_n` for async)
  and one for registers without.
* Memories follow the Vivado/Yosys inference templates: an unpacked
  array with `(* ram_style = "block" | "ultra" | "distributed" *)`, one
  `always_ff` per port, byte enables as per-byte conditional writes,
  `init` as an `initial` block. `ExHdl.Target.Timing.memory_style/3`
  picks a style from width, depth and the target family (URAM only on
  UltraScale+). `style: :auto` emits no attribute: the tool decides by
  size and port shape, and both Vivado and Yosys pick LUTRAM for shallow
  memories (64 x 256 becomes 37 Yosys RAM cells, `:block` 8 RAMB18).
* Unread signal bits get `verilator lint_off UNUSEDSIGNAL` pragmas,
  including the wires of instance outputs nobody reads.
* `mux(sel, list)` is a `case` in an `always_comb`. Yosys turns a case
  of constants into a ROM and may merge it with a register into block
  RAM. `wire(:t, mux(sel, table), rom_style: :distributed)` writes the
  case into `t`, declared `(* rom_style = "distributed" *)` for Vivado,
  with `(* rom_style = "logic" *)` on the case for Yosys, which then maps
  it to LUTs; `rom_style: :block` asks Vivado for block RAM.
* Black-box parameters: integers, strings, `{:bits, w, v}`, and floats or
  `{:real, n}` for `real` parameters (`CLKOUT0_DIVIDE_F`), emitted as
  `2.5`, `10.0`.

FSM states are `localparam`s; `encoding: :one_hot` gives an `n`-bit
state register with one bit per state, and `in_state/2` tests that bit.

Black boxes are not emitted; their `sources:` files are.
`sim_sources:` files (stubs of vendor primitives such as an `IBUFDS`
that would clash with the real one in Vivado) come only from
`generate(mod, sim: true)`. Black-box outputs may be marked `clock:
true` (`BUFG` `O`, `MMCME4_ADV` `CLKOUT0`), listed in the module's
`clock_outputs`.
`ExHdl.RTL.Wrap.protocol/2` and `ExHdl.RTL.Wrap.scan/1` wrap the
existing protocol and stream-kernel generators that way.

## Register maps

`ExHdl.Regs` declares a 32-bit register map once and derives the
AXI4-Lite slave, host helpers, a C header and Markdown:

```elixir
defmodule Mixer.Regs do
  use ExHdl.Regs

  defregs "mixer_regs" do
    register :ctrl, strobe: :write do
      field :enable, 0, :rw, reset: 1
      field :mode, 1..2, :rw, enum: [off: 0, mono: 1, stereo: 2]
    end

    register :irq do
      field :overflow, 0, :w1c
    end

    register :gain, count: 8 do
      field :value, 0..15, :rw, reset: 0x4000
    end

    window :coeffs, offset: 0x1000, size: 0x400, latency: 1
  end
end
```

Register, field and window names become signal names (`<reg>_<field>`,
`<reg>_<field>_set`, `<window>_en`, ...). They are checked when the map
is defined: a SystemVerilog keyword (`register :s` with `field :until`
gives `s_until`) or two declarations giving one name (`a_b.c` and
`a.b_c`, or a field clashing with the slave's internal signals) raise
there, not when the slave is elaborated.

Registers get the next free word unless `offset:` is given; `count:` and
`stride:` make arrays; fields take a bit or an ascending range and an
access type: `:rw` and `:wo` drive outputs `<reg>_<field>`, `:ro` reads
an input (or `const:`), `:w1c` and `:rc` keep status bits set by a
`<reg>_<field>_set` input, `:w1s` bits are cleared by
`<reg>_<field>_clr`. A hardware set beats a software clear in the same
cycle. `strobe:` adds registered `<reg>_wr` / `<reg>_rd` pulses. Windows
forward an aligned power-of-two range to an `Interface.mem_port/1`
master with byte enables, read data `latency` cycles after `en`.

`Mixer.Regs.rtl()` is the slave (`ExHdl.Regs.RTL`): all AXI outputs
registered, one access at a time, reads and writes alternating under
contention, byte strobes honoured, unmapped addresses OKAY (or SLVERR)
reading 0. `offset/2`, `encode/2`, `decode/2`, `update/3` serve host
drivers; `c_header/0` and `markdown/0` render the map.
`ExHdl.Regs.SimDriver` is an AXI4-Lite master for the BEAM simulator
with random handshake delays that records its stimulus for
`Cosim.assert_equivalent/3`.

The tests check the slave against a transaction-level model with that
driver and with an AXI4-Lite master written in RTL (commands from a ROM,
random stalls), both in the BEAM simulator and in Verilator, and the
encode/decode helpers with property tests.

## Verification

* Expression semantics are tested three ways with StreamData: random
  expression trees through the BEAM simulator, an independent integer
  implementation of the width table above (`test/support/rtl_gen.ex`),
  and Verilator on the generated SV.
* Random comb/sync blocks (nested `if`/`switch`, feedback through
  registers) are co-simulated BEAM against Verilator.
* Random expression modules must lint clean under `-Wall`.
* The examples, CDC cells and an asynchronous FIFO are co-simulated, two
  of them with two clocks; Yosys checks BRAM, URAM and LUTRAM inference.

## Limits

* Only rising-edge clocks; no latches or tristate logic. `inout` ports
  only pass through to instances (an `IOBUF` black box drives the pad);
  the simulators ignore them.
* No partial assignment (`x[3..0] <~ ...`); build words with `cat/1`.
* The BEAM simulator drives every clock ideally, including internal ones
  (an MMCM model does not generate its clock); co-simulation needs clocks
  that are top-level ports.
* Register initial values for FPGA configuration (`INIT`) are not
  emitted; state before reset is undefined on hardware.
* Register maps: 32-bit data, one clock domain (`:sys`, cross to others
  with `ExHdl.RTL.CDC`), one outstanding access; a field is either
  software-written (`rw`, `wo`) or hardware-driven (`ro`, `w1c`, `w1s`,
  `rc`), there is no `rw` field with a hardware write port.
