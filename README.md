# ExHdl

Elixir-to-FPGA co-design for the Xilinx Zynq-7020: packet protocols and
fixed-point stream kernels written once in Elixir, run as software and
generated as SystemVerilog, bit-identical.

## The library family

| Library | Scope |
|---|---|
| [nx_fixed](../nx_fixed) | number formats, fixed-point primitives, range analysis and width check for Nx |
| [nx_simd](../nx_simd) | Nx compiler to native code for integer and quantized graphs |
| [ex_sdr](../ex_sdr) | radio building blocks (DSP, channel coding, OFDM), DVB-T, GNU Radio comparisons |
| **ex_hdl** (this one) | hardware: protocol DSL, SystemVerilog, scheduling and timing, co-simulation |
| [elixir_type_laws](../elixir_type_laws) | set-theoretic laws checked against Elixir's type system |

ExHdl only provides the basics: describing, simulating and building
hardware. Function lives in the hardware library set built on it:

| Library | Scope |
|---|---|
| [ex_hdl_cores](../ex_hdl_cores) | generic IP: FIFOs, CRC, arbiters, AXI4-Stream plumbing |
| [ex_hdl_xilinx](../ex_hdl_xilinx) | Xilinx primitives, constraints, boards, Vivado |
| [ex_net](../ex_net) | Ethernet MAC, PCS, VLAN/IPv4/UDP/IGMP |
| [ex_ptp](../ex_ptp) | IEEE 1588: timestamping, wallclock, servo, BMCA |
| [ex_aes67](../ex_aes67) | RTP streams, jitter buffer, SAP/SDP, RTSP, mDNS, NMOS |
| [ex_audio](../ex_audio) | audio DSP kernels: EQ, dynamics, matrix mixer, meters |
| [ex_pcie](../ex_pcie) | PCIe DMA and BAR access, host side over vfio |

## Status

