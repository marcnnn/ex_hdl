defmodule ExHdl.ProtocolChainCodecTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExHdl.Protocol.{Codec, Layout, Spec}
  alias ExHdl.Test.ChainGen
  alias ExHdl.Test.NetProtocols, as: N

  @tables %{{:udp, :dst_port} => [5004, 319]}

  @header %{
    eth: %{dst: 0x01005E000001, src: 0x020000000001},
    vlan: [%{pcp: 3, dei: false, vid: 100}],
    ipv4: %{
      dscp: 46,
      ecn: 0,
      id: 0,
      reserved: 0,
      df: true,
      mf: false,
      frag_offset: 0,
      ttl: 64,
      src: 0xC0A80001,
      dst: 0xC0A800C7
    },
    udp: %{src_port: 5004, dst_port: 5004}
  }

  describe "udp chain" do
    test "wire layout: derived selectors, lengths and checksums" do
      bin = N.encode_udp64(@header, "hello world")

      assert Base.encode16(bin) ==
               "01005E000001020000000001" <>
                 "8100" <>
                 "60640800" <>
                 "45B80027000040004011B7F5C0A80001C0A800C7" <>
                 "138C138C0013C4C8" <> Base.encode16("hello world")

      assert {:ok, h, "hello world"} = N.decode_udp64(bin)
      assert h.eth.ethertype == :vlan
      assert [%{vid: 100, dei: false, ethertype: :ipv4}] = h.vlan
      assert %{ihl: 5, total_length: 39, checksum: 0xB7F5, protocol: :udp, df: true} = h.ipv4
      assert %{length: 19, checksum: 0xC4C8} = h.udp
    end

    test "known IPv4 header checksum (RFC 1071 example header)" do
      ip = Base.decode16!("450000730000400040110000C0A80001C0A800C7")
      assert Bitwise.bxor(Codec.inet_sum(ip), 0xFFFF) == 0xB861
    end

    test "options set the header length" do
      h = put_in(@header, [:ipv4, :options], <<1, 1, 1, 0>>)
      bin = N.encode_udp64(h, "x")
      assert {:ok, d, "x"} = N.decode_udp64(bin)
      assert d.ipv4.ihl == 6 and d.ipv4.options == <<1, 1, 1, 0>> and d.ipv4.total_length == 33

      assert_raise ArgumentError, ~r/multiple of 4 bytes/, fn ->
        N.encode_udp64(put_in(@header, [:ipv4, :options], <<1, 2>>), "x")
      end
    end

    test "padding after the innermost length is dropped, truncation is an error" do
      bin = N.encode_udp64(@header, "hello world")
      assert {:ok, _, "hello world"} = N.decode_udp64(bin <> <<0, 0, 0>>)

      assert N.decode_udp64(binary_part(bin, 0, byte_size(bin) - 2)) ==
               {:error, {:truncated, {:udp, :length}, 19}}
    end

    test "header-only decode returns the rest untouched" do
      bin = N.encode_udp64(@header, "hello world")
      assert {:ok, h, rest} = N.decode_udp64_header(bin <> "pad")
      assert rest == "hello worldpad"
      assert h.udp.dst_port == 5004
      # works on a header-sized slice too: lengths are not checked
      assert {:ok, _, ""} = N.decode_udp64_header(binary_part(bin, 0, 46))
    end

    test "runtime matches and error shapes" do
      bin = N.encode_udp64(@header, "x")
      assert {:ok, _, "x"} = N.decode_udp64(bin, match: @tables)

      assert N.decode_udp64(bin, match: %{{:udp, :dst_port} => [319]}) ==
               {:error, {:no_match, {:udp, :dst_port}, 5004}}

      # error: on the version field maps the assert failure to a chosen reason
      bad = put_in(@header, [:ipv4, :version], 6)
      assert N.decode_udp64(N.encode_udp64(bad, "x")) == {:error, :not_ipv4}

      assert N.decode_udp64(ChainGen.put_bits(bin, 12 * 8, 16, 0x86DD)) ==
               {:error, {:no_branch, {:eth, :ethertype}, 0x86DD}}

      assert N.decode_udp64(ChainGen.put_bits(bin, 18 * 8 + 4, 4, 4)) ==
               {:error, {:bad_length, {:ipv4, :ihl}, 4}}

      assert {:error, {:bad_checksum, {:ipv4, :checksum}, _}} =
               N.decode_udp64(ChainGen.put_bits(bin, 26 * 8, 8, 0))

      assert {:error, {:bad_checksum, {:udp, :checksum}, _}} =
               N.decode_udp64(N.encode_udp64(put_in(@header, [:udp, :checksum], 1), "x"))

      # optional: 0 means no UDP checksum
      assert {:ok, _, "x"} =
               N.decode_udp64(N.encode_udp64(put_in(@header, [:udp, :checksum], 0), "x"))

      assert N.decode_udp64(N.encode_udp64(put_in(@header, [:udp, :length], 7), "x")) ==
               {:error, {:bad_length, {:udp, :length}, 7}}

      assert N.decode_udp64(binary_part(bin, 0, 30)) == {:error, :truncated_header}
    end

    test "three VLAN tags exceed max: 2" do
      h = %{@header | vlan: [%{pcp: 0, dei: false, vid: 1}, %{pcp: 0, dei: false, vid: 2}]}
      bin = N.encode_udp64(h, "x")
      assert {:ok, %{vlan: [%{vid: 1}, %{vid: 2}]}, "x"} = N.decode_udp64(bin)
      assert {:ok, %{vlan: []}, "x"} = N.decode_udp64(N.encode_udp64(%{@header | vlan: []}, "x"))

      # a third tag, spliced in after the second one's TCI
      <<pre::binary-size(20), post::binary>> = bin
      bin3 = pre <> <<0x81, 0x00, 0x00, 0x03>> <> post

      assert N.decode_udp64(bin3) == {:error, {:no_branch, {:vlan, :ethertype}, 0x8100}}
    end

    test "encode errors" do
      assert_raise ArgumentError,
                   ~r/cannot derive :ipv4.protocol: no next layer \[:udp\] in the header/,
                   fn ->
                     N.encode_udp64(Map.delete(@header, :udp), "x")
                   end

      assert_raise ArgumentError, ~r/missing header field :ttl/, fn ->
        N.encode_udp64(update_in(@header, [:ipv4], &Map.delete(&1, :ttl)), "x")
      end

      assert_raise ArgumentError, ~r/vid = 4096 does not fit/, fn ->
        N.encode_udp64(put_in(@header, [:vlan], [%{pcp: 0, dei: false, vid: 4096}]), "x")
      end

      assert_raise ArgumentError, ~r/payload must be a binary/, fn ->
        N.encode_udp64(@header, [1, 2])
      end
    end

    property "encode/decode round trip on every layout" do
      spec = N.udp32()

      check all({header, payload, _path} <- ChainGen.packet(spec, @tables)) do
        bin = N.encode_udp32(header, payload)
        assert {:ok, decoded, ^payload} = N.decode_udp32(bin, match: @tables)
        # decoded maps hold every field, so they encode to the same bytes
        assert N.encode_udp32(decoded, payload) == bin
        assert {:ok, ^decoded, ^payload} = N.decode_udp32_header(bin)
      end
    end

    property "every generated case decodes as the hardware treats it" do
      spec = N.udp64()

      check all({kind, outcome} <- ChainGen.loopback_case(spec, @tables), max_runs: 500) do
        bin = elem(outcome, 1)
        result = N.decode_udp64(bin, match: @tables)

        case {elem(outcome, 0), result} do
          {:good, {:ok, h, payload}} ->
            assert N.encode_udp64(h, payload) == elem(outcome, 2)

          {:flag, {:error, {:truncated, {:udp, :length}, _}}} ->
            assert kind == :truncated

          {:flag, {:error, {:bad_checksum, {:udp, :checksum}, _}}} ->
            assert kind == :bad_seg

          # header only: lengths say there is payload
          {:drop, {:error, {:truncated, _, _}}} ->
            assert kind == :header_only

          {:drop, {:error, reason}} ->
            assert kind != :header_only
            assert reason == :not_ipv4 or is_atom(reason) or elem(reason, 0) != :truncated
        end
      end
    end
  end

  describe "layouts" do
    test "the udp chain has 33 layouts, payload at 42..90" do
      paths = Layout.paths(N.udp64())
      assert length(paths) == 33
      assert paths |> Enum.map(& &1.payload) |> Enum.min_max() == {42, 90}
      assert Layout.max_header_bytes(paths) == 90
    end

    test "default branches" do
      paths = Layout.paths(N.eth_iq())
      assert Enum.map(paths, & &1.payload) |> Enum.sort() == [14, 18]
      spec = N.eth_iq()
      bin = N.encode_eth_iq(%{eth: %{dst: 1, src: 2, ethertype: 0x1234}}, [{1, -1}])
      assert byte_size(bin) == 18
      assert {:ok, %{eth: %{ethertype: 0x1234}}, [{1, -1}]} = N.decode_eth_iq(bin)
      assert Spec.payload_elem_bytes(spec) == 4
    end
  end

  describe "spec validation" do
    defp define(body) do
      mod = :"Elixir.ExHdl.ProtocolChainCodecTest.M#{System.unique_integer([:positive])}"

      Code.eval_string("""
      defmodule #{inspect(mod)} do
        use ExHdl.Protocol
        #{body}
      end
      """)
    end

    test "bytes fields need a header length and come last" do
      assert_raise ArgumentError, ~r/a :bytes field needs a header_length field/, fn ->
        define("""
        defheader :h do
          field :a, 8
          field :opts, :bytes
        end
        defpacket :p do
          layer :h
          payload :d, type: :bytes
        end
        """)
      end

      assert_raise ArgumentError, ~r/must be the last field/, fn ->
        define("""
        defheader :h do
          field :len, 8, header_length: 1
          field :opts, :bytes
          field :b, 8
        end
        defpacket :p do
          layer :h
          payload :d, type: :bytes
        end
        """)
      end
    end

    test "next targets, reachability and segment checksums" do
      assert_raise ArgumentError, ~r/next target :nope is not a layer/, fn ->
        define("""
        defheader :h do
          field :t, 8
        end
        defpacket :p do
          layer :h, next: {:t, %{1 => :nope}}
          payload :d, type: :bytes
        end
        """)
      end

      assert_raise ArgumentError, ~r/layer :b is not reachable/, fn ->
        define("""
        defheader :h do
          field :t, 8
        end
        defpacket :p do
          layer :a, header: :h
          layer :b, header: :h
          payload :d, type: :bytes
        end
        """)
      end

      assert_raise ArgumentError,
                   ~r/segment checksum needs a fixed-size layer directly before/,
                   fn ->
                     define("""
                     defheader :h do
                       field :t, 8
                       field :c, 16, checksum: :segment
                     end
                     defheader :g do
                       field :x, 8
                     end
                     defpacket :p do
                       layer :h, next: {:t, %{1 => :g}}
                       layer :g
                       payload :d, type: :bytes
                     end
                     """)
                   end

      assert_raise ArgumentError, ~r/unknown value :ipv6/, fn ->
        define("""
        defheader :h do
          field :t, 8, type: {:enum, ipv4: 4}
        end
        defpacket :p do
          layer :h, next: {:t, ipv6: :payload}
          payload :d, type: :bytes
        end
        """)
      end
    end

    test "field options" do
      assert_raise ArgumentError, ~r/type :flag needs 1 bit/, fn ->
        define("""
        defpacket :p do
          header do
            field :a, 8, type: :flag
          end
          payload :d, type: :bytes
        end
        """)
      end

      assert_raise ArgumentError, ~r/checksum fields are 16 bits/, fn ->
        define("""
        defpacket :p do
          header do
            field :a, 8, checksum: :header
          end
          payload :d, type: :bytes
        end
        """)
      end

      assert_raise ArgumentError, ~r/unknown options \[:lenght\]/, fn ->
        define("""
        defpacket :p do
          header do
            field :a, 16, lenght: :total
          end
          payload :d, type: :bytes
        end
        """)
      end
    end
  end
end
