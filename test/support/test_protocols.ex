defmodule ExHdl.Test.Protocols do
  @moduledoc false
  use ExHdl.Protocol

  # The iq_frame from the architecture plan: 4 header words on a 32-bit bus.
  defpacket :iq_frame, bus_width: 32, byte_order: :little do
    header on_mismatch: :drop_packet do
      field(:magic, 16, assert: 0x55AA)
      field(:channel_id, 8, type: :u8)
      field(:flags, 8, type: :u8)
      field(:gain_q15, 16, type: :s16)
      field(:seq_num, 16, type: :u16)
      field(:timestamp, 64, type: :u64)
    end

    payload(:stream, type: {:complex, :s16})
  end

  # Big-endian bit fields (IPv6-like), single header word on a 64-bit bus,
  # byte payload so the last beat can have a partial tkeep.
  defpacket :be_frame, bus_width: 64, byte_order: :big do
    header do
      field(:version, 4, assert: 6)
      field(:tclass, 8)
      field(:flow, 20)
      field(:len, 16)
      field(:next, 8)
      field(:hops, 8, type: :s8)
    end

    payload(:data, type: :u8)
  end
end
