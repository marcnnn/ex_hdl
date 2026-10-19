defmodule ExHdl.BlockCosimTest do
  @moduledoc """
  ex_sdr's :stream blocks generated from their `%NxFixed.Block{}`
  descriptions (`ExHdl.Block`) and co-simulated against
  `NxFixed.Block.run/4` on random full-range input, bit for bit, with
  random backpressure. The list is `ExHdl.Test.BlockCases.cases/0`; blocks
  that do not generate are listed there with the expected error.
  """
  use ExUnit.Case, async: true

  alias ExHdl.Sim.Verilator
  alias ExHdl.Test.BlockCases, as: C

  @moduletag :verilator
  @moduletag timeout: 600_000

  # {valid_pct, ready_pct, seed}
  @traffic [{100, 100, 1}, {70, 50, 2}, {30, 95, 3}, {95, 20, 4}]

  for c <- C.cases() do
    @case c

    case c.expect do
      :ok ->
        test "#{c.label}: RTL is bit-identical to NxFixed.Block.run" do
          c = @case
          block = C.block(c)
          {:ok, design} = ExHdl.Block.scan_to_sv(block, [name: "blk_" <> c.label] ++ c.gen)
          {:ok, sim} = Verilator.build_stream(design)

          input = C.stimulus(block, c.samples, c.symbols, 11)

          expected =
            case NxFixed.Block.run(block, input) do
              # variable rate, no output item at all
              {nil, _} -> Enum.map(design.outputs, fn _ -> [] end)
              {out, _} -> C.leaf_ints(out)
            end

          refute expected |> List.flatten() |> Enum.uniq() |> length() < 2, "constant output"
          params = C.leaf_ints(List.to_tuple(block.params))

          for {vp, rp, seed} = traffic <- @traffic do
            assert {:ok, res} =
                     Verilator.run_stream(sim, C.leaf_ints(input), params,
                       valid_pct: vp,
                       ready_pct: rp,
                       seed: seed
                     )

            assert res.outputs == expected, "#{c.label}, traffic #{inspect(traffic)}"
          end
        end

      {:error, reason} ->
        @reason reason
        test "#{c.label}: does not generate (#{inspect(reason)})" do
          block = C.block(@case)

          message =
            try do
              case ExHdl.Block.scan_to_sv(block, @case.gen) do
                {:ok, _} -> "generated"
                {:error, e} -> Exception.message(e)
              end
            rescue
              e -> Exception.message(e)
            end

          assert message =~ @reason
        end
    end
  end
end
