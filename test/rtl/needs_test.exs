defmodule ExHdl.RTL.NeedsTest.SyncLib do
  @moduledoc false
  # ex_hdl_cores: a library that defines its own sync/1.
  use ExHdl.RTL, except: [:sync, :state]

  def sync(opts), do: {:mine, opts}
  def state(a, b), do: {:mine, a, b}

  def build do
    module "except_sync" do
      r = reg(:r, 4)
      q = output(:q, 4)

      sync do
        r <~ add_wrap(r, 1)
      end

      fsm :f do
        state :a, do: goto(:b)
        state(:b, do: goto(:a))
      end

      q <~ r
    end
  end
end

defmodule ExHdl.RTL.NeedsTest do
  # Regression tests for the DSL and SV backend items of the sibling
  # libraries' NEEDS.md files, each with the reproducer given there.
  use ExUnit.Case, async: true
  use ExHdl.RTL

  alias ExHdl.Backends.SystemVerilog.RTL, as: SV
  alias ExHdl.RTL.{CDC, ElaborationError, Sim, WidthError}

  @iobuf """
  module IOBUF (input wire I, input wire T, output wire O, inout wire IO);
    assign IO = T ? 1'bz : I;
    assign O = IO;
  endmodule
  """

  defp lint!(mod, extra \\ %{}) do
    dir = Path.join(System.tmp_dir!(), "ex_hdl_needs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      files =
        for {f, src} <- Map.merge(SV.generate(mod), extra) do
          File.write!(Path.join(dir, f), src)
          Path.join(dir, f)
        end

      {out, status} =
        System.cmd("verilator", ["--lint-only", "-Wall", "--top-module", mod.name | files],
          stderr_to_stdout: true
        )

      assert status == 0, "#{mod.name}:\n#{out}"
    after
      File.rm_rf!(dir)
    end
  end

  # -- ex_hdl_xilinx ---------------------------------------------------------------------

  describe "ex_hdl_xilinx" do
    test "1: real-valued parameters" do
      bb =
        black_box "BR", params: [P: 1.5, Q: {:real, 10}, R: 1.0e-3] do
          input(:I, 1)
        end

      t =
        module "t_real" do
          a = input(:a, 1)
          instance(:u, bb, connect: [I: a], params: [Q: 2.5])
        end

      src = SV.generate(t)["t_real.sv"]
      assert src =~ ".P(1.5)"
      assert src =~ ".Q(2.5)"
      assert src =~ ".R(0.001)"

      assert SV.module_source(
               module "t_real_int" do
                 a = input(:a, 1)
                 instance(:u, bb, connect: [I: a], params: [Q: {:real, 10}])
               end
             ) =~ ".Q(10.0)"
    end

    @tag :verilator
    test "1: real parameters lint against a real-typed module" do
      stub = """
      /* verilator lint_off UNUSEDPARAM */
      /* verilator lint_off UNUSEDSIGNAL */
      module BR #(parameter real P = 1.0, parameter real Q = 1.0) (input wire I);
      endmodule
      /* verilator lint_on UNUSEDSIGNAL */
      /* verilator lint_on UNUSEDPARAM */
      """

      bb =
        black_box "BR", params: [P: 1.5, Q: {:real, 10}], sources: %{"BR.sv" => stub} do
          input(:I, 1)
        end

      lint!(
        module "t_real_lint" do
          a = input(:a, 1)
          instance(:u, bb, connect: [I: a], params: [P: 2.25])
        end
      )
    end

    test "4: black_box_from builds the same box as the macro" do
      macro =
        black_box "BUFGCE", params: [CE_TYPE: "SYNC"] do
          input(:I, 1, domain: :async)
          input(:CE, 1, domain: :async)
          output(:O, 1, domain: :async, comb_from: [:I, :CE], clock: true)
        end

      data =
        ExHdl.RTL.black_box_from(
          "BUFGCE",
          [
            {:input, :I, 1, domain: :async},
            {:input, :CE, 1, domain: :async},
            {:output, :O, 1, domain: :async, comb_from: [:I, :CE], clock: true}
          ],
          params: [CE_TYPE: "SYNC"]
        )

      assert data == macro
      assert data.clock_outputs == [:O]

      clocked =
        ExHdl.RTL.black_box_from(
          "FDRE_BOX",
          [{:input, :D, 1}, {:output, :Q, 1, comb_from: :none}],
          domains: [sys: [clock: :C, reset: nil]]
        )

      assert Enum.map(clocked.ports, & &1.name) == [:C, :D, :Q]
      assert clocked.comb_paths == %{Q: []}
    end

    test "5: uppercase port access u.O" do
      bb =
        black_box "B5" do
          input(:I, 1)
          output(:O, 1)
        end

      m =
        module "upper" do
          a = input(:a, 1)
          y = output(:y, 1)
          u = instance(:u, bb)
          u.I <~ a
          y <~ u.O
        end

      assert SV.module_source(m) =~ "assign y = u_O;"
      assert SV.module_source(m) =~ ".I(u_I)"

      assert_raise ElaborationError, ~r/instance u has no port :X; ports: \[:I, :O\]/, fn ->
        module "upper_bad" do
          u = instance(:u, bb, connect: [I: 0])
          _ = u.X
        end
      end
    end

    test "6: sim_sources reach simulation only" do
      bb =
        black_box "IBUFDS", sim_sources: %{"IBUFDS.sv" => "module IBUFDS; endmodule\n"} do
          input(:I, 1)
          input(:IB, 1)
          output(:O, 1)
        end

      m =
        module "uses_ibufds" do
          p = input(:clk_p, 1)
          n = input(:clk_n, 1)
          y = output(:y, 1)
          u = instance(:u, bb, connect: [I: p, IB: n])
          y <~ u.O
        end

      assert Map.keys(SV.generate(m)) == ["uses_ibufds.sv"]
      assert Map.keys(SV.generate(m, sim: true)) == ["IBUFDS.sv", "uses_ibufds.sv"]
    end

    test "8: clock outputs are marked on black boxes only" do
      bb =
        black_box "BUFG" do
          input(:I, 1, domain: :async)
          output(:O, 1, domain: :async, clock: true)
        end

      assert bb.clock_outputs == [:O]

      assert_raise ElaborationError, ~r/clock: true marks black-box outputs/, fn ->
        module "no_clock_out" do
          output(:o, 1, clock: true)
        end
      end

      assert_raise ElaborationError, ~r/must be 1 bit/, fn ->
        black_box "BAD" do
          output(:O, 2, clock: true)
        end
      end
    end

    defp iobuf do
      black_box "IOBUF", sources: %{"IOBUF.sv" => @iobuf} do
        input(:I, 1)
        input(:T, 1)
        output(:O, 1)
        inout(:IO, 1)
      end
    end

    defp i2c_top do
      buf = iobuf()

      module "i2c_pads" do
        sda = inout(:sda, 1)
        _scl = inout(:scl, 1)
        sda_o = input(:sda_o, 1)
        sda_t = input(:sda_t, 1)
        sda_i = output(:sda_i, 1)
        u = instance(:u_sda, buf, connect: [I: sda_o, T: sda_t, IO: sda])
        sda_i <~ u.O
      end
    end

    test "9: inout ports pass through to black boxes" do
      m = i2c_top()
      src = SV.module_source(m)
      assert src =~ ~r/inout\s+wire\s+sda,/
      assert src =~ ".IO(sda)"
      assert Enum.find(m.ports, &(&1.name == :sda)).dir == :inout
      assert [%{inouts: [IO: :sda]}] = m.instances

      # the simulator ignores inout ports
      plain =
        module "inout_sim" do
          _pad = inout(:pad, 1)
          a = input(:a, 1)
          y = output(:y, 1)
          y <~ a
        end

      assert {_, [%{y: 1}]} = plain |> Sim.new() |> Sim.run([%{a: 1}])
    end

    @tag :verilator
    test "9: inout passthrough lints, left open as .IO()" do
      lint!(i2c_top())

      child =
        module "pad_child" do
          pad = inout(:pad, 1)
          i = input(:i, 1)
          o = output(:o, 1)
          u = instance(:u_buf, iobuf(), connect: [I: i, T: 0, IO: pad])
          o <~ u.O
        end

      top =
        module "pad_top" do
          pad = inout(:pad, 1)
          i = input(:i, 1)
          o = output(:o, 1)
          u = instance(:u_c, child, connect: [i: i, pad: pad])
          o <~ u.o
        end

      lint!(top)
      assert SV.module_source(top) =~ ".pad(pad)"

      open =
        module "pad_open" do
          i = input(:i, 1)
          o = output(:o, 1)
          u = instance(:u_buf, iobuf(), connect: [I: i, T: 1])
          o <~ u.O
        end

      assert SV.module_source(open) =~ ".IO()"
    end

    test "9: logic cannot read or drive an inout" do
      assert_raise ElaborationError, ~r/inout sda is read by logic/, fn ->
        module "read_inout" do
          sda = inout(:sda, 1)
          y = output(:y, 1)
          y <~ sda
        end
      end

      assert_raise ElaborationError, ~r/sda is an inout port .* cannot be assigned/, fn ->
        module "drive_inout" do
          sda = inout(:sda, 1)
          sda <~ 1
        end
      end

      assert_raise ElaborationError,
                   ~r/connects to an inout port of connect_wire, x is not/,
                   fn ->
                     module "connect_wire" do
                       x = input(:x, 1)
                       instance(:u, iobuf(), connect: [I: x, T: x, IO: x])
                     end
                   end
    end
  end

  # -- ex_aes67 --------------------------------------------------------------------------

  describe "ex_aes67" do
    defp fsm_mem do
      module "fsm_mem" do
        mem = memory(:m, width: 8, depth: 16, init: [1])
        q = output(:q, 1)
        rd = read_port(mem, addr: 0, en: in_state(:c, :a))

        f =
          fsm :c do
            state :a do
              if rd == 1, do: goto(:b)
            end

            state(:b, do: goto(:a))
          end

        q <~ in_state(f, :b)
      end
    end

    test "FSM state usable in a memory enable the state body depends on" do
      m = fsm_mem()
      assert m.signals[:c_in_a].kind == :wire

      {_, out} =
        m |> Sim.new() |> Sim.reset() |> Sim.run(List.duplicate(%{rst_n: 1}, 6))

      # rd already holds mem[0] = 1 after the reset edge: a -> b -> a ...
      assert Enum.map(out, & &1.q) == [0, 1, 0, 1, 0, 1]
    end

    @tag :verilator
    test "FSM forward reference lints and co-simulates" do
      m = fsm_mem()
      lint!(m)
      stim = [%{rst_n: 0} | List.duplicate(%{rst_n: 1}, 8)]
      ExHdl.RTL.Cosim.assert_equivalent(m, stim)
    end

    test "a forward in_state needs the FSM" do
      assert_raise ElaborationError, ~r/in_state\(:nope, :a\) refers to an fsm nope/, fn ->
        module "no_fsm" do
          y = output(:y, 1)
          y <~ in_state(:nope, :a)
        end
      end

      assert_raise ElaborationError, ~r/fsm c has no state :zz/, fn ->
        module "bad_state" do
          y = output(:y, 1)
          y <~ in_state(:c, :zz)

          fsm :c do
            state(:a, do: goto(:a))
          end
        end
      end
    end

    test "zero-width pieces: slice of width 0, cat skips nil" do
      module "zero_width" do
        x = input(:x, 4)
        y = output(:y, 4)
        z = output(:z, 4)
        assert slice(x, 1, 0) == nil
        assert slice(x, 4, 0) == nil
        assert x[2..1//1] == nil
        assert cat([]) == nil
        assert rep(x, 0) == nil
        assert_raise WidthError, ~r/empty slice at bit 5/, fn -> slice(x, 5, 0) end

        # an address builder with no group bits
        groups = 0
        y <~ cat([slice(x, 2, 2), slice(x, 0, groups), slice(x, 0, 2)])
        z <~ cat([nil, x, cat([])])
      end
      |> then(fn m ->
        {_, [out]} = m |> Sim.new() |> Sim.run([%{x: 0b1011}])
        assert out == %{y: 0b1011, z: 0b1011}
      end)
    end
  end

  # -- ex_net ----------------------------------------------------------------------------

  describe "ex_net" do
    test "12: instance wire names colliding with parent signals name the instance" do
      child =
        module "tx_child" do
          a = input(:a, 1)
          d = output(:data, 1)
          d <~ a
        end

      assert_raise ElaborationError,
                   ~r/tx_data is declared twice; tx_data is the wire of port data of instance tx .*u_tx/,
                   fn ->
                     module "collide_after" do
                       a = input(:a, 1)
                       instance(:tx, child, connect: [a: a])
                       output(:tx_data, 1)
                     end
                   end

      assert_raise ElaborationError, ~r/port data of instance tx/, fn ->
        module "collide_before" do
          a = input(:a, 1)
          o = output(:tx_data, 1)
          o <~ a
          instance(:tx, child, connect: [a: a])
        end
      end
    end

    test "14: mux of two integers takes the wider constant's width" do
      m =
        module "mux_ints" do
          c = input(:c, 1)
          phase = reg(:phase, 3)
          s = output(:s, s(4))
          t = output(:t, 3)
          e = mux(c, 4, 3)
          assert e.type == {:u, 3}
          assert mux(c, -1, 3).type == {:s, 3}
          assert mux(c, 1, 0).type == {:u, 1}
          sync(do: phase <~ mux(c, 4, 3))
          s <~ mux(c, -8, 7)
          t <~ mux(phase, [1, 5, 2, 7, 6])
        end

      {_, out} = m |> Sim.new() |> Sim.reset() |> Sim.run([%{c: 1, rst_n: 1}, %{c: 0, rst_n: 1}])
      assert Enum.map(out, & &1.s) == [-8, 7]
      assert Enum.map(out, & &1.t) == [1, 6]
    end

    test "13: a table wire with rom_style carries the attributes" do
      m =
        module "rom_table" do
          sel = input(:sel, 4)
          y = output(:y, 4)
          t = wire(:tbl, mux(sel, Enum.map(0..15, &rem(&1 * 7 + 3, 16))), rom_style: :distributed)
          y <~ t
        end

      src = SV.module_source(m)
      assert src =~ ~s|(* rom_style = "distributed" *) logic [3:0] tbl;|
      assert src =~ ~s|(* rom_style = "logic" *) case (sel)|
      assert src =~ "4'd1: tbl = 4'd10;"
      refute src =~ "_t0"

      assert_raise ElaborationError, ~r/rom_style must be :distributed or :block/, fn ->
        module "rom_bad" do
          sel = input(:sel, 2)
          wire(:tbl, mux(sel, [1, 2]), rom_style: :ultra)
        end
      end
    end

    # A registered next-state table (the 8b/10b decode table of ex_net's PCS):
    # Yosys merges the case ROM with the register into block RAM.
    defp table_design(style) do
      words =
        for i <- 0..1023,
            do: rem(Bitwise.bxor(Bitwise.bsr(i * 2_654_435_761, 7), i * 40_503), 8192)

      module "rom_regd_#{style}" do
        din = input(:din, 3)
        y = output(:y, 13)
        st = reg(:st, 13)
        opts = if style == :auto, do: [], else: [rom_style: style]
        nxt = wire(:nxt, mux(cat([din, st[0..6]]), Enum.map(words, &const(&1, 13))), opts)

        sync do
          st <~ nxt
        end

        y <~ st
      end
    end

    @tag :yosys
    @tag timeout: 300_000
    test "13: rom_style: :distributed keeps a registered table out of block RAM" do
      util = fn m ->
        {:ok, u} = ExHdl.Synth.Yosys.utilization(SV.generate(m), m.name)
        u
      end

      assert util.(table_design(:auto)).bram18 >= 1
      assert %{bram18: 0, lut: lut} = util.(table_design(:distributed))
      assert lut > 0
    end

    @tag :verilator
    test "13: table wires lint" do
      lint!(table_design(:distributed))
    end

    test "15: SystemVerilog keywords are rejected at declaration" do
      for kw <- [:small, :event, :within, :s_until] do
        assert_raise ElaborationError, ~r/#{kw}.*keyword/, fn ->
          module "kw_decl" do
            input(kw, 1)
          end
        end
      end
    end

    test "16: == and != against nil keep their Elixir meaning" do
      module "nil_fold" do
        a = input(:a, 4)
        b = input(:b, 4)
        y = output(:y, 4)
        assert a == nil == false
        assert nil != a == true

        acc =
          Enum.reduce([a, b], nil, fn t, acc ->
            if acc == nil, do: t, else: acc ||| t
          end)

        y <~ acc
      end

      assert_raise WidthError, ~r/not a hardware expression: nil.*is_nil/, fn ->
        module "nil_lt" do
          a = input(:a, 4)
          _ = a < nil
        end
      end
    end
  end

  # -- ex_hdl_cores ----------------------------------------------------------------------

  describe "ex_hdl_cores" do
    test "use ExHdl.RTL, except: frees sync/1 and state/2 for the library" do
      alias ExHdl.RTL.NeedsTest.SyncLib
      assert SyncLib.sync(depth: 4) == {:mine, [depth: 4]}
      assert SyncLib.state(1, 2) == {:mine, 1, 2}
      m = SyncLib.build()
      {_, out} = m |> Sim.new() |> Sim.reset() |> Sim.run(List.duplicate(%{rst_n: 1}, 3))
      assert Enum.map(out, & &1.q) == [0, 1, 2]
      assert [%{name: :f}] = m.fsms
    end

    test "a hardware if on a generator accumulator explains itself" do
      assert_raise WidthError, ~r/needs a 1-bit unsigned value, got u4.*case, is_nil\/1/, fn ->
        module "if_acc" do
          ts = [input(:a, 4), input(:b, 4)]
          y = output(:y, 4)

          comb do
            y
            <~ Enum.reduce(ts, nil, fn t, acc ->
              if acc, do: acc ||| t, else: t
            end)
          end
        end
      end

      assert_raise ElaborationError, ~r/hardware if outside a comb or sync block; .*case/, fn ->
        module "if_top" do
          a = input(:a, 1)
          if a, do: nil
        end
      end
    end
  end

  # -- ex_pcie ---------------------------------------------------------------------------

  describe "ex_pcie" do
    test "5: axi_stream tkeep per DWord" do
      i = Interface.axi_stream(data: 256, keep_unit: 32, user: 4)
      assert {:tkeep, {:u, 8}, :fwd} in i.fields
      assert {:tkeep, {:u, 32}, :fwd} in Interface.axi_stream(data: 256).fields

      refute Enum.any?(
               Interface.axi_stream(data: 48, keep_unit: 32).fields,
               &(elem(&1, 0) == :tkeep)
             )
    end

    @tag :verilator
    test "1: zext of a nested mux of constants lints (already fixed, kept)" do
      lint!(
        module "repro_zext_mux" do
          be = input(:be, 4)
          n = input(:n, 3)
          y = output(:y, 5)

          y
          <~ sub_wrap(
            cat([n, const(0, 2)]),
            zext(mux(be[0], const(0, 2), mux(be[1], const(1, 2), const(3, 2))), 5)
          )
        end
      )
    end
  end

  # -- ex_ptp ----------------------------------------------------------------------------

  describe "ex_ptp" do
    defp cdc_top do
      module "cdc_top" do
        domain(:sys)
        domain(:mac, clock: :clk_mac, reset: :rst_mac_n)
        x = input(:x, 8, domain: :sys)
        p = input(:p, 1, domain: :sys)
        lvl = input(:lvl, 1, domain: :async)
        q = output(:q, 8)
        o = output(:o, 1)
        l = output(:l, 1)
        tag_hold = reg(:tag_hold, 8, domain: :sys)
        c_tag = reg(:c_tag, 8, domain: :mac, cdc: true)

        sync :sys do
          tag_hold <~ x
        end

        sync :mac do
          c_tag <~ tag_hold
        end

        ps = instance(:u_ps, CDC.pulse_sync(), domains: [src: :sys, dst: :mac])
        ps.pulse_in <~ p
        o <~ ps.pulse_out
        sf = instance(:u_sf, CDC.sync_ff(), domains: [dst: :mac])
        sf.d <~ lvl
        l <~ sf.q
        q <~ c_tag
      end
    end

    test "CDC.paths lists every crossing for set_max_delay" do
      assert CDC.paths(cdc_top()) == [
               %{
                 to: "c_tag",
                 to_clock: "clk_mac",
                 from: "tag_hold",
                 from_kind: :reg,
                 from_clock: "clk",
                 kind: :cdc
               },
               %{
                 to: "u_ps/s0",
                 to_clock: "clk_mac",
                 from: "u_ps/toggle",
                 from_kind: :reg,
                 from_clock: "clk",
                 kind: :async_reg
               },
               %{
                 to: "u_sf/s0",
                 to_clock: "clk_mac",
                 from: "lvl",
                 from_kind: :port,
                 from_clock: nil,
                 kind: :async_reg
               }
             ]

      fifo = ExHdl.Test.RTLDesigns.async_fifo()
      paths = CDC.paths(fifo)
      assert paths != []
      assert Enum.all?(paths, &(&1.from_clock != &1.to_clock))
      assert Enum.all?(paths, &(&1.kind == :async_reg))
    end

    @tag :verilator
    test "1: unused and partly read instance outputs lint (already fixed, kept)" do
      child =
        module "c_two" do
          a = input(:a, 4)
          x = output(:x, 4)
          y = output(:y, 4)
          x <~ a
          y <~ a
        end

      lint!(
        module "t_partial" do
          a = input(:a, 4)
          q = output(:q, 2)
          u = instance(:u, child, connect: [a: a])
          q <~ u.x[0..1]
        end
      )
    end

    @tag :yosys
    test "4: negation of a signed value parses in Yosys (already fixed, kept)" do
      m =
        module "neg_signed" do
          a = input(:a, s(32))
          q = output(:q, 33)
          q <~ as_unsigned(-a)
        end

      assert {:ok, _} = ExHdl.Synth.Yosys.utilization(SV.generate(m), "neg_signed")
    end
  end
end
