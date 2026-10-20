defmodule ExHdl.RTL.FsmPartTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  use ExHdl.RTL

  import Bitwise, only: [band: 2, bsl: 2, bsr: 2]

  alias ExHdl.Backends.SystemVerilog.RTL, as: SV
  alias ExHdl.RTL.{Cosim, ElaborationError, Examples, Expr, Sim, WidthError}

  defp burst_stimulus(n, seed) do
    :rand.seed(:exsss, {seed, 9, 9})
    [%{rst_n: 0}] ++ for(_ <- 2..n, do: %{rst_n: 1, start: Enum.random([0, 0, 1])})
  end

  describe "one-hot FSM" do
    test "state register has one bit per state and behaves like binary" do
      oh = Examples.burst_fsm(5, encoding: :one_hot)
      [f] = oh.fsms
      assert f.encoding == :one_hot
      assert f.states == [idle: 1, run: 2, done: 4]
      assert oh.signals[:ctrl_state].type == {:u, 3}

      stim = burst_stimulus(200, 1)
      {_, a} = oh |> Sim.new() |> Sim.run(stim)
      {_, b} = Examples.burst_fsm(5) |> Sim.new() |> Sim.run(stim)
      assert a == b
      assert Enum.any?(a, &(&1.done == 1))
    end

    test "SV states are one-hot localparams, in_state tests a bit" do
      src = SV.module_source(Examples.burst_fsm(3, encoding: :one_hot))
      assert src =~ "localparam logic [2:0] CTRL_DONE = 3'd4;"

      m =
        module "oh_in_state" do
          go = input(:go, 1)
          busy = output(:busy, 1)

          f =
            fsm :f, encoding: :one_hot do
              state(:a, do: if(go, do: goto(:b)))
              state(:b, do: goto(:c))
              state(:c, do: goto(:a))
            end

          busy <~ (in_state(f, :b) or in_state(f, :c))
        end

      assert SV.module_source(m) =~ "f_state[1]"
      {_, out} = m |> Sim.new() |> Sim.run([%{rst_n: 0}, %{rst_n: 1, go: 1}, %{go: 0}, %{}, %{}])
      assert Enum.map(out, & &1.busy) == [0, 0, 1, 1, 0]
    end

    test "unknown encodings are rejected" do
      assert_raise ElaborationError, ~r/encoding must be :binary or :one_hot/, fn ->
        module "bad_enc" do
          fsm :f, encoding: :gray do
            state(:a, do: goto(:a))
          end
        end
      end
    end

    @tag :verilator
    test "co-simulates" do
      Cosim.assert_equivalent(Examples.burst_fsm(4, encoding: :one_hot), burst_stimulus(300, 2))
    end
  end

  describe "part/3" do
    defp part_module(aw, sw, w, signed) do
      t = if signed, do: s(aw), else: aw

      module "part_#{aw}_#{sw}_#{w}_#{signed}" do
        a = input(:a, t)
        sel = input(:sel, sw)
        q = output(:q, w)
        k = output(:k, w)
        q <~ part(a, sel, w)
        k <~ part(a, 3, w)
      end
    end

    defp ref(a, aw, sel, w), do: band(bsr(Expr.raw(a, {:u, aw}), sel), bsl(1, w) - 1)

    test "constant start bits fold to slices and zeros" do
      a = Expr.input_like(:a, 8)
      assert part(a, 0, 8) == a
      assert part(a, 2, 4) == a[2..5]
      assert %Expr{type: {:u, 6}} = part(a, 4, 6)
      assert %Expr{op: :const, args: [0 | _], type: {:u, 3}} = part(a, 9, 3)

      assert_raise WidthError, ~r/start bit must be/, fn ->
        part(a, Expr.input_like(:i, s(3)), 2)
      end
    end

    property "matches a[sel +: w] with zero fill in the BEAM simulator" do
      check all(
              aw <- integer(1..80),
              sw <- integer(1..7),
              w <- integer(1..20),
              signed <- boolean(),
              signed == false or aw >= 2,
              vals <-
                list_of(tuple({integer(0..(bsl(1, aw) - 1)), integer(0..(bsl(1, sw) - 1))}),
                  length: 8
                ),
              max_runs: 60
            ) do
        m = part_module(aw, sw, w, signed)

        stim =
          for {a, sel} <- vals do
            %{a: if(signed, do: Expr.wrap(a, {:s, aw}), else: a), sel: sel}
          end

        {_, out} = m |> Sim.new() |> Sim.run(stim)

        for {{a, sel}, o} <- Enum.zip(vals, out) do
          assert o.q == ref(a, aw, sel, w)
          assert o.k == ref(a, aw, 3, w)
        end
      end
    end

    # three Verilator builds; a cold cache under the parallel suite can need more than 60 s
    @tag :verilator
    @tag timeout: 300_000
    test "co-simulates, including starts beyond the top" do
      for {aw, sw, w, signed} <- [{32, 5, 8, false}, {72, 7, 16, true}, {12, 4, 20, false}] do
        :rand.seed(:exsss, {aw, sw, w})

        stim =
          for _ <- 1..64 do
            a = :rand.uniform(bsl(1, aw)) - 1

            %{
              a: if(signed, do: Expr.wrap(a, {:s, aw}), else: a),
              sel: :rand.uniform(bsl(1, sw)) - 1
            }
          end

        Cosim.assert_equivalent(part_module(aw, sw, w, signed), stim)
      end
    end
  end
end
