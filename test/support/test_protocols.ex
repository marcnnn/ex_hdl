defmodule ExHdl.Test.Protocols do
  @moduledoc false
  use ExHdl.Protocol

  # The iq_frame from the architecture plan: 4 header words on a 32-bit bus.
  defpacket :iq_frame, bus_width: 32, byte_order: :little do
    header <<magic::16-little, channel_id::8, flags::8, gain_q15::16-little-signed,
             seq_num::16-little, timestamp::64-little>>
           when magic == 0x55AA,
           on_mismatch: :drop_packet

    payload(:stream, type: {:complex, :s16})
  end

  # Big-endian bit fields (IPv6-like), single header word on a 64-bit bus,
  # byte payload so the last beat can have a partial tkeep.
  defpacket :be_frame, bus_width: 64, byte_order: :big do
    header <<version::4, tclass::8, flow::20, len::16, next::8, hops::8-signed>>
           when version == 6

    payload(:data, type: :u8)
  end

  # 5-byte header on a 32-bit bus: the payload starts in lane 1.
  defpacket :odd_frame, bus_width: 32 do
    header <<kind::4, urgent::1, tag::3, seq::32>> when tag == 5,
      kind: [type: {:enum, data: 1, ctrl: 2}],
      urgent: [type: :flag]

    payload(:words, type: :u16)
  end
end

defmodule ExHdl.Test.NetProtocols do
  @moduledoc false
  # The AES67 receive chain: Ethernet, up to two VLAN tags, IPv4 with
  # options, UDP with a runtime port table, on 8, 32 and 64-bit buses.
  use ExHdl.Protocol

  @ethertypes {:enum, vlan: 0x8100, qinq: 0x88A8, ipv4: 0x0800}

  defheader :eth, <<dst::48, src::48, ethertype::16>>, ethertype: [type: @ethertypes]

  defheader :vlan, <<pcp::3, dei::1, vid::12, ethertype::16>>,
    dei: [type: :flag],
    ethertype: [type: @ethertypes]

  defheader :ipv4,
            <<version::4, ihl::4, dscp::6, ecn::2, total_length::16, id::16, reserved::1, df::1,
              mf::1, frag_offset::13, ttl::8, protocol::8, checksum::16, src::32, dst::32,
              options::binary-size(ihl * 4 - 20)>>
            when version == 4,
            version: [error: :not_ipv4],
            total_length: [length: :total],
            df: [type: :flag],
            mf: [type: :flag],
            protocol: [type: {:enum, udp: 17}],
            checksum: [checksum: :header]

  defheader :udp, <<src_port::16, dst_port::16, length::16, checksum::16>>,
    dst_port: [match: 4],
    length: [length: :total],
    checksum: [
      checksum: :segment,
      optional: true,
      pseudo: [{:ipv4, :src}, {:ipv4, :dst}, {:ipv4, :protocol}, :length]
    ]

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