| Area | State |
|---|---|
| `ExHdl.Protocol`: `defpacket` DSL, BEAM codecs, AXI4-Stream parser/emitter in SystemVerilog | done |
| Header chains (`defheader`, `layer`, `next:`): VLAN stacks, IPv4 options, lengths and checksums, runtime match tables, payload realigned from any byte lane | done |
| Verilator co-simulation (`ExHdl.Sim.Verilator`) | done |
| Stateful streams: recurrence analysis, `ii:`/`channels:`, Zynq timing model (`ExHdl.DSP.analyze_scan/3`, on top of nx_fixed's width check) | done |
| Stream kernels to SystemVerilog (`ExHdl.Backends.SystemVerilog.Scan`): AXI4-Stream module per kernel, bit-identical with the Nx reference | done |
| FIRs as transposed DSP48E1 chains with pre-adder folding, running sums, delay lines in LUT RAM / block RAM (`ExHdl.Backends.SystemVerilog.Fir`) | done |
| Blocks from `%NxFixed.Block{}` descriptions (`ExHdl.Block`), variable-rate outputs; 46 ex_sdr stream blocks co-simulated | done |
| Many channels on one pipeline: state in LUT RAM, block RAM or UltraRAM (`state_mem:`), per-channel parameters from a double-buffered memory with a host write port (`channel_params:`), `tid` and `tuser` through the pipeline | done |
| Feedback loops per state group (a cascade of k filters has the loop of one), kernel composition (`ExHdl.DSP.cascade/1`) | done |
| Resource estimates with Yosys `synth_xilinx` (`ExHdl.Synth.Yosys`, `mix ex_hdl.gen.sv --synth`, 7-series and UltraScale+) | done |
| `ExHdl.RTL`: RTL DSL with explicit widths, clock domains and a domain-crossing check, FSMs, interface bundles (AXI4-Stream, AXI4-Lite, memory port), inferred memories, black boxes ([design note](docs/rtl_dsl.md)) | done |
| RTL to SystemVerilog (`ExHdl.Backends.SystemVerilog.RTL`), lint-clean under `verilator -Wall` | done |
| BEAM RTL simulator with multiple clocks and VCD (`ExHdl.RTL.Sim`), port-level Verilator co-simulation (`ExHdl.RTL.Cosim`), ports of any width | done |
| Cycle-by-cycle check of RTL against an Elixir step function or a recorded trace, BEAM and Verilator, with a mismatch report (`ExHdl.RTL.Cosim.check_model/4`) | done |
| One-hot FSM encoding, indexed part select `part/3` | done |
| BEAM simulator compiled to BEAM code (100x to 1000x faster on large designs), interpreter kept as reference | done |
| Closed-loop Verilator sessions (`ExHdl.RTL.Cosim.open/2`), agent testbench on both simulators (`ExHdl.RTL.Bench`), Verilator VCD of replays, Verilator flags | done |
| BEAM models for wrapped stream kernels (`Wrap.scan(design, model: ...)`), signed kernel ports, black-box models with instance parameters, co-simulation of designs with internal (MMCM) clocks | done |
| CDC cells (`ExHdl.RTL.CDC`: synchroniser, pulse, reset, handshake) and wrappers for protocol and stream-kernel modules (`ExHdl.RTL.Wrap`) | done |
| Retiming, `accelerator` DSL | planned |
| openXC7 bitstream builder, Zynq runtime | planned |
| `defregs` register maps (`ExHdl.Regs`): AXI4-Lite slave with rw/ro/wo/w1c/w1s/rc fields, arrays, strobes and RAM windows; host encode/decode, C header, Markdown; BEAM AXI4-Lite master (`ExHdl.Regs.SimDriver`) | done |
| Timing families (`ExHdl.Target.Timing`): Zynq-7000 and UltraScale+ (DSP48E2, URAM, -1/-2 delays), from `ExHdlXilinx.Device` data | done |
| Gathers: parameters that are RAMs read by `Nx.take` at computed addresses, a read port per index element, write port and bank swap (`memories:`); frame sideband from `tlast` (`frame: true`) | done |
| Products wider than a DSP multiplier split into slices per family (`Timing.dsp_split/3`), DSP sharing under `ii: n`, slice count per design | done |
| Idioms: signed wraps as wiring (`ExHdl.DSP.wrap/2`: accumulators without a clamp, one adder in the loop), leading one as a priority encoder (`ExHdl.DSP.msb/2`, `count_leading_zeros/2`) | done |

## Development

```sh
mix test                      # unit and property tests; co-simulation if verilator is in PATH
mix test --only verilator     # co-simulation only
mix test --only yosys         # resource checks
mix ex_hdl.gen.sv MyApp.Protocol --out hdl/generated
mix ex_hdl.gen.sv MyApp.Kernels --out hdl/generated --synth   # stream kernels, ex_hdl_kernels/0
```

## Packets in hardware

`defpacket` describes a header chain once; it becomes a BEAM codec and an
AXI4-Stream parser and emitter. The AES67 receive chain:

```elixir
defheader :eth do
  field :dst, 48
  field :src, 48
  field :ethertype, 16, type: {:enum, vlan: 0x8100, qinq: 0x88A8, ipv4: 0x0800}
end

defheader :vlan do
  field :pcp, 3
  field :dei, 1, type: :flag
  field :vid, 12
  field :ethertype, 16, type: {:enum, vlan: 0x8100, ipv4: 0x0800}
end

defheader :ipv4 do
  field :version, 4, assert: 4, error: :not_ipv4
  field :ihl, 4, header_length: 4
  field :dscp_ecn, 8
  field :total_length, 16, length: :total
  field :id, 16
  field :flags_frag, 16
  field :ttl, 8
  field :protocol, 8
  field :checksum, 16, checksum: :header
  field :src, 32
  field :dst, 32
  field :options, :bytes
end

defheader :udp do
  field :src_port, 16
  field :dst_port, 16, match: 4
  field :length, 16, length: :total
  field :checksum, 16, checksum: :segment, optional: true,
    pseudo: [{:ipv4, :src}, {:ipv4, :dst}, {:ipv4, :protocol}, :length]
end

defpacket :udp_rx, bus_width: 64 do
  layer :eth, next: {:ethertype, vlan: :vlan, qinq: :vlan, ipv4: :ipv4}
  layer :vlan, max: 2, next: {:ethertype, vlan: :vlan, ipv4: :ipv4}
  layer :ipv4, next: {:protocol, %{17 => :udp}}
  layer :udp
  payload :data, type: :bytes
end
```

`encode_udp_rx(%{eth: ..., vlan: [...], ipv4: ..., udp: ...}, payload)`
fills in EtherTypes, IHL, lengths and checksums; `decode_udp_rx/2` checks
them, cuts Ethernet padding and returns `{:ok, header, payload}` or an
`{:error, {kind, {layer, field}, value}}` (`ExHdl.Protocol.Codec`);
`decode_udp_rx_header/2` stops after the headers.

The parser matches every header layout (here 33: 0-2 tags times 11 IHL
values) in parallel against a byte register of the header, decides in the
beat holding the last header byte, and shifts the payload to lane 0 with
one register of the previous beat. It accepts one beat per cycle on 8 to
64-bit buses, also across packet boundaries. Header errors drop the packet
(`dropped_packets`); a packet shorter than its length field or with a bad
UDP checksum is forwarded with `m_axis_tuser` on its last beat, since that
is only known at the end. The emitter computes lengths (from a
`payload_bytes` input) and the IPv4 checksum; the UDP checksum over the
payload is an input (or 0), as computing it would need store-and-forward.
Co-simulation drives random packets (good, padded, truncated, every kind of
bad header) through the parser and a parser -> emitter loopback under random
backpressure (test/protocol_chain_cosim_test.exs).

Yosys `synth_xilinx` for this chain (33 layouts, 90-byte header register,
40 bytes of IPv4 options as meta output): parser 3635 LUT / 1681 FF at
64 bits and 2876 LUT / 1634 FF at 8 bits, emitter about 3000 LUT / 100 FF.
Variable layouts multiply: every header-length value and repeat count is
one layout, at most 4096.

## Stream kernels in hardware

A kernel `step(sample, state, params..., opts) -> {output, next_state}`
written against `NxFixed.Num` goes through nx_fixed's width check (every
value gets a proven integer range), the recurrence analysis and schedule
(`ExHdl.DSP.analyze_scan/3`) and the SystemVerilog backend:

