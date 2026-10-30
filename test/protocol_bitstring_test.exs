defmodule ExHdl.ProtocolBitstringTest do
  use ExUnit.Case, async: true

  alias ExHdl.Test.NetProtocols, as: Net

  defmodule Legacy do
    use ExHdl.Protocol

    defheader :ipv4 do
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

    defpacket :ip, bus_width: 32 do
      layer(:ipv4)
      payload(:data, type: :bytes)
    end
  end

  # A clause as it would appear in a hand-written BEAM parser, pasted as is.
  defmodule Pasted do
    use ExHdl.Protocol

    defheader :eth, <<dst::48, src::48, ethertype::16, _rest::binary>>

    defpacket :frame, bus_width: 64 do
      layer(:eth)
      payload(:data, type: :bytes)
    end
  end

  defmodule Pattern do
    use ExHdl.Protocol

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

    defpacket :ip, bus_width: 32 do
      layer(:ipv4)
      payload(:data, type: :bytes)
    end
  end

  @ipv4 %{
    ipv4: %{
      dscp: 46,
      ecn: 0,
      id: 7,
      reserved: 0,
      df: true,
      mf: false,
      frag_offset: 0,
      ttl: 64,
      protocol: :udp,
      src: 0xC0A80001,
      dst: 0xEF000001,
      options: <<1, 1, 1, 0>>
    }
  }

  test "a pattern header gives the same spec as the field form" do
    assert Pattern.ip() == Legacy.ip()
  end

  test "match_name/1 is the pattern as a function head" do
    bin = Pattern.encode_ip(@ipv4, "payload")

    assert {:ok, fields, "payload"} = Pattern.match_ipv4(bin)
    assert %{version: 4, ihl: 6, options: <<1, 1, 1, 0>>, df: 1, protocol: 17} = fields

    # the same raw values the codec decodes
    {:ok, %{ipv4: decoded}, _} = Pattern.decode_ip(bin)
    assert fields.src == decoded.src and fields.checksum == decoded.checksum

    assert :error = Pattern.match_ipv4(<<6::4, 0::4, 0::152>>)
    assert :error = Pattern.match_ipv4(<<1, 2, 3>>)
  end

  test "a pasted BEAM pattern with a trailing rest" do
    bin = <<1::48, 2::48, 0x0800::16, "data">>
    assert {:ok, %{dst: 1, src: 2, ethertype: 0x0800}, "data"} = Pasted.match_eth(bin)
    assert {:ok, %{eth: %{dst: 1, src: 2, ethertype: 0x0800}}, "data"} = Pasted.decode_frame(bin)
  end

  test "the test protocols' patterns run on real packets" do
    pkt = %{
      eth: %{dst: 0x01005E000001, src: 0x020000000001},
      ipv4: Map.put(@ipv4.ipv4, :options, <<>>),
      udp: %{src_port: 5004, dst_port: 5004}
    }

    bin = Net.encode_udp32(pkt, "rtp")
    assert {:ok, %{ethertype: 0x0800}, rest} = Net.match_eth(bin)
    assert {:ok, %{protocol: 17, ihl: 5, options: ""}, rest} = Net.match_ipv4(rest)
    assert {:ok, %{dst_port: 5004}, "rtp"} = Net.match_udp(rest)
  end

  describe "errors" do
    defp compile(body) do
      Code.compile_string("""
      defmodule ExHdl.ProtocolBitstringTest.M#{System.unique_integer([:positive])} do
        use ExHdl.Protocol
        #{body}
      end
      """)
    end

    test "constants need a name and a guard" do
      assert_raise ArgumentError, ~r/need a name/, fn ->
        compile("defheader :h, <<4::4, ihl::4>>")
      end

      assert_raise ArgumentError, ~r/need a name, not _/, fn ->
        compile("defheader :h, <<_::4, ihl::4>>")
      end
    end

    test "only field == value guards" do
      assert_raise ArgumentError, ~r/unsupported guard/, fn ->
        compile("defheader :h, <<a::4, b::4>> when a > 2")
      end

      assert_raise ArgumentError, ~r/not a field/, fn ->
        compile("defheader :h, <<a::4, b::4>> when c == 2")
      end
    end

    test "options for unknown fields" do
      assert_raise ArgumentError, ~r/options for :c/, fn ->
        compile("defheader :h, <<a::4, b::4>>, c: [type: :flag]")
      end
    end

    test "tail size must match the fixed part" do
      assert_raise ArgumentError, ~r/fixed part is 16 bits/, fn ->
        compile("defheader :h, <<a::8, hl::8, opts::binary-size(hl * 4 - 3)>>")
      end

      assert_raise ArgumentError, ~r/size\(field \* unit - fixed_bytes\)/, fn ->
        compile("defheader :h, <<a::8, hl::8, opts::binary-size(hl)>>")
      end
    end

    test "endianness must agree with byte_order" do
      assert_raise ArgumentError, ~r/little-endian in the pattern/, fn ->
        compile("""
        defpacket :p, bus_width: 32 do
          header <<a::16-little, b::16>>
          payload :d, type: :u8
        end
        """)
      end
    end
  end
end
