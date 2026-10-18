defmodule ExHdl.Test.SetLaws do
  @moduledoc """
  Turns `ExHdl.Types.Laws` into properties for one algebra:

      use ExHdl.Test.SetLaws, algebra: MyAlgebra, max_runs: 100, budget_ms: 1_000

  The using module defines `types/0` (generator of `ExHdl.Types.Expr`) and
  `values/0`. A law fails if it does not hold or if evaluating it exceeds
  the time budget. StreamData shrinks the failing case, and the minimal one
  is written as a standalone script to `_build/<env>/type_findings/`.
  """
  use ExUnitProperties
  import ExUnit.Assertions
  alias ExHdl.Types.Laws

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnitProperties
      @alg Keyword.fetch!(opts, :algebra)
      @max_runs String.to_integer(
                  System.get_env("LAW_RUNS") || to_string(Keyword.get(opts, :max_runs, 100))
                )
      @budget Keyword.get(opts, :budget_ms, 1_000)
      @moduletag timeout: 600_000

      for {name, prop} <- ExHdl.Types.Laws.all() do
        @law_name name
        @law prop
        property "law #{name}" do
          ExHdl.Test.SetLaws.check_law(
            @alg,
            @law_name,
            @law,
            types(),
            values(),
            @max_runs,
            @budget
          )
        end
      end
    end
  end

  @marker "----- reproducer -----"

  def check_law(alg, name, prop, types, values, max_runs, budget) do
    gens = Map.new(Laws.type_vars(prop), &{&1, types})
    gens = if Laws.value?(prop), do: Map.put(gens, :v, values), else: gens

    env_gen =
      if Laws.congruence?(name) do
        # :b is a semantics-preserving rewrite of :a.
        gens
        |> Map.delete(:b)
        |> Map.put(:rewrite, ExHdl.Test.TypeGen.rewrites(types))
        |> fixed_map()
      else
        fixed_map(gens)
      end

    try do
      check all env <- env_gen, max_runs: max_runs do
        task = Task.async(fn -> Laws.holds?(prop, alg, env) end)

        case Task.yield(task, budget) || Task.shutdown(task, :brutal_kill) do
          {:ok, true} -> :ok
          {:ok, false} -> flunk(report(alg, name, prop, env, "does not hold"))
          {:exit, reason} -> flunk(report(alg, name, prop, env, "crashed: #{inspect(reason)}"))
          nil -> flunk(report(alg, name, prop, env, "exceeded the #{budget} ms budget"))
        end
      end
    rescue
      error in [ExUnit.AssertionError] ->
        save_reproducer(alg, name, error.message)
        reraise error, __STACKTRACE__
    end
  end

  defp report(alg, name, prop, env, problem) do
    """
    #{inspect(alg)}: law #{name} #{problem}
    #{@marker}
    #{Laws.reproducer(name, prop, alg, env, problem)}#{@marker}
    """
  end

  defp save_reproducer(alg, name, message) do
    case String.split(message, @marker) do
      [_, script | _] ->
        dir = Path.join(Mix.Project.build_path(), "type_findings")
        File.mkdir_p!(dir)
        alg_name = alg |> Module.split() |> List.last() |> Macro.underscore()
        File.write!(Path.join(dir, "#{alg_name}_#{name}.exs"), String.trim_leading(script))

      _ ->
        :ok
    end
  end
end
