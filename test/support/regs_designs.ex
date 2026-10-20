defmodule ExHdl.Test.MixerRegs do
  @moduledoc false
  # A register map using every access type, an array, strobes and two
  # memory windows with different latencies.
  use ExHdl.Regs

  defregs "mixer_regs", doc: "Test map" do
    register :id, doc: "Identification" do
      field(:version, 0..15, :ro, const: 0x0102)
      field(:channels, 16..23, :ro)
    end

    register :ctrl, strobe: :write, doc: "Control" do
      field(:enable, 0, :rw, reset: 1, doc: "Mixer running")
      field(:mode, 1..2, :rw, enum: [off: 0, mono: 1, stereo: 2])
      field(:gain, 4..19, :rw, reset: 0x4000, doc: "Master gain, spans three byte lanes")
      field(:start, 31, :wo)
    end

    register :irq, offset: 0x10, strobe: :both do
      field(:overflow, 0, :w1c)
      field(:underrun, 1..3, :w1c)
      field(:arm, 8..9, :w1s)
      field(:events, 16..23, :rc)
    end

    register :level, count: 4, stride: 8 do
      field(:value, 0..23, :rw, reset: 0x10)
      field(:mute, 31, :rw)
    end

    window(:coeffs, offset: 0x100, size: 0x40, latency: 1, doc: "Coefficient RAM")
    window(:lut, size: 0x20, latency: 3)
  end
end
