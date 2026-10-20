defmodule ExHdl.RegsTest do
  use ExUnit.Case, async: true
  use ExHdl.Regs

  alias ExHdl.Regs
  alias ExHdl.Test.MixerRegs, as: R

  describe "layout" do
    test "offsets are automatic or explicit, arrays and windows placed" do
      assert R.offset(:id) == 0x00
      assert R.offset(:ctrl) == 0x04
      assert R.offset(:irq) == 0x10
      assert R.offset(:level, 0) == 0x14
      assert R.offset(:level, 3) == 0x2C
      assert R.window_offset(:coeffs, 2) == 0x108
      # auto-placed window aligned to its size after coeffs
      assert R.window_offset(:lut, 0) == 0x140
      assert R.regmap().addr_width == 9
    end

    test "array and index errors" do
      assert_raise ArgumentError, ~r/is an array of 4/, fn -> R.offset(:level) end
      assert_raise ArgumentError, ~r/outside 0..3/, fn -> R.offset(:level, 4) end
      assert_raise ArgumentError, ~r/not an array/, fn -> R.offset(:ctrl, 0) end
      assert_raise ArgumentError, ~r/no register/, fn -> R.offset(:nope) end
      assert_raise ArgumentError, ~r/outside 0..15/, fn -> R.window_offset(:coeffs, 16) end
    end

    test "overlaps and bad declarations are rejected" do
      assert_raise ArgumentError, ~r/a and b overlap at offset 0x4/, fn ->
        regmap "m" do
          register :a, count: 2 do
            field :x, 0
          end

          register :b, offset: 4 do
            field :x, 0
          end
        end
      end

      assert_raise ArgumentError, ~r/fields x and y overlap/, fn ->
        regmap "m" do
          register :a do
            field :x, 0..3
            field :y, 3..4
          end
        end
      end

      assert_raise ArgumentError, ~r/bits beyond 31/, fn ->
        regmap "m" do
          register :a do
            field :x, 30..32
          end
        end
      end

      assert_raise ArgumentError, ~r/reset 4 does not fit 2 bits/, fn ->
        regmap "m" do
          register :a do
            field :x, 0..1, :rw, reset: 4
          end
        end
      end

      assert_raise ArgumentError, ~r/ascending range/, fn ->
        regmap "m" do
          register :a do
            field :x, 3..0//-1
          end
        end
      end

      assert_raise ArgumentError, ~r/not a multiple of 4/, fn ->
        regmap "m" do
          register :a, offset: 2 do
            field :x, 0
          end
        end
      end

      assert_raise ArgumentError, ~r/power of two/, fn ->
        regmap("m", do: window(:w, size: 12))
      end

      assert_raise ArgumentError, ~r/not a multiple of 64/, fn ->
        regmap("m", do: window(:w, size: 64, offset: 32))
      end

      assert_raise ArgumentError, ~r/addr_width 4 too small/, fn ->
        regmap "m", addr_width: 4 do
          register :a, offset: 0x40 do
            field :x, 0
          end
        end
      end

      assert_raise ArgumentError, ~r/access must be one of/, fn ->
        regmap "m" do
          register :a do
            field :x, 0, :rx
          end
        end
      end

      assert_raise ArgumentError, ~r/const: is only for :ro/, fn ->
        regmap "m" do
          register :a do
            field :x, 0, :rw, const: 1
          end
        end
      end
    end

    test "regmap/3 builds maps from parameters" do
      n = 3

      m =
        regmap "param" do
          for i <- 0..(n - 1) do
            register :"ch#{i}" do
              field :gain, 0..15, :rw, reset: i
            end
          end
        end

      assert Enum.map(m.registers, &{&1.name, &1.offset}) == [ch0: 0, ch1: 4, ch2: 8]
      assert Regs.reset_value(m, :ch2) == 2
    end
  end

  describe "host helpers" do
    test "encode fills reset values, decode names enums" do
      assert R.encode(:ctrl, mode: :stereo) == 0x40005
      assert R.encode(:ctrl, enable: false, gain: 0, start: true) == 0x8000_0000
      assert R.decode(:ctrl, 0x40005) == %{enable: 1, mode: :stereo, gain: 0x4000}
      assert R.decode(:ctrl, 0b110) == %{enable: 0, mode: 3, gain: 0}
      assert R.reset_value(:ctrl) == 0x40001
      assert R.reset_value(:id) == 0x0102
    end

    test "w1c and w1s fields default to 0 so unnamed bits are left alone" do
      assert R.encode(:irq, []) == 0
      assert R.encode(:irq, overflow: 1, arm: 2) == 0x201
    end

    test "update replaces only the named fields" do
      w = R.encode(:level, value: 0x123456, mute: 1)
      assert R.update(:level, w, value: 7) == 0x8000_0007
      assert R.decode(:level, R.update(:level, w, mute: false)) == %{value: 0x123456, mute: 0}
    end

    test "errors name the field" do
      assert_raise ArgumentError, ~r/ctrl.mode: 4 does not fit 2 bits/, fn ->
        R.encode(:ctrl, mode: 4)
      end

      assert_raise ArgumentError, ~r/unknown enum value :quad/, fn ->
        R.encode(:ctrl, mode: :quad)
      end

      assert_raise ArgumentError, ~r/id.version is ro/, fn -> R.encode(:id, version: 1) end

      assert_raise ArgumentError, ~r/no field\(s\) \[:bogus\]/, fn ->
        R.encode(:ctrl, bogus: 1)
      end

      assert_raise ArgumentError, ~r/32-bit unsigned/, fn -> R.decode(:ctrl, -1) end
    end
  end

  describe "slave ports" do
    test "field, strobe and window ports" do
      m = R.rtl()
      ports = Map.new(m.ports, &{&1.name, {&1.dir, &1.type}})

      assert ports[:id_channels] == {:input, {:u, 8}}
      refute Map.has_key?(ports, :id_version)
      assert ports[:ctrl_mode] == {:output, {:u, 2}}
      assert ports[:ctrl_start] == {:output, {:u, 1}}
      assert ports[:ctrl_wr] == {:output, {:u, 1}}
      refute Map.has_key?(ports, :ctrl_rd)
      assert ports[:irq_underrun] == {:output, {:u, 3}}
      assert ports[:irq_underrun_set] == {:input, {:u, 3}}
      assert ports[:irq_arm_clr] == {:input, {:u, 2}}
      assert ports[:irq_events_set] == {:input, {:u, 8}}
      assert ports[:irq_rd] == {:output, {:u, 1}}
      assert ports[:level_3_value] == {:output, {:u, 24}}
      assert ports[:coeffs_addr] == {:output, {:u, 4}}
      assert ports[:coeffs_be] == {:output, {:u, 4}}
      assert ports[:lut_rdata] == {:input, {:u, 32}}
      assert ports[:s_axil_awaddr] == {:input, {:u, 9}}
      assert ExHdl.RTL.Module.port(m, :s_axil_rdata).dir == :output
    end
  end

  describe "C header" do
    test "defines offsets, masks and accessors" do
      h = R.c_header()
      assert h =~ "#define MIXER_REGS_CTRL_OFFSET 0x00000004u\n"
      assert h =~ "#define MIXER_REGS_CTRL_GAIN_MASK 0x000FFFF0u\n"
      assert h =~ "#define MIXER_REGS_CTRL_MODE_STEREO 2u\n"

      assert h =~
               "#define MIXER_REGS_LEVEL_OFFSET(i) (0x00000014u + (uint32_t)(i) * 0x00000008u)\n"

      assert h =~ "#define MIXER_REGS_COEFFS_WORDS 16u\n"
    end

    @tag :cc
    @tag :tmp_dir
    test "compiles and agrees with the Elixir helpers", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "mixer_regs.h"), R.c_header())

      File.write!(Path.join(dir, "main.c"), """
      #include <stdio.h>
      #include "mixer_regs.h"
      int main(void) {
        uint32_t w = MIXER_REGS_CTRL_RESET;
        w = MIXER_REGS_CTRL_MODE_SET(w, MIXER_REGS_CTRL_MODE_STEREO);
        w = MIXER_REGS_CTRL_GAIN_SET(w, 0x1234);
        printf("%u %u %u %u %u\\n", (unsigned)MIXER_REGS_LEVEL_OFFSET(3), (unsigned)w,
               (unsigned)MIXER_REGS_CTRL_GAIN_GET(w), (unsigned)MIXER_REGS_IRQ_OFFSET,
               (unsigned)MIXER_REGS_LUT_OFFSET);
        return 0;
      }
      """)

      exe = Path.join(dir, "main")

      {_, 0} =
        System.cmd("cc", ["-std=c99", "-Wall", "-Wextra", "-Werror", "-o", exe, "main.c"],
          cd: dir,
          stderr_to_stdout: true
        )

      {out, 0} = System.cmd(exe, [])
      w = R.encode(:ctrl, mode: :stereo, gain: 0x1234)

      assert out ==
               "#{R.offset(:level, 3)} #{w} #{0x1234} #{R.offset(:irq)} #{R.window_offset(:lut, 0)}\n"
    end
  end

  test "Markdown lists registers, windows and fields" do
    md = R.markdown()
    assert md =~ "## Register map `mixer_regs`"
    assert md =~ "| 0x0004 | `ctrl` | register | 0x00040001 | Control |"
    assert md =~ "| 0x0014 + i * 0x0008, i < 4 | `level` | register |"
    assert md =~ "| 0x0100 - 0x013F | `coeffs` | window (rw, 16 words) |  | Coefficient RAM |"
    assert md =~ "| 2:1 | `mode` | rw | 0x0 | Values: 0 = `off`, 1 = `mono`, 2 = `stereo`. |"
    assert md =~ "| 31 | `start` | wo | 0x0 |  |"
  end
end
