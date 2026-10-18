defmodule Mix.Tasks.ExHdl.Types.Minimize do
  @shortdoc "Minimizes a type-law reproducer on the current Elixir version"
  @moduledoc """
      mix ex_hdl.types.minimize path/to/finding.exs [--budget 1000]

  Reads the `# case:` line written by the law suite, shrinks the types with
  `ExHdl.Types.Minimize` against the running Elixir version and writes
  `<name>.min.exs` next to the input.
  """
  use Mix.Task
  alias ExHdl.Types.{Laws, Minimize}

  @requirements ["app.config"]

  @impl true
  def run(args) do
    {opts, [path]} = OptionParser.parse!(args, strict: [budget: :integer])
    Mix.Task.run("compile")

    %{law: law, algebra: alg, env: env, problem: problem} =
      path |> File.read!() |> Laws.read_case()

    budget = Keyword.get(opts, :budget, 1_000)

    failing? =
      case problem do
        :slow -> Minimize.slow(law, alg, budget)
        _ -> Minimize.violates(law, alg)
      end

    unless failing?.(env), do: Mix.raise("the case does not fail on Elixir #{System.version()}")

    small = Minimize.minimize(env, failing?)
    note = if problem == :slow, do: "exceeded the #{budget} ms budget", else: "does not hold"
    script = Laws.reproducer(law, Keyword.fetch!(Laws.all(), law), alg, small, note)
    out = String.replace_suffix(path, ".exs", ".min.exs")
    File.write!(out, script)
    Mix.shell().info("cost #{Minimize.cost(env)} -> #{Minimize.cost(small)}, wrote #{out}")
  end
end
