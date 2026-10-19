defmodule ExHdl.Test.SdrCases do
  @moduledoc false
  # ex_sdr's shared DSP cases (test/dsp_cases/*.json) as stream kernels:
  # the block, its fixed-point instances, and the GNU Radio comparison input
  # (test/fixtures/gnuradio/<case>/input.s16le).

  alias NxFixed.Num

  @root Mix.Project.deps_paths()[:ex_sdr]

  def case_paths,
    do: @root |> Path.join("test/dsp_cases/*.json") |> Path.wildcard() |> Enum.sort()

  def read_case(path), do: path |> File.read!() |> JSON.decode!()

  def format(%{"bits" => bits, "frac" => frac} = f),
    do: Num.q(bits, frac, rounding: String.to_atom(f["rounding"]), lut_bits: f["lut_bits"] || 10)

  @doc "Q15 input integers of the case: a list, or `{re, im}` lists for complex input."
  def input(case) do
    path = Path.join([@root, "test/fixtures/gnuradio", case["name"], "input.s16le"])
    ints = for <<v::little-signed-16 <- File.read!(path)>>, do: v

    if case["input"]["type"] == "complex" do
      ints |> Enum.chunk_every(2) |> Enum.map(&List.to_tuple/1) |> Enum.unzip()
    else
      ints
    end
  end

  @doc """
  The case's block instantiated in `format`: `%{fun, samples, state, params,
  kernel_opts, args}` where `samples` is stacked (sample index first) and
  `args` are the templates for `ExHdl.DSP.analyze_scan/3`.
  """
  def kernel(case, format, input \\ nil) do
    %{"block" => block, "params" => params} = case
    input = input || input(case)
    args = Enum.map(block["args"] || [], &arg(&1, params, format))
    opts = Enum.map(block["opts"] || %{}, fn {k, v} -> {String.to_atom(k), value(v, params)} end)
    fun = Function.capture(ExSdr.DSP.Blocks, String.to_atom(block["name"]), 3 + length(args))

    samples =
      case input do
        {re, im} -> {samples(re, format), samples(im, format)}
        ints -> samples(ints, format)
      end

    state = state(block["state"], params, format)
    kernel_opts = [format: format] ++ opts

    sample_template =
      Nx.Defn.Composite.traverse(samples, fn t ->
        Nx.template(t.shape |> Tuple.delete_at(0), t.type)
      end)

    template = &Nx.Defn.Composite.traverse(&1, fn t -> Nx.to_template(t) end)

    %{
      fun: fun,
      samples: samples,
      state: state,
      params: args,
      kernel_opts: kernel_opts,
      args: [sample_template, template.(state) | Enum.map(args, template)] ++ [kernel_opts]
    }
  end

  @doc "Flat integer lists, one per tensor leaf of a container."
  def leaf_ints(container),
    do: [container] |> Nx.Defn.Composite.flatten_list() |> Enum.map(&Nx.to_flat_list/1)

  defp samples(ints, format), do: Num.from_int(Nx.tensor(ints, type: :s16), 15, format)

  defp arg(%{"phase" => p}, params, _format), do: Nx.tensor(value(p, params), type: :u16)
  defp arg(%{"real" => p}, params, format), do: Num.constant(value(p, params), format)

  defp state(%{"zeros" => n, "complex" => true}, _params, format),
    do: {Num.zeros({n}, format), Num.zeros({n}, format)}

  defp state(%{"zeros" => n}, _params, format), do: Num.zeros({n}, format)
  defp state(spec, params, format), do: arg(spec, params, format)

  defp value(name, params) when is_binary(name), do: Map.fetch!(params, name)
  defp value(v, _params), do: v
end
