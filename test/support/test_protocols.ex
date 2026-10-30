defmodule ExHdl.Test.Protocols do
  @moduledoc false
  use ExHdl.Protocol

  # The iq_frame from the architecture plan: 4 header words on a 32-bit bus.
  defpacket :iq_frame, bus_width: 32, byte_order: :little do
    header on_mismatch: :drop_packet do
      <<
        magic::16,
        channel_id::8 - type(:u8),
        flags::8 - type(:u8),
        gain_q15::16 - type(:s16),
        seq_num::16 - type(:u16),
        timestamp::64 - type(:u64)
      >>
      when magic == 0x55AA
    end

    payload(:stream, type: {:complex, :s16})
  end

  # Big-endian bit fields (IPv6-like), single header word on a 64-bit bus,
  # byte payload so the last beat can have a partial tkeep.
  defpacket :be_frame, bus_width: 64, byte_order: :big do
    header do
      <<
        version::4,
        tclass::8,
        flow::20,
        len::16,
        next::8,
        hops::8 - type(:s8)
      >>
      when version == 6
    end

    payload(:data, type: :u8)
  end

  # 5-byte header on a 32-bit bus: the payload starts in lane 1.
  defpacket :odd_frame, bus_width: 32 do
    header do
      <<
        kind::4 - type({:enum, data: 1, ctrl: 2}),
        urgent::1 - flag,
        tag::3,
        seq::32
      >>
      when tag == 5
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
      version::4,
      ihl::4,
      dscp::6,
      ecn::2,
      total_length::16,
      id::16,
      reserved::1,
      df::1,
      mf::1,
      frag_offset::13,
      ttl::8,
      protocol::8,
      checksum::16,
      src::32,
      dst::32,
      options::bytes
    >>
    when version == 4 and
         error(version, :not_ipv4) and
         header_length(ihl, 4) and
         length(total_length, :total) and
         flag(df) and
         flag(mf) and
         type(protocol, {:enum, udp: 17}) and
         header_checksum(checksum)
  end

  defheader :udp do
    <<
      src_port::16,
      dst_port::16,
      length::16,
      checksum::16
    >>
    when hw_match(dst_port, 4) and
         length(length, :total) and
         segment_checksum(checksum,
           optional: true,
           pseudo: [{:ipv4, :src}, {:ipv4, :dst}, {:ipv4, :protocol}, :length]
         )
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
