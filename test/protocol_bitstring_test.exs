defmodule ExHdl.ProtocolBitstringTest do
  use ExUnit.Case, async: true
  use ExHdl.Protocol

  defheader :eth_macro do
    field(:dst, 48)
    field(:src, 48)
    field(:ethertype, 16, type: {:enum, vlan: 0x8100, qinq: 0x88A8, ipv4: 0x0800})
  end

  defheader :eth_bits do
    <<
      dst::48,
      src::48,
      ethertype::16 - type({:enum, vlan: 0x8100, qinq: 0x88A8, ipv4: 0x0800})
    >>
  end

  defheader :ipv4_macro do
    field(:version, 4, assert: 4, error: :not_ipv4)
    field(:ihl, 4, header_length: 4)
    field(:dscp, 6)
    field(:ecn, 2)
    field(:total_length, 16, length: :total)
    field(:id, 16)
    field(:reserved, 1)
    field(:df, 1, type: :flag)
    field(:mf, 1, type: :flag)
    field(:frag_offset, 13)
    field(:ttl, 8)
    field(:protocol, 8, type: {:enum, udp: 17})
    field(:checksum, 16, checksum: :header)
    field(:src, 32)
    field(:dst, 32)
    field(:options, :bytes)
  end

  defheader :ipv4_bits do
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

  defheader :ipv4_guarded do
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

  defheader :udp_macro do
    field(:src_port, 16)
    field(:dst_port, 16, match: 4)
    field(:length, 16, length: :total)

    field(:checksum, 16,
      checksum: :segment,
      optional: true,
      pseudo: [{:ipv4, :src}, {:ipv4, :dst}, {:ipv4, :protocol}, :length]
    )
  end

  defheader :udp_bits do
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

  defheader :udp_guarded do
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

  defpacket :pkt_macro, bus_width: 64 do
    layer(:eth, header: :eth_macro, next: {:ethertype, ipv4: :ipv4})
    layer(:ipv4, header: :ipv4_macro, next: {:protocol, udp: :udp})
    layer(:udp, header: :udp_macro)
    payload(:data, type: :bytes)
  end

  defpacket :pkt_bits, bus_width: 64 do
    layer(:eth, header: :eth_bits, next: {:ethertype, ipv4: :ipv4})
    layer(:ipv4, header: :ipv4_bits, next: {:protocol, udp: :udp})
    layer(:udp, header: :udp_bits)
    payload(:data, type: :bytes)
  end

  defpacket :pkt_guarded, bus_width: 64 do
    layer(:eth, header: :eth_bits, next: {:ethertype, ipv4: :ipv4})
    layer(:ipv4, header: :ipv4_guarded, next: {:protocol, udp: :udp})
    layer(:udp, header: :udp_guarded)
    payload(:data, type: :bytes)
  end

  defpacket :flat_bits, bus_width: 32 do
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

  defpacket :assignment_assert_bits, bus_width: 32 do
    header do
      <<
        (version = 4)::4,
        ihl::4,
        tos::8,
        len::16
      >>
    end

    payload(:data, type: :bytes)
  end

  test "bitstring header definitions produce identical field specs to macro field definitions" do
    headers = __ex_hdl_headers__()

    eth_m = List.keyfind(headers, :eth_macro, 0) |> elem(1)
    eth_b = List.keyfind(headers, :eth_bits, 0) |> elem(1)
    assert eth_b == eth_m

    ipv4_m = List.keyfind(headers, :ipv4_macro, 0) |> elem(1)
    ipv4_b = List.keyfind(headers, :ipv4_bits, 0) |> elem(1)
    assert ipv4_b == ipv4_m

    udp_m = List.keyfind(headers, :udp_macro, 0) |> elem(1)
    udp_b = List.keyfind(headers, :udp_bits, 0) |> elem(1)
    assert udp_b == udp_m
  end

  test "guarded bitstring header definitions produce identical field specs" do
    headers = __ex_hdl_headers__()

    ipv4_m = List.keyfind(headers, :ipv4_macro, 0) |> elem(1)
    ipv4_g = List.keyfind(headers, :ipv4_guarded, 0) |> elem(1)
    assert ipv4_g == ipv4_m

    udp_m = List.keyfind(headers, :udp_macro, 0) |> elem(1)
    udp_g = List.keyfind(headers, :udp_guarded, 0) |> elem(1)
    assert udp_g == udp_m
  end

  test "packets built from bitstring headers have identical layers and specs" do
    m_spec = pkt_macro()
    b_spec = pkt_bits()
    g_spec = pkt_guarded()

    # Compare layer fields
    assert length(m_spec.layers) == length(b_spec.layers)
    assert length(m_spec.layers) == length(g_spec.layers)

    for {l_m, l_g} <- Enum.zip(m_spec.layers, g_spec.layers) do
      assert l_m.fixed_bytes == l_g.fixed_bytes
      assert l_m.hlen_field == l_g.hlen_field
      assert l_m.tail == l_g.tail
      assert l_m.fields == l_g.fields
    end
  end

  test "encode and decode work identically with bitstring-defined headers" do
    pkt_data = %{
      eth: %{dst: 0x010203040506, src: 0x111213141516, ethertype: :ipv4},
      ipv4: %{
        ihl: 5,
        dscp: 0,
        ecn: 0,
        id: 0x1234,
        reserved: 0,
        df: true,
        mf: false,
        frag_offset: 0,
        ttl: 64,
        protocol: :udp,
        src: 0x0A000001,
        dst: 0x0A000002,
        options: <<>>
      },
      udp: %{
        src_port: 5004,
        dst_port: 5004
      }
    }

    bin_m = encode_pkt_macro(pkt_data, "hello world")
    bin_b = encode_pkt_bits(pkt_data, "hello world")
    bin_g = encode_pkt_guarded(pkt_data, "hello world")
    assert bin_b == bin_m
    assert bin_g == bin_m

    assert {:ok, decoded, "hello world"} = decode_pkt_guarded(bin_g, match: %{{:udp, :dst_port} => [5004]})
    assert decoded.eth.dst == 0x010203040506
    assert decoded.udp.dst_port == 5004
  end

  test "assignment syntax in bitstrings asserts constant value" do
    spec = assignment_assert_bits()
    version_field = Enum.find(spec.layers |> hd() |> Map.get(:fields), &(&1.name == :version))
    assert version_field.assert == 4
  end
end
