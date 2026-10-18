defmodule ExHdl.DSP.ScanLoop do
  @moduledoc """
  Runs a stream kernel `step(sample, state, params...) -> {output, next_state}`
  over a whole block of samples inside one compiled `while` loop.

  The step function is used unchanged; with a compiler such as EXLA the loop
  body is fused, which is far faster than calling a compiled step per sample.
  Samples and outputs are containers (tuples, `ExHdl.Num.Fixed`, ...) whose
  tensors carry the sample index as their first axis.
  """
  import Nx.Defn
  alias Nx.Defn.Composite

  @doc false
  defn loop(samples, state, params, opts \\ []) do
    opts = keyword!(opts, [:step, :kernel_opts, :outputs, :n])
    n = opts[:n]

    {_, state, outputs, _, _} =
      while {i = 0, state, outputs = zeros(opts[:outputs], n), samples, params}, i < n do
        {y, next} = step(opts[:step], at(samples, i), state, params, opts[:kernel_opts])
        {i + 1, next, put(outputs, y, i), samples, params}
      end

    {outputs, state}
  end

  deftransformp step(fun, sample, state, params, kernel_opts) do
    extra = if kernel_opts, do: [kernel_opts], else: []
    apply(fun, [sample, state | Tuple.to_list(params)] ++ extra)
  end

  deftransformp zeros(templates, n) do
    Composite.traverse(templates, fn t ->
      Nx.broadcast(Nx.tensor(0, type: t.type), Tuple.insert_at(t.shape, 0, n))
    end)
  end

  deftransformp at(samples, i) do
    Composite.traverse(samples, fn t ->
      rank = tuple_size(t.shape)
      starts = [i | List.duplicate(0, rank - 1)]
      lengths = [1 | t.shape |> Tuple.to_list() |> tl()]
      t |> Nx.slice(starts, lengths) |> Nx.squeeze(axes: [0])
    end)
  end

  deftransformp put(outputs, y, i) do
    {outputs, []} =
      Composite.traverse(outputs, Composite.flatten_list([y]), fn out, [v | rest] ->
        starts = [i | List.duplicate(0, tuple_size(v.shape))]
        {Nx.put_slice(out, starts, Nx.new_axis(v, 0)), rest}
      end)

    outputs
  end

  @doc "Stacks a list of sample containers along a new first axis."
  def stack([first | _] = samples) do
    columns = samples |> Enum.map(&Composite.flatten_list([&1])) |> Enum.zip_with(&Nx.stack/1)
    {stacked, []} = Composite.traverse(first, columns, fn _leaf, [col | rest] -> {col, rest} end)
    stacked
  end
end
