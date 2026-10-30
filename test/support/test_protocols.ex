defmodule ExHdl.Test.Protocols do
  @moduledoc false
  use ExHdl.Protocol

  # The iq_frame from the architecture plan: 4 header words on a 32-bit bus.
  defpacket :iq_frame, bus_width: 32, byte_order: :little do
    header on_mismatch: :drop_packet do
      <<
        magic::16 - assert(0x55AA),
        channel_id::8 - type(:u8),
        flags::8 - type(:u8),
        gain_q15::16 - type(:s16),
        seq_num::16 - type(:u16),
        timestamp::64 - type(:u64)
      >>
    end

    payload(:stream, type: {:complex, :s16})
  end

  # Big-endian bit fields (IPv6-like), single header word on a 64-bit bus,
  # byte payload so the last beat can have a partial tkeep.
  defpacket :be_frame, bus_width: 64, byte_order: :big do
    header do
      <<
        version::4 - assert(6),
        tclass::8,
        flow::20,
        len::16,
        next::8,
        hops::8 - type(:s8)
      >>
    end

    payload(:data, type: :u8)
  end

  # 5-byte header on a 32-bit bus: the payload starts in lane 1.
  defpacket :odd_frame, bus_width: 32 do
    header do
      <<
        kind::4 - type({:enum, data: 1, ctrl: 2}),
        urgent::1 - flag,
        tag::3 - assert(5),
        seq::32
      >>
    end

    payload(:words, type: :u16)
  end
end

defmodule ExHdl.Test.NetProtocols do
  @moduledoc false
  # The AES67 receive chain: Ethernet, up to two VLAN tags, IPv4 with
  # options, UDP with a runtime port table, on 8, 32 and 64-bit buses.
  use ExHdl.Protocol

  defheader :eth do
    <<
      dst::48,
      src::48,
      ethertype::16 - type({:enum, vlan: 0x8100, qinq: 0x88A8, ipv4: 0x0800})
    >>
  end

  defheader :vlan do
    <<
      pcp::3,
      dei::1 - flag,
      vid::12,
      ethertype::16 - type({:enum, vlan: 0x8100, qinq: 0x88A8, ipv4: 0x0800})
    >>
  end

  defheader :ipv4 do
    <<
      version::4 - assert(4) - error(:not_ipv4),
      ihl::4 - header_length(4),
      dscp::6,
      ecn::2,
      total_length::16 - length(:total),
      id::16,
      reserved::1,
      df::1 - flag,
      mf::1 - flag,
      frag_offset::13,
      ttl::8,
      protocol::8 - type({:enum, udp: 17}),
      checksum::16 - checksum(:header),
      src::32,
      dst::32,
      options::bytes
    >>
  end

  defheader :udp do
    <<
      src_port::16,
      dst_port::16 - match(4),
      length::16 - length(:total),
      checksum::16 - checksum(:segment,
        optional: true,
        pseudo: [{:ipv4, :src}, {:ipv4, :dst}, {:ipv4, :protocol}, :length]
      )
    >>
  end

  for w <- [8, 32, 64] do
    defpacket :"udp#{w}", bus_width: w do
      layer(:eth, next: {:ethertype, vlan: :vlan, qinq: :vlan, ipv4: :ipv4})
      layer(:vlan, max: 2, next: {:ethertype, vlan: :vlan, ipv4: :ipv4})
      layer(:ipv4, next: {:protocol, udp: :udp})
      layer(:udp)
      payload(:data, type: :bytes)
    end
  end

  # 14-byte header on a 64-bit bus: payload starts in lane 6. Unknown
  # EtherTypes pass with the payload right after the Ethernet header.
  defpacket :eth_iq, bus_width: 64 do
    layer(:eth, next: {:ethertype, vlan: :vlan}, default: :payload)
    layer(:vlan, max: 1, next: {:ethertype, %{}}, default: :payload)
    payload(:samples, type: {:complex, :s16})
  end
end
