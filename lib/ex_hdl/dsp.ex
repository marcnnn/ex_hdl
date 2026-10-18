defmodule ExHdl.DSP do
  @moduledoc """
  Entry point for analysing `defn` kernels.

      ExHdl.DSP.analyze(&MySDR.DSP.ddc_step/4, [
        {Nx.template({}, :s16), Nx.template({}, :s16)},
        Nx.template({}, :u16),
        Nx.template({}, :u16),
        Nx.template({}, :s16)
      ])

  Arguments are passed like to the function itself; tensors may be templates.
  """

  alias ExHdl.IR.Dataflow
  alias ExHdl.Passes.WidthCheck

  defmodule RangeError do
    defexception [:message, :graph, :violations]
  end

  @doc """
  Traces `fun` with `args`, builds the dataflow IR and runs the width check.

  Returns `{:ok, graph}` with every node's `range` set, or
  `{:error, %RangeError{}}`. Options: `:param_ranges`, `:name`.
  """
  def analyze(fun, args, opts \\ []) when is_function(fun) and is_list(args) do
    fun
    |> Nx.Defn.debug_expr()
    |> apply(args)
    |> analyze_expr(opts)
  end

  @doc "Like `analyze/3` but raises `RangeError`."
  def analyze!(fun, args, opts \\ []) do
    case analyze(fun, args, opts) do
      {:ok, graph} -> graph
      {:error, error} -> raise error
    end
  end

  @doc "Runs the analysis on an already traced output expression."
  def analyze_expr(output, opts \\ []) do
    {graph, violations} = output |> Dataflow.from_expr() |> WidthCheck.run(opts)

    case violations do
      [] ->
        {:ok, graph}

      _ ->
        name = Keyword.get(opts, :name, "defn")
        message = WidthCheck.format(graph, violations, name)
        {:error, %RangeError{message: message, graph: graph, violations: violations}}
    end
  end
end
