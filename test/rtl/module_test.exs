defmodule ExHdl.RTL.ModuleTest do
  use ExUnit.Case, async: true
  use ExHdl.RTL

  alias ExHdl.RTL.{DomainError, ElaborationError, Sim, WidthError}

  defp passthrough do
    module "pass" do
      a = input(:a, 8)
      y = output(:y, 8)
      y <~ a
    end
  end

  test "a module gets the :sys domain (clk, rst_n first) when it needs one" do
    m =
      module "regs" do
        x = input(:x, 4)
        q = output(:q, 4, reset: 3)
        sync(do: q <~ x)
      end

    assert Enum.map(m.ports, & &1.name) == [:clk, :rst_n, :x, :q]
    assert [%{name: :sys, reset_kind: :sync, reset_active: :low}] = m.domains
    assert m.signals[:q].reset == 3
    assert m.comb_paths == %{q: []}
  end

  test "a purely combinational module has no domain and records its paths" do
    m = passthrough()
    assert m.domains == []
    assert m.comb_paths == %{y: [:a]}
    assert hd(m.ports).domain == nil
  end

  test "wire/3 names an expression; switch selects on constants" do
    m =
      module "sw" do
        op = input(:op, 2)
        a = input(:a, 8)
        y = output(:y, 8)
        twice = wire(:twice, trunc(a <<< 1, 8))

        comb do
          switch op do
            0 -> y <~ a
            [1, 2] -> y <~ twice
            _ -> y <~ 0
          end
        end
      end

    sim = Sim.new(m)
    assert sim |> Sim.poke(%{op: 0, a: 5}) |> Sim.peek(:y) == 5
    assert sim |> Sim.poke(%{op: 2, a: 200}) |> Sim.peek(:y) == 144
    assert sim |> Sim.poke(%{op: 3, a: 5}) |> Sim.peek(:y) == 0
  end

  test "Elixir values in if/switch select at elaboration time" do
    build = fn invert ->
      module "elab_#{invert}" do
        a = input(:a, 1)
        y = output(:y, 1)

        if invert do
          y <~ not a
        else
          y <~ a
        end
      end
    end

    assert Sim.new(build.(true)) |> Sim.poke(:a, 1) |> Sim.peek(:y) == 0
    assert Sim.new(build.(false)) |> Sim.poke(:a, 1) |> Sim.peek(:y) == 1
  end

  describe "elaboration errors name the problem" do
    test "undriven outputs, wires and instance inputs" do
      assert_raise ElaborationError, ~r/output y is never driven/, fn ->
        module "e1" do
          output(:y, 1)
        end
      end

      assert_raise ElaborationError, ~r/wire w is never driven/, fn ->
        module "e2" do
          wire(:w, 1)
        end
      end

      assert_raise ElaborationError, ~r/input a of instance u is not connected/, fn ->
        module "e3" do
          instance(:u, passthrough())
        end
      end
    end

    test "two drivers" do
      assert_raise ElaborationError, ~r/y is driven from more than one/, fn ->
        module "e4" do
          y = output(:y, 1)
          y <~ 0
          y <~ 1
        end
      end
    end

    test "latches" do
      assert_raise ElaborationError, ~r/y is not assigned on every path.*latch/, fn ->
        module "e5" do
          a = input(:a, 1)
          y = output(:y, 1)

          comb do
            if a, do: y <~ 1
          end
        end
      end
    end

    test "combinational loops, also through instances" do
      assert_raise ElaborationError, ~r/combinational loop/, fn ->
        module "e6" do
          x = wire(:x, 1)
          z = wire(:z, 1)
          x <~ z
          z <~ not x
        end
      end

      assert_raise ElaborationError, ~r/combinational loop through u_y -> u_a -> u_y/, fn ->
        module "e7" do
          u = instance(:u, passthrough())
          u.a <~ u.y
        end
      end
    end

    test "wrong targets" do
      assert_raise ElaborationError, ~r/a is an input and cannot be assigned/, fn ->
        module "e8" do
          a = input(:a, 1)
          a <~ 0
        end
      end

      assert_raise ElaborationError, ~r/register r can only be assigned in sync/, fn ->
        module "e9" do
          r = reg(:r, 1)
          r <~ 1
        end
      end

      assert_raise ElaborationError, ~r/w \(a wire\) assigned in a sync block/, fn ->
        module "e10" do
          w = wire(:w, 1)
          sync(do: w <~ 1)
        end
      end

      assert_raise ElaborationError, ~r/hardware if outside/, fn ->
        module "e11" do
          a = input(:a, 1)
          if a, do: :x
        end
      end
    end

    test "widths in assignments" do
      assert_raise WidthError, ~r/assignment to y: u9 value does not fit u8/, fn ->
        module "e12" do
          a = input(:a, 8)
          y = output(:y, 8)
          y <~ (a + 1)
        end
      end
    end

    test "an assignment used as an operand (precedence)" do
      assert_raise WidthError, ~r/write `y <~ \(a == b\)`/, fn ->
        module "e13" do
          a = input(:a, 1)
          b = input(:b, 1)
          y = output(:y, 1)
          y <~ a == b
        end
      end
    end

    test "names, duplicates, signals of other modules" do
      assert_raise ElaborationError, ~r/invalid signal name :module/, fn ->
        module "e14" do
          input(:module, 1)
        end
      end

      assert_raise ElaborationError, ~r/a is declared twice/, fn ->
        module "e15" do
          input(:a, 1)
          input(:a, 1)
        end
      end

      assert_raise ElaborationError, ~r/signal a of another module is used here/, fn ->
        module "outer" do
          a = input(:a, 1)

          module "inner" do
            y = output(:y, 1)
            y <~ a
          end
        end
      end
    end

    test "different modules with one name" do
      a = passthrough()

      b =
        module "pass" do
          a = input(:a, 8)
          y = output(:y, 8)
          y <~ ~~~a
        end

      top =
        module "top" do
          u = instance(:u, a, connect: [a: 0])
          v = instance(:v, b, connect: [a: 0])
          y = output(:y, 8)
          y <~ (u.y &&& v.y)
        end

      assert_raise ElaborationError, ~r/two different modules are named pass/, fn ->
        ExHdl.Backends.SystemVerilog.RTL.generate(top)
      end
    end
  end

  test "the same generator twice gives equal modules" do
    assert passthrough() == passthrough()
  end

  test "domain errors" do
    assert_raise DomainError, ~r/input x needs domain:/, fn ->
      module "d1" do
        domain(:a)
        domain(:b)
        input(:x, 1)
      end
    end
  end
end
