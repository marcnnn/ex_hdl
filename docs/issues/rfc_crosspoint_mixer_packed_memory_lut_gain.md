# RFC / Issue: Memory-Optimized Crosspoint Mixer with Packed 24-bit Entries & Distributed LUT Gain ROM

## Summary

Update the stream-kernel crosspoint mixer ([`ExHdl.Test.Mixer`](file:///home/marc/Projects/exhdl/test/support/mixer_kernels.ex#L1-L75)), documentation ([`README.md`](file:///home/marc/Projects/exhdl/README.md#L240-L280)), and co-simulation tests ([`test/gather_cosim_test.exs`](file:///home/marc/Projects/exhdl/test/gather_cosim_test.exs)) to align with the memory-optimized FPGA architecture implemented in the AES67 intercom gateware ([`matrix_mixer.vhd`](file:///home/marc/Projects/AES67/FPGA/intercom/rtl/matrix_mixer.vhd)). The updated design packs crosspoint table entries into 24-bit words (source channel, flags, and 8-bit log gain) and uses an on-the-fly distributed LUT ROM expansion (`GAIN_ROM`) to preserve scarce FPGA Block RAM and URAM.

---

## Background & Motivation

In large matrix mixers (e.g., $1024 \times 64 = 65,536$ crosspoints, or up to $4096 \times 64$ in the 10G scaling plan), the crosspoint table is by far the largest memory consumer on the chip. On parts like the XCKU3P (which has ~13.5 Mbit total memory), spending 32 bits per crosspoint or storing full linear gains in BRAM/URAM consumes an excessive fraction of the memory budget.

### The Proven AES67 Optimization

The hardware design in [`matrix_mixer.vhd`](file:///home/marc/Projects/AES67/FPGA/intercom/rtl/matrix_mixer.vhd) solves this through a trade-off between distributed logic and block memory:

1. **24-bit Packed Word**:
   - `[11:0]`: Source channel address (supports up to 4096 inputs)
   - `[14]`: Invert flag (negates the coefficient for phase inversion)
   - `[15]`: Enable flag
   - `[23:16]`: **8-bit logarithmic gain code** ($0.5\text{ dB}$ per step, with code 231 representing $0\text{ dB}$ unity gain, and code 0 representing mute)
2. **Distributed LUT ROM Expansion**:
   - The 8-bit log gain is converted to a 16-bit signed linear Q3.13 coefficient via a 256-entry lookup table (`GAIN_ROM`).
   - Because `GAIN_ROM` is only $256 \times 16$ ($4\text{ Kbit}$), it maps to **distributed LUT ROM (~130 LUT6 per lane)** rather than BRAM/URAM.
   - The LUT lookup replaces an existing register in the pipeline stage, adding **zero additional pipeline cycles**.

### Limitations of Current `ExHdl` Example

The current `xmix` example in `exhdl`:
- Uses separate, uncompressed memories for `src` (channel indices) and `gain` (18-bit linear Q3.15 coefficients).
- Omits the log-to-linear conversion and packed bitfields.
- Presents an abbreviated sketch in `README.md` that does not reflect the memory-saving architecture required to fit 1024 or 4096 channels onto actual hardware.

---

## Proposed Architecture & Design

### Phase 1: Packed Crosspoint Entry Representation

Define the packed 24-bit crosspoint format in Elixir:
```elixir
defmodule ExHdl.Mixer.Entry do
  import Bitwise

  @gain_code_unity 231
  @gain_step_db 0.5

  # Pack 12b source, invert, enable, 8b log gain code
  def pack(src, gain_code, opts \\ []) do
    inv = if Keyword.get(opts, :invert, false), do: 1 <<< 14, else: 0
    en = if Keyword.get(opts, :enable, true), do: 1 <<< 15, else: 0
    (src &&& 0xFFF) ||| inv ||| en ||| ((gain_code &&& 0xFF) <<< 16)
  end

  def unpack(word) do
    src = word &&& 0xFFF
    inv = (word &&& (1 <<< 14)) != 0
    en = (word &&& (1 <<< 15)) != 0
    gain_code = (word >>> 16) &&& 0xFF
    {src, gain_code, inv, en}
  end
end
```

### Phase 2: `GAIN_ROM` Generation & LUT Memory Specification

Generate the $256 \times 16$ Q3.13 table at compilation time and expose it as a `:distributed` memory:
* `build_gain_rom/0`: Generates the 256 signed 16-bit linear coefficients.
* In `ExHdl.DSP.scan_to_sv/3`, declare:
  ```elixir
  memories: [
    {"xp", style: :ultra, banks: 2},           # Packed 24-bit crosspoint table (URAM)
    {"frame", style: :block, banks: 2},        # 24-bit audio frame buffer (BRAM)
    {"gain_rom", style: :distributed, latency: 1} # 256x16 log-to-linear expansion (LUT ROM)
  ]
  ```

### Phase 3: Update `xmix` Kernel Implementation

Update the `xmix` `defn` in [`ExHdl.Test.Mixer`](file:///home/marc/Projects/exhdl/test/support/mixer_kernels.ex#L1-L35):
1. Read the packed entry from `xp` memory for row `row`.
2. Extract source index `src = entry &&& 0xFFF` and log gain code `gain_code = (entry >>> 16) &&& 0xFF`.
3. Gather source audio sample `x = Nx.take(frame, src)`.
4. Lookup linear coefficient `g = Nx.take(gain_rom, gain_code)`.
5. Conditionally invert `g` if bit 14 is set; multiply $x \times g$ and accumulate in 48-bit `acc`.
6. Round and saturate output on the last row of the channel.

### Phase 4: Documentation & Co-Simulation Updates

* **README Update**: Update the `### Gathers and the mixer` section in [`README.md`](file:///home/marc/Projects/exhdl/README.md#L240-L280) to explain the packed 24-bit memory format, the LUT `GAIN_ROM` expansion, and the exact BRAM/URAM savings.
* **Co-simulation**: Update [`test/gather_cosim_test.exs`](file:///home/marc/Projects/exhdl/test/gather_cosim_test.exs) to test packed entry generation, log-gain lookup, and bit-exact agreement against the integer reference model under Verilator.

---

## Verification & Acceptance Criteria

1. **Memory Inference**: Yosys synthesis (`mix ex_hdl.gen.sv --synth`) confirms `gain_rom` infers distributed LUTs (~130 LUT6 per lane) and does not consume Block RAM / URAM.
2. **Crosspoint Compression**: Total crosspoint memory width drops from separate 32b/18b tables down to a single 24-bit wide memory.
3. **Bit-Exact Co-Simulation**: `mix test --only verilator` passes bit-for-bit against the Elixir integer reference model with randomized log gains, phase inversions, and bank swaps mid-stream.
4. **Latency Verification**: The schedule in `ExHdl.Passes.Recurrence` verifies that the `gain_rom` LUT lookup is folded into the pipeline without increasing loop latency (`ii == 1`).
