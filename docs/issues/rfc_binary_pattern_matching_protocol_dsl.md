# RFC / Issue: Idiomatic Binary Pattern Matching DSL for `ExHdl.Protocol`

## Status

Phase 1 is done, in a different shape than sketched below: headers are
real Elixir patterns (`defheader :udp, <<src_port::16, ...>>, dst_port:
[match: 4]`), not bitstrings with invented modifiers such as
`x::16 - type(...)` or pseudo-guards such as `header_checksum(c)`, which
no BEAM code can use. Constants are `field == value` guards, the IPv4 tail
is `options::binary-size(ihl * 4 - 20)`, and everything a pattern cannot
say is a per-field keyword list. Each header gets `match_name/1`, the
pattern compiled as a function head. See `ExHdl.Protocol.Bitstring`.

## Summary

Refactor and extend `ExHdl.Protocol` to support standard Elixir binary pattern matching syntax (`<<...>>`) for protocol definitions alongside the existing `field`/`layer` macro syntax. This allows developers to declare packet protocols using idiomatic Elixir patterns (matching ecosystem norms such as Nerves and Erlang/OTP) while compiling to both zero-copy BEAM software codecs and synthesizable SystemVerilog AXI4-Stream hardware.

---

## Background & Problem Statement

Currently, `ExHdl.Protocol` uses an explicit macro-based syntax:

```elixir
defheader :eth do
  field :dst, 48
  field :src, 48
  field :ethertype, 16, type: {:enum, vlan: 0x8100, qinq: 0x88A8, ipv4: 0x0800}
end
```

While this design clearly reflects P4-style parser DAGs, it differs significantly from how binary protocols are expressed across the broader Elixir ecosystem (e.g. Nerves, `pkt`, `Circuits.UART`):

```elixir
# Idiomatic Elixir pattern matching
def parse_eth(<<dst::48, src::48, ethertype::16, rest::binary>>)
```

### Limitations of Current Approach
1. **Ecosystem Divergence**: Existing protocol specs and knowledge from Nerves/embedded Elixir cannot be copied or shared directly without rewriting them into `field` calls.
2. **Codec Overhead on BEAM**: [`ExHdl.Protocol.Codec.parse_fixed/3`](file:///home/marc/Projects/exhdl/lib/ex_hdl/protocol/codec.ex) dynamically reduces over field lists using `<<v::size(f.bits), rest::bitstring>> = rest` instead of unrolling into a single native pattern match compiled by the BEAM JIT.
3. **Redundant Declarations**: Assertions and branch selectors (`assert: 4`, `17 => :udp`) require separate options instead of natural literal matches (`4::4`, `17::8`).

---

## Proposed Architecture & Design

### Phase 1: Native Bitstring Syntax in `defheader`
Allow `defheader` to accept Elixir bitstring syntax (`<<...>>`) directly:

```elixir
defheader :eth do
  <<
    dst::48,
    src::48,
    ethertype::16(type: {:enum, vlan: 0x8100, qinq: 0x88A8, ipv4: 0x0800})
  >>
end

defheader :ipv4 do
  <<
    version::4-assert(4),
    ihl::4-header_length(4),
    dscp_ecn::8,
    total_length::16-length(:total),
    id::16,
    flags_frag::16,
    ttl::8,
    protocol::8,
    checksum::16-checksum(:header),
    src::32,
    dst::32,
    options::binary
  >>
end
```

* **AST Parsing**: An AST walker parses `{:"::", meta, [name, spec]}` to construct `ExHdl.Protocol.Field` structs.
* **Backward Compatibility**: Fully compatible with existing `field/2,3` declarations.

---

### Phase 2: Clause-Based Protocol Matching (`defpacket_clause`)
Support defining whole packet chains as single or multi-clause pattern-matching heads:

```elixir
defpacket_clause parse_packet(<<
  # Ethernet
  dst::48,
  src::48,
  0x0800::16,

  # IPv4
  4::4,
  ihl::4,
  _dscp_ecn::8,
  total_len::16,
  _id_frag::32,
  _ttl::8,
  17::8,
  csum::16,
  src_ip::32,
  dst_ip::32,

  # UDP
  src_port::16,
  dst_port::16,
  udp_len::16,
  udp_csum::16,

  payload::binary
>>) when header_checksum(csum) and hw_match(dst_port, table_size: 4)
```

* **Literals as Asserts**: Literal values (`0x0800::16`, `4::4`, `17::8`) automatically become assertion/branch conditions in hardware.
* **Guards as Hardware Directives**: Hardware-specific features (`checksum: :header`, `match: n`) are declared as guards (`when header_checksum(...)`).
* **Wildcards**: Prefix `_` fields are treated as unexposed/ignored header bytes.

---

### Phase 3: JIT-Compiled BEAM Software Codecs
Update [`ExHdl.Protocol`](file:///home/marc/Projects/exhdl/lib/ex_hdl/protocol.ex) code generation:
* Instead of calling dynamic runtime walkers, compile `decode_<name>` into a single native Elixir binary pattern match clause.
* Benchmark software decoding throughput on BEAM against current codec implementation.

---

## Verification & Acceptance Criteria

1. **AST Compatibility**: Existing tests in [`test/protocol_chain_codec_test.exs`](file:///home/marc/Projects/exhdl/test/protocol_chain_codec_test.exs) pass without modification.
2. **Bitstring Header Tests**: New unit tests demonstrating headers defined via `<<...>>` produce identical [`%ExHdl.Protocol.Spec{}`](file:///home/marc/Projects/exhdl/lib/ex_hdl/protocol/spec.ex) structs as `field/2,3`.
3. **Hardware Emission**: Running `ExHdl.Backends.SystemVerilog.Protocol.emit/1` on bitstring-defined protocols produces identical SystemVerilog parser/emitter code.
4. **Verilator Co-simulation**: Co-simulation tests (`mix test --only verilator`) pass bit-identically between the generated SystemVerilog and the Elixir reference parser.
