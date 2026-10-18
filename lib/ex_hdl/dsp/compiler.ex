defmodule ExHdl.DSP.Compiler do
  @moduledoc """
  `Nx.Defn.Compiler` that refuses to run kernels that can overflow.

  It runs `ExHdl.Passes.WidthCheck` on the traced graph and then evaluates it
  with `Nx.Defn.Evaluator`, which makes it the bit-exact Elixir reference:

      Nx.Defn.jit(&MySDR.DSP.ddc_step/4, compiler: ExHdl.DSP.Compiler).(...)

  Extra options: `:param_ranges` (see `ExHdl.Passes.WidthCheck.run/2`).
  """
  @behaviour Nx.Defn.Compiler

  @own_opts [:param_ranges, :case_split, :split_threshold, :split_budget]

  @impl true
  def __jit__(key, vars, fun, args_list, opts), do: __compile__(key, vars, fun, opts).(args_list)

  @impl true
  def __compile__(key, vars, fun, opts) do
    {own, opts} = Keyword.split(opts, @own_opts)

    case ExHdl.DSP.analyze_expr(fun.(vars), own) do
      {:ok, _graph} -> Nx.Defn.Evaluator.__compile__(key, vars, fun, opts)
      {:error, error} -> raise error
    end
  end

  @impl true
  def __shard_jit__(key, mesh, vars, fun, args_list, opts) do
    {own, opts} = Keyword.split(opts, @own_opts)
    {:ok, _} = ExHdl.DSP.analyze_expr(fun.(vars), own)
    Nx.Defn.Evaluator.__shard_jit__(key, mesh, vars, fun, args_list, opts)
  end

  @impl true
  def __partitions_options__(opts),
    do: Nx.Defn.Evaluator.__partitions_options__(Keyword.drop(opts, @own_opts))

  @impl true
  def __to_backend__(opts), do: Nx.Defn.Evaluator.__to_backend__(Keyword.drop(opts, @own_opts))
end
