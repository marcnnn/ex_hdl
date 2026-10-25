defmodule ExHdl.Frame do
  @moduledoc """
  Hardware for `:frame` blocks (`%NxFixed.Block{kind: :frame}`).

  Linear frame kernels (decimating and interpolating FIRs, rational
  resamplers, polyphase filter banks) are recognised from their Nx graph:
  `analyze/2` traces the kernel on one period of `d` items
  (`rate: {d, l}`) and evaluates it on affine forms
  (`ExHdl.Frame.Linear`). The state must be a delay line of the input
  (the next state is the newest items of line and frame), and every
  output an exact sum of products of constant taps and window items,
  rounded once (shift with an optional rounding constant) and
  saturated. That gives an `ExHdl.IR.Multirate`, which
  `ExHdl.Backends.SystemVerilog.Polyphase` turns into a streaming module.
  The kernel's function is not inspected otherwise, so any frame kernel
  of this form generates.
  """

  import Bitwise

  alias ExHdl.Frame.Linear
  alias ExHdl.IR.Multirate
  alias NxFixed.Block

  defmodule Error do
    defexception [:message]
  end

  @doc """
  Recognises the linear multirate structure of a frame block. Returns
  `{:ok, %ExHdl.IR.Multirate{}}` or `{:error, %ExHdl.Frame.Error{}}`.
  """
  def analyze(block, opts \\ [])

  def analyze(%Block{kind: :frame, rate: {d, l}} = block, _opts)
      when is_integer(d) and is_integer(l) do
    format = Keyword.get(block.opts, :format)
    x = ExHdl.Block.frame_template(block, d)
    state = template(block.init)
    expr = Nx.Defn.debug_expr(block.fun) |> apply([x, state | block.params] ++ [block.opts])

    with {:ok, {out, _next}} <- shape(expr),
         {:ok, values} <- linear(expr) do
      {out_v, next_v} = values
      in_leaves = leaves(x)
      state_leaves = leaves(state)
      n_in = length(in_leaves)

      cond do
        format == nil or format.kind != :fixed ->
          error("#{block.name}: hardware needs a fixed-point :format")

        length(state_leaves) != n_in ->
          error(
            "#{block.name}: the state is not a delay line of the input (#{length(state_leaves)} state leaves, #{n_in} input leaves)"
          )

        true ->
          build(block, d, l, in_leaves, state_leaves, leaves(out), out_v, next_v)
      end
    end
  rescue
    e in Linear.NotLinear -> error("#{block.name}: not a linear frame kernel: #{e.message}")
  end

  def analyze(%Block{name: name, kind: kind, rate: rate}, _opts),
    do:
      error(
        "#{name}: #{inspect(kind)} block with rate #{inspect(rate)} is not a fixed-rate frame block"
      )

  @doc """
  Generates the streaming module of a linear frame block: `analyze/2`,
  then `ExHdl.Backends.SystemVerilog.Polyphase.generate/2` (options
  `:name`, default the block name, and `:structure`). Returns
  `{:ok, %ExHdl.Backends.SystemVerilog.Scan.Design{}}` or `{:error, %Error{}}`.
  """
  def to_sv(%Block{} = block, opts \\ []) do
    opts = Keyword.put_new(opts, :name, Atom.to_string(block.name))

    with {:ok, ir} <- analyze(block, opts) do
      {:ok, ExHdl.Backends.SystemVerilog.Polyphase.generate(ir, opts)}
    end
  end

  defp error(message), do: {:error, %Error{message: message}}

  defp shape({_out, _next} = expr), do: {:ok, expr}
  defp shape(_), do: error("the frame kernel must return {output, next_state}")

  defp linear(expr), do: {:ok, Linear.eval(expr)}

  defp template(container),
    do: Nx.Defn.Composite.traverse(container, &Nx.to_template(Nx.tensor(&1)))

  defp leaves(container), do: Nx.Defn.Composite.flatten_list([container])

  defp flat_values(v) when is_tuple(v) and not is_map(v),
    do: v |> Tuple.to_list() |> Enum.flat_map(&flat_values/1)

  defp flat_values(%{elems: _} = v), do: [v]
  defp flat_values(%NxFixed.Fixed{t: t}), do: flat_values(t)

  defp flat_values(%{} = struct) when is_struct(struct),
    do: struct |> Map.from_struct() |> Map.values() |> Enum.flat_map(&flat_values/1)

  defp flat_values(_), do: []

  defp build(block, d, l, in_leaves, state_leaves, out_leaves, out_v, next_v) do
    n_in = length(in_leaves)
    # parameter index -> {component, time}: inputs 0..n_in-1 (time 0..d-1),
    # state leaves n_in.. (time -h..-1, oldest first)
    hist = Enum.map(state_leaves, &Nx.size/1)

    var_time = fn {p, i} ->
      cond do
        p < n_in -> {p, i}
        p < 2 * n_in -> {p - n_in, i - Enum.at(hist, p - n_in)}
        true -> throw({:param, p})
      end
    end

    ranges =
      for {leaf, p} <- Enum.with_index(in_leaves ++ state_leaves), into: %{} do
        {p, type_range(Nx.type(leaf))}
      end

    next_vals = flat_values(next_v)
    out_vals = flat_values(out_v)

    with :ok <- check_delay_line(block, next_vals, hist, d, var_time),
         {:ok, outputs} <- outputs(block, out_vals, out_leaves, l, var_time, ranges) do
      {anchors, k} = anchors(outputs, d, l)

      outputs =
        Enum.map(outputs, fn o ->
          terms =
            for c <- 0..(n_in - 1),
                taps =
                  for(m <- 0..(l - 1), do: taps(Enum.at(o.forms, m), c, Enum.at(anchors, m), k)),
                Enum.any?(taps, fn t -> Enum.any?(t, &(&1 != 0)) end),
                do: %{input: c, taps: taps}

          o |> Map.delete(:forms) |> Map.put(:terms, terms)
        end)

      inputs =
        Enum.map(in_leaves, fn leaf ->
          {lo, hi} = type_range(Nx.type(leaf))
          %{type: Nx.type(leaf), lo: lo, hi: hi}
        end)

      init =
        for {leaf, h} <- Enum.zip(state_init_leaves(block), hist) do
          line = leaf |> Nx.tensor() |> Nx.to_flat_list()
          # x[-1 - j] is line[h - 1 - j]
          for j <- 0..(k - 1), do: if(j < h, do: Enum.at(line, h - 1 - j), else: 0)
        end

      {:ok,
       %Multirate{
         d: d,
         l: l,
         anchors: anchors,
         k: k,
         inputs: inputs,
         outputs: outputs,
         init: init
       }}
    end
  catch
    {:param, p} ->
      error("#{block.name}: the output depends on parameter #{p}, which is not input or state")
  end

  defp state_init_leaves(block), do: leaves(block.init) |> Enum.map(&Nx.tensor/1)

  # next state leaf c, element i must be the window item at time d - h + i
  defp check_delay_line(block, next_vals, hist, d, var_time) do
    ok =
      length(next_vals) == length(hist) and
        Enum.all?(Enum.zip([next_vals, hist, Enum.to_list(0..(length(hist) - 1))]), fn {v, h, c} ->
          v.elems
          |> Tuple.to_list()
          |> Enum.with_index()
          |> Enum.all?(fn {e, i} ->
            case e do
              %{} = m when map_size(m) == 1 ->
                case Map.to_list(m) do
                  [{{_, _} = var, 1}] -> var_time.(var) == {c, d - h + i}
                  _ -> false
                end

              _ ->
                false
            end
          end)
        end)

    if ok,
      do: :ok,
      else:
        error(
          "#{block.name}: the next state is not the input's delay line (newest items of line and frame)"
        )
  end

  # every output element: clip(shr(affine, k), lo, hi), parts optional
  defp outputs(block, out_vals, out_leaves, l, var_time, ranges) do
    Enum.zip(out_vals, out_leaves)
    |> Enum.reduce_while({:ok, []}, fn {v, leaf}, {:ok, acc} ->
      elems = Tuple.to_list(v.elems)
      type = Nx.type(leaf)
      {tlo, thi} = type_range(type)

      if length(elems) != l do
        {:halt,
         error("#{block.name}: output leaf has #{length(elems)} items per period, rate says #{l}")}
      else
        parsed = Enum.map(elems, &post/1)

        case Enum.uniq_by(parsed, fn {_, shift, lo, hi} -> {shift, lo, hi} end) do
          [{_, shift, lo, hi}] ->
            lo = max(lo || tlo, tlo)
            hi = min(hi || thi, thi)

            forms =
              for {form, _, _, _} <- parsed do
                for {key, coeff} <- form, into: %{} do
                  case key do
                    :c -> {:c, coeff}
                    var -> {var_time.(var), coeff}
                  end
                end
              end

            consts = forms |> Enum.map(&Map.get(&1, :c, 0)) |> Enum.uniq()

            # without a clip the value must fit the output type
            fits =
              Enum.all?(parsed, fn {form, s, clo, chi} ->
                {a, b} = Linear.range(form, ranges)
                (clo != nil and chi != nil) or (a >>> s >= tlo and b >>> s <= thi)
              end)

            cond do
              length(consts) != 1 ->
                {:halt, error("#{block.name}: different constants per output phase")}

              not fits ->
                {:halt,
                 error("#{block.name}: an output can leave its type's range without saturation")}

              true ->
                o = %{type: type, forms: forms, const: hd(consts), shift: shift, lo: lo, hi: hi}
                {:cont, {:ok, acc ++ [o]}}
            end

          _ ->
            {:halt, error("#{block.name}: output phases round or saturate differently")}
        end
      end
    end)
  end

  defp post({:clip, inner, lo, hi}) do
    {form, shift, _, _} = post(inner)
    {form, shift, lo, hi}
  end

  defp post({:shr, %{} = form, k}), do: {form, k, nil, nil}
  defp post(%{} = form), do: {form, 0, nil, nil}

  defp post(other),
    do:
      raise(Linear.NotLinear, "output is not one rounding of a sum: #{inspect(other, limit: 5)}")

  # Anchor of output m: its newest input with a non-zero tap over all
  # components, at least 0 (no output before the first input of its
  # period), made non-decreasing. k covers the oldest tap of any output.
  defp anchors(outputs, d, l) do
    newest =
      for m <- 0..(l - 1) do
        outputs
        |> Enum.flat_map(fn o ->
          Enum.at(o.forms, m) |> Map.keys() |> Enum.reject(&(&1 == :c))
        end)
        |> Enum.map(fn {_, t} -> t end)
        |> Enum.max(fn -> nil end)
      end

    # outputs without taps take the anchor of the next one with taps
    filled =
      newest
      |> Enum.reverse()
      |> Enum.map_reduce(nil, fn
        nil, next -> {next, next}
        a, _ -> {a, a}
      end)
      |> elem(0)
      |> Enum.reverse()
      |> Enum.map(&max(&1 || 0, 0))

    {anchors, _} = Enum.map_reduce(filled, 0, fn a, prev -> {max(a, prev), max(a, prev)} end)
    anchors = Enum.map(anchors, &min(&1, d - 1))

    oldest =
      for {m, a} <- Enum.with_index(anchors) |> Enum.map(fn {a, m} -> {m, a} end),
          o <- outputs,
          {{_, t}, _} <- Enum.at(o.forms, m) |> Map.delete(:c),
          do: a - t

    {anchors, max(Enum.max(oldest, fn -> 0 end) + 1, 1)}
  end

  defp taps(form, c, anchor, k), do: for(j <- 0..(k - 1), do: Map.get(form, {c, anchor - j}, 0))

  defp type_range({:s, b}), do: {-(1 <<< (b - 1)), (1 <<< (b - 1)) - 1}
  defp type_range({:u, b}), do: {0, (1 <<< b) - 1}
end
