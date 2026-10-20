defmodule ExHdl.ProtocolCodecTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExHdl.Test.Protocols, as: P
  alias ExHdl.Test.Gen

  describe "iq_frame (little endian)" do
    test "wire layout" do
      bin =
        P.encode_iq_frame(
          %{
            channel_id: 0x12,
            flags: 0x34,
            gain_q15: -2,
            seq_num: 0x5678,
            timestamp: 0x0102030405060708
          },
          [{1, -1}]
        )

      assert bin ==
               <<0xAA, 0x55, 0x12, 0x34, 0xFE, 0xFF, 0x78, 0x56, 8, 7, 6, 5, 4, 3, 2, 1, 1, 0,
                 0xFF, 0xFF>>
    end

    property "encode/decode round trip" do
      spec = P.iq_frame()

      check all(header <- Gen.header(spec), payload <- Gen.payload(spec, min_length: 0)) do
        assert {:ok, decoded, ^payload} = P.decode_iq_frame(P.encode_iq_frame(header, payload))
        assert decoded == Map.put(header, :magic, 0x55AA)
      end
    end

    test "decode errors" do
      good =
        P.encode_iq_frame(%{channel_id: 1, flags: 0, gain_q15: 0, seq_num: 0, timestamp: 0}, [
          {0, 0}
        ])

      assert P.decode_iq_frame(<<0xAB, 0x55>> <> binary_part(good, 2, 18)) ==
               {:error, {:assert_failed, :magic, 0x55AB}}

      assert P.decode_iq_frame(binary_part(good, 0, 15)) == {:error, :truncated_header}
      assert P.decode_iq_frame(binary_part(good, 0, 18)) == {:error, :partial_payload_element}
    end

    test "encode rejects out-of-range values instead of wrapping" do
      header = %{channel_id: 256, flags: 0, gain_q15: 0, seq_num: 0, timestamp: 0}
      assert_raise ArgumentError, ~r/channel_id = 256/, fn -> P.encode_iq_frame(header, []) end

      header = %{header | channel_id: 0}

      assert_raise ArgumentError, ~r/stream = 32768/, fn ->
        P.encode_iq_frame(header, [{32768, 0}])
      end

      assert_raise ArgumentError, ~r/missing header field :flags/, fn ->
        P.encode_iq_frame(Map.delete(header, :flags), [])
      end
    end
  end

  describe "odd_frame (flags, enums, header ending mid-word)" do
    test "wire layout and decoded names" do
      bin = P.encode_odd_frame(%{kind: :ctrl, urgent: true, seq: 7}, [0x0102])
      assert bin == <<0x2D, 0, 0, 0, 7, 1, 2>>

      assert P.decode_odd_frame(bin) ==
               {:ok, %{kind: :ctrl, urgent: true, tag: 5, seq: 7}, [0x0102]}

      # unknown enum values decode to integers
      assert {:ok, %{kind: 3, urgent: false}, []} =
               P.decode_odd_frame(<<0x35, 0, 0, 0, 0>>)

      assert P.decode_odd_frame(<<0x2C, 0, 0, 0, 7>>) == {:error, {:assert_failed, :tag, 4}}
      assert {:ok, _, <<1, 2>>} = P.decode_odd_frame_header(bin)
    end
  end

  describe "be_frame (big endian bit fields)" do
    test "wire layout" do
      bin =
        P.encode_be_frame(%{tclass: 0xA5, flow: 0xBCDEF, len: 0x1234, next: 0x56, hops: -1}, [7])

      assert bin == <<0x6A, 0x5B, 0xCD, 0xEF, 0x12, 0x34, 0x56, 0xFF, 7>>
    end

    property "encode/decode round trip" do
      spec = P.be_frame()

      check all(header <- Gen.header(spec), payload <- Gen.payload(spec, min_length: 0)) do
        assert {:ok, decoded, ^payload} = P.decode_be_frame(P.encode_be_frame(header, payload))
        assert decoded == Map.put(header, :version, 6)
      end
    end
  end

  describe "spec validation" do
    defp define(body) do
      mod = :"Elixir.ExHdl.ProtocolCodecTest.M#{System.unique_integer([:positive])}"

      Code.eval_string("""
      defmodule #{inspect(mod)} do
        use ExHdl.Protocol
        #{body}
      end
      """)
    end

    test "headers need whole bytes, not whole bus words" do
      {{:module, mod, _, _}, _} =
        define("""
        defpacket :p, bus_width: 32 do
          header do
            field :a, 24
          end
          payload :d, type: :u8
        end
        """)

      assert mod.encode_p(%{a: 0x010203}, [9]) == <<1, 2, 3, 9>>
      assert mod.decode_p(<<1, 2, 3, 9>>) == {:ok, %{a: 0x010203}, [9]}

      assert_raise ArgumentError, ~r/is 12 bits, not a whole number of bytes/, fn ->
        define("""
        defpacket :p do
          header do
            field :a, 12
          end
          payload :d, type: :u8
        end
        """)
      end
    end

    test "little endian needs whole-byte fields" do
      assert_raise ArgumentError, ~r/whole-byte fields, got 4 bits/, fn ->
        define("""
        defpacket :p, byte_order: :little do
          header do
            field :a, 4
            field :b, 28
          end
          payload :d, type: :u8
        end
        """)
      end
    end

    test "type and width must agree, assert must fit" do
      assert_raise ArgumentError, ~r/type :s16 does not match width 8/, fn ->
        define("""
        defpacket :p, bus_width: 8 do
          header do
            field :a, 8, type: :s16
          end
          payload :d, type: :u8
        end
        """)
      end

      assert_raise ArgumentError, ~r/assert value 256 does not fit/, fn ->
        define("""
        defpacket :p, bus_width: 8 do
          header do
            field :a, 8, assert: 256
          end
          payload :d, type: :u8
        end
        """)
      end
    end
  end
end
