# RFC / Issue: First-Class Arbitrary Bit-Width Integer Types in `NxFixed` & `ExHdl`

## Summary

Extend the `NxFixed` and `ExHdl` type systems to support first-class arbitrary bit-width signed and unsigned integer types (e.g. `{:s, 18}`, `{:s, 24}`, `{:u, 12}`, `{:s, 48}`) instead of relying on standard primitive Nx containers (`:s32`, `:s64`) annotated by out-of-band `param_ranges:` maps. This simplifies `defn` stream kernels, eliminates artificial type promotions, and allows hardware signal widths to be declared and inferred directly from Elixir type definitions.

---

## Background & Problem Statement

Currently, when writing stream kernels for `ExHdl.DSP.scan_to_sv/3` (such as [`ExHdl.Test.Mixer.xmix/5`](file:///home/marc/Projects/exhdl/test/support/mixer_kernels.ex#L18-L33)), developers must work around standard Nx type restrictions:

```elixir
defn xmix(sample, acc, src, gain, frame) do
  # ...
  # Cast to standard Nx :s64 to avoid overflow during pure Elixir execution
  part = Nx.dot(Nx.as_type(x, :s64), Nx.as_type(g, :s64))
  base = Nx.select(first, Nx.tensor(0, type: :s64), acc)
  acc2 = ExHdl.DSP.wrap(base + part, 48)
  # ...
end
```

The actual hardware signal widths (e.g., 18-bit gain, 24-bit audio samples, 10-bit source indices) must then be declared in a separate, out-of-band `param_ranges` keyword option:

```elixir
def param_ranges(rows, n_in) do
  %{
    3 => -(1 <<< 47)..((1 <<< 47) - 1),   # 48-bit accumulator
    4 => 0..(n_in - 1),                   # 10-bit source address
    5 => -(1 <<< 17)..((1 <<< 17) - 1),   # 18-bit signed gain
    6 => -(1 <<< 23)..((1 <<< 23) - 1)    # 24-bit signed audio
  }
end
```

### Limitations of Current Approach

1. **Disconnected Specifications**: The kernel body uses `:s64` while the hardware compiler relies on an indexed map of ranges. If argument positions change, `param_ranges` indices break silently.
2. **Artificial Promoted Widths**: Using `:s64` in `defn` can cause conservative width analysis to infer wider multipliers (e.g. splitting into multiple DSP slices via `Timing.dsp_split/3`) unless clamped by `wrap/2` or `param_ranges`.
3. **Inability to Express Custom Quantized Types**: Custom types like logarithmic gain codes (`u8_log`) or non-standard DSP widths (`s18`, `s27`) are treated as opaque integers rather than types with semantic range and precision.

Because `nx_fixed` is authored and maintained in-house, the type definitions, templates, and arithmetic rules can be extended to support arbitrary bit-widths natively.

---

## Proposed Architecture & Design

### Phase 1: Arbitrary Bit-Width Integer Types in `NxFixed`

Introduce arbitrary-width type tuples:
* `{:s, bits}` — Signed two's complement integer of width `bits` (e.g. `{:s, 18}`, `{:s, 24}`, `{:s, 48}`).
* `{:u, bits}` — Unsigned integer of width `bits` (e.g. `{:u, 10}`, `{:u, 12}`).
* Support them in `NxFixed.template/2` and `Nx.template/2` type specifications:
  ```elixir
  # Audio frame buffer of 24-bit signed samples
  frame = NxFixed.template({1024}, {:s, 24})

  # Gain table of 18-bit signed coefficients
  gain = NxFixed.template({rows, p}, {:s, 18})

  # Source index table of 10-bit unsigned addresses
  src = NxFixed.template({rows, p}, {:u, 10})
  ```

### Phase 2: In-Graph Range & Width Propagation

Update `NxFixed.analyze_expr/2`:
* Whenever a parameter node has a type `{:s, n}` or `{:u, n}`, automatically assign its initial range as:
  * `{:s, n}` $\rightarrow [-(2^{n-1}), 2^{n-1} - 1]$
  * `{:u, n}` $\rightarrow [0, 2^n - 1]$
* Propagate bit widths through arithmetic operations (`+`, `-`, `*`, `Nx.dot`, `Nx.take`, shifts) without requiring artificial `Nx.as_type(..., :s64)` promotions.
* Direct overflow semantics: support wrapping and saturation as type attributes or explicit operators.

### Phase 3: Hardware Lowering in `ExHdl.DSP` & Backends

Update `ExHdl.DSP.analyze_scan/3` and `ExHdl.Backends.SystemVerilog`:
* Generate port and wire declarations directly using exact bit ranges (`logic signed [17:0] gain`, `logic signed [23:0] frame`).
* Automatically detect when a multiply fits directly within the target family's hardware DSP slice (e.g., $24 \times 18$ fits in a single UltraScale+ DSP48E2 $27 \times 18$ multiplier) without manual range annotations.
* Deprecate the requirement for `param_ranges:` when inputs are typed with `{:s, n}` / `{:u, n}`.

---

## Verification & Acceptance Criteria

1. **Template & Type Compatibility**: `NxFixed.template` accepts arbitrary `{:s, n}` and `{:u, n}` widths and reports accurate range bounds.
2. **Kernel Range Inference**: Kernels defined with arbitrary-width templates pass `ExHdl.DSP.analyze_scan/3` without needing a `param_ranges:` option.
3. **Multiplier Sizing**: A product of `{:s, 24}` and `{:s, 18}` infers a single DSP48E2 slice for `:ultrascale_plus` without intermediate splits.
4. **Backward Compatibility**: Existing kernels using standard types (`:s32`, `:s64`) and `param_ranges:` continue to pass all tests in [`test/dsp_features_test.exs`](file:///home/marc/Projects/exhdl/test/dsp_features_test.exs).