```elixir
{:ok, design} =
  ExHdl.DSP.scan_to_sv(&ExSdr.DSP.Blocks.one_pole/4, [s, s, s, [format: q15]],
    state: 1, ii: :auto, name: "one_pole", param_names: ["alpha"])
```

The module has AXI4-Stream input and output, one port per parameter
plus `p_load`, signals of their proven widths, DSP48E1 multiplies, block
RAM or LUT ROM tables and the state register closing the loop. One clock
enable drives the whole pipeline; it comes from a two-entry output buffer,
so no ready path is combinational. `p_load` captures new parameter values,
which apply once the samples accepted before have left the pipeline.
Feedback loops longer than one cycle run with `ii: n` (one sample every n
cycles) or `channels: n` (n interleaved streams at one sample per cycle).
The state leaves are split into groups (strongly connected parts of "next
value of leaf i depends on leaf j"), each read and written at its own
stages, so only a group's own loop counts: one biquad section has a loop
of 8 cycles (Zynq timing model at 150 MHz), and so has a cascade of four.

Structures recognised on the lowered kernel (`ExHdl.Backends.SystemVerilog.Fir`),
from value keys `{delay, base}` that see through the kernel's delay line:

  * dot products of constant taps with one signal at several delays: a
    transposed DSP48E1 chain (post-adder, partial sums advance once per
    sample), symmetric or antisymmetric taps folded through the pre-adder,
    zero taps without multiplier; `fir: :tree` keeps the adder tree
  * equal taps (moving averages): a running sum with the delayed input
    from a memory
  * a take with a data-dependent index into a delay line (convolutional
    interleaver): a memory of the line's input, LUT RAM or block RAM
  * outputs that are the input many samples back (delay blocks): a memory

`ExHdl.Block.scan_to_sv/2` generates a `%NxFixed.Block{}` of kind `:stream`
directly (sample templates from the block's item type and format). Blocks
with `rate: {:variable, max}` get `max` output lanes and a count; the
output buffer sends the valid ones one per beat. test/support/block_cases.ex
lists the co-simulated ex_sdr blocks, one line each.

### Many channels

An audio mixer runs 1024 channels through one pipeline at one sample per
cycle. With `channels: n` the state of every channel can live in a memory
instead of registers, and parameters can come per channel from a
coefficient memory the host rewrites at run time:

```elixir
spec = ExHdl.DSP.cascade(for k <- 1..4, do: [fun: &MyAudio.biquad/3, args: args,
  state: 1, init: zero, param_ranges: ranges, param_names: ["coef"], name: "eq#{k}"])

{:ok, design} =
  ExHdl.DSP.scan_to_sv(spec[:fun], spec[:args],
    Keyword.drop(spec, [:fun, :args]) ++
      [name: "eq4", channels: 1024, state_mem: :block, channel_params: :all,
       tid: true, tuser: 16])
```

  * `state_mem: :distributed | :block | :ultra`: one memory word per channel
    and state group (groups read in the same stage share a word), read
    `ram_latency` cycles ahead (1, or 2 for UltraRAM) and written back at the
    group's write stage. No forwarding: the analysis requires `channels` of
    at least the loop latency plus the read latency and reports the
    shortest valid `channels:` otherwise. After reset the memory is cleared
    to `:init`, one word per cycle, while `busy` is high;
    `state_init: :initial` puts `:init` into the initial contents instead.
  * `channel_params: [name] | :all`: those parameter arguments come from a
    memory with two banks of a word per channel, each leaf read at the stage
    of its first use. The host writes the inactive bank (`pc_addr`,
    `pc_data`, `pc_we`, optionally on its own clock with
    `pc_clock: :separate`) and pulses `pc_swap`; the banks swap at the next
    frame boundary (the next sample is channel 0), so every frame sees one
    coefficient set, and `pc_pending` stays high until no sample reading the
    old bank is left in the pipeline.
  * `m_axis_tid` gives every output's channel; `tid: true` takes the channel
    from `s_axis_tid` instead of the arrival order (a frame then starts
    where the channel does not increase); `tuser: bits` carries a sideband
    through the pipeline.

`ExHdl.DSP.cascade/1` composes kernels into one (outputs feed the next
stage's sample, states and parameters are concatenated, port names get the
stage's name as prefix): one pipeline with one clock enable.

### Gathers and the mixer

A crosspoint mixer reads, for every row of an output, `p` source channels
and gains from a table and the samples of those sources from a frame
written by the strip stage. Both are parameters on the BEAM and memories
in hardware (abbreviated; the whole kernel is `ExHdl.Test.Mixer` in
test/support/mixer_kernels.ex):

```elixir
defn xmix({row, {first, last}}, acc, src, gain, frame) do
  x = Nx.take(frame, Nx.take(src, row))          # p reads of the frame
  part = Nx.dot(Nx.as_type(x, :s64), Nx.as_type(Nx.take(gain, row), :s64))
  acc2 = ExHdl.DSP.wrap(Nx.select(first, 0, acc) + part, 48)
  y = shift_round(acc2, 15)
  {{{saturated(y), clip(y)}, last}, acc2}       # one output per frame
end

ExHdl.DSP.scan_to_sv(&xmix/5, args,
  state: 1, param_names: ["src", "gain", "frame"],
  memories: ["src", "gain", "frame"], frame: true, lanes: 1,
  family: :ultrascale_plus, clock_mhz: 250)
```

  * `memories: [name | {name, opts}]` (`ExHdl.IR.Memory`): the parameter
    (`{depth}` or `{depth, row...}`) becomes a RAM, every `Nx.take` element
    a read port with its own copy, `latency:` cycles in the schedule
    (default from the style: LUT RAM 1, block RAM and URAM 2). The write
    port `<name>_waddr`/`_wdata`/`_we` (own clock with `clock: :separate`)
    writes the inactive bank; `<name>_swap` activates it for the next
    sample, `<name>_pending` until the old bank's readers are gone
    (`banks: 1` for a single bank).
  * `frame: true`: the sample ends in `{first, last}`; `last` is
    `s_axis_tlast`, `first` follows it, `m_axis_tlast` marks the output.
    A reduction over a runtime number of rows needs no counter;
    `ExHdl.DSP.frame_flags/1` builds the flags for the reference.
  * `ExHdl.DSP.wrap(x, bits)` is the signed wrap of NxFixed's `wrap/2` for
    any width: the width check proves the accumulator without a clamp,
    and the hardware is wiring, so the loop is one adder and the mixer
    takes one row per cycle. Saturation happens at the output.

The mixer of the AES67 card: 1024 outputs of up to 64 crosspoints, 16 per
row, so a full frame is 4096 rows (of 5208 cycles at 48 kHz and 250 MHz);
outputs with fewer sources take fewer rows. Yosys for UltraScale+:

| Kernel | latency | ii | LUT | FF | DSP48E2 | RAMB18 | URAM |
|---|---|---|---|---|---|---|---|
| mixer, 1024 x 64 crosspoints, 16 per row, 1024 sources | 14 | 1 | 1210 | 3068 | 16 | 48 | 13 |

The tables (two banks of 4096 rows of 16 x 10-bit sources and 16 x 18-bit
gains) are URAM, the 16 copies of the double-buffered frame block RAM.
test/gather_cosim_test.exs runs a small instance (16 sources, 6 outputs
of 1 to 3 rows) with bank swaps of tables and frame mid-stream, against
the Nx reference and an integer model of the mix.

### DSP slices

Products that fit the family's multiplier (25 x 18 on DSP48E1, 27 x 18 on
DSP48E2) take one slice. Wider ones are cut into pieces of one slice each
and summed by a registered adder tree (`Timing.dsp_split/3`): 32 x 24 is
two slices, 32 x 32 four, on both families; the schedule uses the tree's
latency. `Design.dsp` counts the slices; Yosys agrees on every kernel
below. With `ii: n` multiplies of the same size share a unit when their
stages are distinct and within `n` of each other (the unit's inputs are
multiplexed by the stage's valid bit); a multiply outside the feedback
loops is delayed by up to `n - 1` stages to join one (`share: false`
turns it off).

`ExHdl.DSP.msb/2` and `count_leading_zeros/2` (nx_fixed has no
`Nx.count_leading_zeros`) are written as the number of powers of two the
value reaches; that idiom, also ex_audio's `log2_q16`, becomes a priority
encoder instead of comparators and an adder tree.

Yosys `synth_xilinx` for Q15 instances (synthesis only, no I/O buffers,
no timing); latency includes the output buffer:

| Kernel | latency | ii | LUT | FF | DSP48E1 | RAMB18 |
|---|---|---|---|---|---|---|
| ddc (NCO with 1024-entry table, mixer, gain) | 10 | 1 | 224 | 143 | 6 | 1 |
| fir_complex (31 taps, I and Q), adder tree | 10 | 1 | 1324 | 2284 | 50 | 0 |
| fir_complex, DSP chain | 5 | 1 | 45 | 969 | 26 | 0 |
| fir_filter_fff, 63-tap low-pass, adder tree | 11 | 1 | 1212 | 3149 | 46 | 0 |
| fir_filter_fff, 63-tap low-pass, DSP chain | 5 | 1 | 28 | 1417 | 25 | 0 |
| fir_filter_ccf, 63-tap low-pass, adder tree | 11 | 1 | 2414 | 6283 | 92 | 0 |
| fir_filter_ccf, 63-tap low-pass, DSP chain | 5 | 1 | 45 | 2825 | 50 | 0 |
| one_pole | 6 | 5 | 67 | 80 | 1 | 0 |
| one_pole, `channels: 5` | 6 | 1 | 128 | 195 | 1 | 0 |
| moving_average_ff, 1024 | 4 | 1 | 60 | 88 | 0 | 1 |
| delay, 600 samples | 2 | 1 | 30 | 42 | 0 | 1 |
| convolutional interleaver, I = 12, M = 17 | 6 | 1 | 58 | 73 | 1 | 2 |

The FIR chains' remaining flip-flops are the kernel's delay line (needed
by the pre-adder) and the partial sums of zero taps.

ex_audio's direct form I biquad (24-bit samples, 32-bit coefficients and
history, error feedback; a copy is in test/support/audio_kernels.ex), same
flow; with `channels: 1024` both the state and the per-channel coefficient
banks are in RAM. Pipeline delays become SRL shift registers (not counted
as LUT). The products are split (3 of 32 x 24, 2 of 32 x 32: 14 slices)
and the error feedback's wrap is wiring, so a section's loop is 8 cycles
at 150 MHz and at 250 MHz:

| Kernel | latency | ii | LUT | FF | DSP48E1 | RAMB18 |
|---|---|---|---|---|---|---|
| biquad, `ii: :auto` (3 multiplies on one unit) | 17 | 8 | 817 | 1133 | 10 | 0 |
| biquad, `channels: 10`, state in registers | 15 | 1 | 1822 | 3028 | 14 | 0 |
| biquad, `channels: 1024`, `state_mem: :block`, `channel_params: :all` | 16 | 1 | 823 | 751 | 14 | 28 |
| 4 biquads (`ExHdl.DSP.cascade/1`), `ii: :auto` | 62 | 8 | 3214 | 4358 | 40 | 0 |
| 4 biquads, `channels: 1024`, block RAM | 58 | 1 | 3240 | 3013 | 56 | 112 |

The same for UltraScale+ (`family: "xcup"`) with `clock_mhz: 250`:

| Kernel | latency | LUT | FF | DSP48E2 | RAMB18 | URAM |
|---|---|---|---|---|---|---|
| biquad, `channels: 1024`, block RAM | 16 | 817 | 1643 | 14 | 28 | 0 |
| biquad, `channels: 1024`, `state_mem: :ultra` | 17 | 818 | 1817 | 14 | 20 | 3 |
| 4 biquads, `channels: 1024`, `state_mem: :ultra` | 59 | 3224 | 6998 | 56 | 80 | 12 |

The split costs flip-flops: the adder trees of the pieces are registered
per level (about 60 bits each), where Yosys's own mapping used 20 slices
and fewer registers.

The sibling libraries are path dependencies (`../nx_fixed`, and
`../ex_sdr` for integration tests); `scripts/checkout_siblings.sh` clones
them. Requires Elixir 1.18+ and Verilator 5 for co-simulation.

## Frame blocks in hardware

### Polyphase rate change

`ExHdl.Frame.to_sv/2` generates linear `:frame` blocks
(`%NxFixed.Block{kind: :frame}`): decimating and interpolating FIRs,
rational resamplers, polyphase decimators and interpolators, with real or
complex data and taps.

```elixir
block = ExSdr.Filters.block(:fir_filter_ccf, taps: taps, decimation: 4, format: q15)
{:ok, design} = ExHdl.Frame.to_sv(block, name: "decim4")
```

Nothing is known about the block's function: `ExHdl.Frame.analyze/2`
traces the kernel on one period of `d` inputs (`rate: {d, l}`) and
evaluates the Nx graph on affine forms (`ExHdl.Frame.Linear`). It accepts
the kernel when the state is a delay line of the input and every output
is a sum of constant taps times inputs, rounded once (a shift with a
rounding constant) and saturated, with the same rounding in every output
phase. The result (`ExHdl.IR.Multirate`) is `l` tap sets of `k` taps, the
newest input each output phase reads, and the rounding. Kernels with
anything else (the NCO of `freq_xlating_fir_filter`, a product of two
inputs) are rejected with the reason.

`ExHdl.Backends.SystemVerilog.Polyphase` builds one of two structures,
bit-exact with `NxFixed.Block.run/4` under backpressure (AXI4-Stream,
one clock enable from the output buffer, as the stream kernels):

  * decimators (`l = 1`): `ceil(k / d)` multiply-accumulators per term,
    multiplier `j` with the taps `j*d .. j*d + d - 1` in a `d`-entry ROM;
    the partial sums move down the chain once per period (a transposed
    FIR with every tap time-shared `d` times). One input per cycle, no
    delay line.
  * everything else: a window of the last `k` inputs and `k` multipliers
    per term with an `l`-entry coefficient ROM per tap, an adder tree and
    a sequencer that accepts an input or emits an output each cycle. One
    output per cycle for interpolators and upsampling resamplers, one
    input per cycle for downsampling ones.

A term is an input component times a tap set (one for real data, two for
complex data and real taps, four for complex taps); taps that are zero in
every phase have no multiplier. test/frame_cosim_test.exs runs 15 ex_sdr
filters (FIR decimation 2-8, interpolation 2-8, resamplers 3/2, 2/3 and
5/4 with a phase, polyphase decimator on channel 0 and 1) under four
traffic patterns.

Yosys `synth_xilinx` (Zynq-7020), 63-tap low-pass, Q15, complex data:

| Block | structure | latency | LUT | FF | DSP48E1 |
|---|---|---|---|---|---|
| fir_filter_ccf, decimation 4 | decimator | 7 | 58 | 89 | 32 |
| fir_filter_ccf, decimation 8 | decimator | 7 | 89 | 134 | 16 |
| pfb_decimator_ccf, 4 channels, channel 1 (complex taps) | decimator | 7 | 1049 | 957 | 50 |
| interp_fir_filter_ccf, interpolation 4 | direct | 10 | 974 | 1007 | 32 |
| rational_resampler_ccf, 3/2 | direct | 10 | 1319 | 1443 | 42 |
| rational_resampler_ccf, 2/3 | direct | 11 | 1978 | 2015 | 64 |

The decimators' accumulators are the DSP slices' P registers. Downsampling
resamplers use their multipliers `l/d` of the time (a 2/3 resampler with
32 taps per phase has 64); time sharing them is not done yet.

### FFT

`ExHdl.FFT.generate/2` generates a streaming FFT or IFFT of 2 to 65536
points, bit-exact with `ExSdr.DSP.FFT.fft/2` (same options: `:format`,
`:twiddle`, `:shifts`):

```elixir
{:ok, design} =
  ExHdl.FFT.generate(8192, format: NxFixed.Num.q(16, 15), shifts: 13, name: "fft8k")
```

AXI4-Stream with `tdata = {im, re}` and `m_axis_tlast` on the last bin of
every symbol; one sample per clock in and out; symbols back to back or
with gaps, and each symbol leaves without waiting for the next. Options:
`inverse: true` (IFFT as `swap(fft(swap(x)))`, the same butterflies),
`order: :bit_reversed` (no reorder buffer). `ExHdl.FFT.model/2` is an
integer model of the same arithmetic; the moduledoc describes the
interface for composing it with other blocks.

The reference is a radix-2 DIT FFT whose every stage rounds the twiddle
product to the data format and saturates (and halves in the last
`shifts` stages). Radix-2^2 would move twiddle products between stages and
round differently, so the pipeline is radix-2 SDF, one stage per stage of
the reference with its butterflies, twiddles (ROM, the reference's
quantized values) and rounding. The stage takes the input in natural
order and gives the bins in bit-reversed order; a reorder buffer of `n`
words (one memory, frames alternating between natural and bit-reversed
addresses) restores natural order. A stage stores the first half of each
block, combines the second half with it (the sum leaves at once) and
sends the differences in the free cycles after the block, so no stage
needs further input to empty. Stages from 256 words per half keep first
halves and differences in one memory. Stage 0 has no multiplier; every
other stage has four (the quantized `w^0` is `1 - 2^-15`, not 1).

test/fft_test.exs: the model against `ExSdr.DSP.FFT` for 2-1024 points
in four formats (including truncation, 18-bit twiddles, 20-bit data) and
three shift settings, 2048 and 8192 points; Verilator co-simulation of
8, 64 (five configurations, inverse, bit-reversed), 2048 and 8192 points
under four traffic patterns, bit for bit, with `tlast` and throughput.

Yosys `synth_xilinx` (Zynq-7020), Q15 data and twiddles:

| FFT | latency (cycles) | LUT | FF | SRL | DSP48E1 | RAMB36 |
|---|---|---|---|---|---|---|
| 2048 points, natural order | 4173 | 2989 | 3153 | 507 | 40 | 6 |
| 8192 points, natural order | 16475 | 3528 | 3701 | 722 | 48 | 24 |
| 8192 points, bit-reversed order | 8281 | 3488 | 3681 | 722 | 48 | 16 |

Latency is from the last sample of a symbol to its last bin. For 8192
points the memories are 8 RAMB36 for the stages, 8 for the twiddle ROMs
(the reference's table per stage, `n - 1` words in all) and 8 for the
reorder buffer; the twiddle ROMs could shrink by sharing one table
between stages or by symmetry where the quantized values allow it.

## OFDM front end in hardware

`ExHdl.OFDM.*` turns `ExSdr.Comm.OFDM.FixedFrontEnd` (DVB-T 2k, QPSK, 16-QAM
and 64-QAM) into one AXI4-Stream pipeline, bit-exact: sc16 samples in,
code bits out (hard decisions, as ex_sdr produces them; there are no soft
bits in `FixedFrontEnd`).

| Stage | Module | Structure |
|---|---|---|
| frequency correction | `Correct` | stream kernel, state `n * inc mod 2^32`, NCO table, 1 sample per clock |
| guard removal | `Guard` | counter, `tlast` per symbol |
| FFT | `ExHdl.FFT` (hdl/frame) | composition point below |
| channel estimate, equaliser, decisions | `Equalise`, `Equaliser`, `Plan` | frame kernel, double-buffered symbol RAM |
| symbol and bit deinterleaver | `Permute` | double-buffered RAM, address ROM, any gather table |
| bit unpacking | `Unpack` | |

`Permute` is the generic frame permutation (`ExSdr.Comm.Permutation`
tables, several tables used in turn): one item per clock in and out, a
bank is read while the other is written, `tlast` per block.

The equaliser needs the whole symbol, so it is a stream kernel with a
frame memory (`memories:`): a writer fills the inactive bank with the FFT
output, a sequencer sends row numbers of a schedule (`Plan`) through the
kernel, one per clock. The schedule walks a symbol in interpolation order
(pilot, pilot, the data carriers between them, next pilot, ...), so every
pilot's channel estimate is computed once and shifted through two state
registers. The kernel uses the nx_fixed operations of `FixedFrontEnd`
unchanged (same constants, rounding, saturation), the width check proves
every width, and the loop is one cycle (`ii = 1`).

test/ofdm: each stage against the stage of `FixedFrontEnd` cut out in
test/support/ofdm_ref.ex (whose chain equals `FixedFrontEnd.run/4`, checked
first), then the chain with the software FFT and with `ExHdl.FFT` in the
design, on ExSdr's DVB-T transmitter output with a carrier offset and
noise, random valid and ready.

### FFT composition point

Two AXI4-Stream connections, `tdata = {im[15:0], re[15:0]}` signed in the
data format (q(16, 12)): `fft_in` carries the corrected symbol without
guard (2048 beats, `tlast` on the last), `fft_out` takes the 2048 bins in
natural order. The FFT must be `ExSdr.DSP.FFT.fft/2` with `shifts: 5`
and q(16, 15) twiddles, which `ExHdl.FFT` is. `FrontEnd.build(spec, fft:
:hardware)` instantiates it, `fft: nil` leaves the ports open.

Yosys `synth_xilinx` (Zynq-7020), DVB-T 2k:

| Block | latency | LUT | FF | DSP48E1 | RAMB18 |
|---|---|---|---|---|---|
| Correct | 8 | 269 | 261 | 4 | 4 |
| Equaliser QPSK | 19 | 616 | 592 | 8 | 20 |
| Equaliser 16-QAM | 23 | 831 | 763 | 14 | 20 |
| Equaliser 64-QAM | 24 | 1055 | 844 | 18 | 20 |
| Guard (2048 + 64) | 2 | 47 | 80 | 0 | 0 |
| Cell deinterleaver (1512 x 2 bit, two tables) | n + 4 | 53 | 53 | 0 | 3 |
| Bit deinterleaver QPSK / 16-QAM / 64-QAM | n + 4 | 54 / 87 / 286 | 47 / 51 / 55 | 0 | 1 |
| Front end QPSK without FFT | | 1067 | 1044 | 12 | 28 |
| Front end QPSK with `ExHdl.FFT` | | 4054 | 4237 | 52 | 40 |

A symbol takes 1688 equaliser rows (176 pilots, 1512 data carriers) of
the 2048 clocks of its FFT output.

### Limits and what ex_sdr would need

* The first sample after reset is the start of a guard interval of a
  class 0 symbol (`FixedFrontEnd.run/4` has the same rule); cell tables
  start with table 0. No synchroniser yet.
* `FixedFrontEnd` exposes only the final bits. The tests copy its private
  `graph/5` and `class_words/6` (test/support/ofdm_ref.ex). The minimal
  ex_sdr refactor: make `nco/2`, `class_words/6` and `axis_index/3` public
  (or a `stages/…` function returning corrected samples, FFT output and
  words), so the hardware tests compare against the library instead of a
  copy. `ExHdl.OFDM.Plan` rebuilds the pilot and weight constants from
  `spec.ofdm` as `tables/3` does (float32 first); a public per-class table
  function would remove that duplication. Nothing in ex_sdr was changed.
