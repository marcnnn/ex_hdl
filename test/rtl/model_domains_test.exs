defmodule ExHdl.RTL.ModelDomainsTest do
  use ExUnit.Case, async: true
  use ExHdl.RTL

  alias ExHdl.RTL.Sim

  defmodule TwoPorts do
    @moduledoc false
    @behaviour ExHdl.RTL.Model
    def init(_params), do: {0, 0}
    def outputs({a, b}, _inputs), do: %{qa: a, qb: b}
    def clock(:a, {a, b}, _inputs), do: {a + 1, b}
    def clock(:b, {a, b}, _inputs), do: {a, b + 2}
  end

  defp top do
    box =
      black_box "two_ports", model: TwoPorts do
        domain(:a, reset: nil)
        domain(:b, reset: nil)
        output(:qa, 8, comb_from: :none)
        output(:qb, 8, comb_from: :none)
      end

    module "two_ports_top" do
      domain(:sys, reset: nil)
      qa = output(:qa, 8)
      qb = output(:qb, 8)
      u = instance(:u, box, domains: [a: :sys, b: :sys])
      qa <~ u.qa
      qb <~ u.qb
    end
  end

  for engine <- [:interpret, :compiled] do
    test "a model with two domains on one clock is clocked in both (#{engine})" do
      sim = Sim.new(top(), engine: unquote(engine)) |> Sim.step(3)
      assert {Sim.peek(sim, :qa), Sim.peek(sim, :qb)} == {3, 6}
    end
  end
end
