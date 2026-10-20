defmodule ExHdl.Protocol.Layout do
  @moduledoc """
  Enumerates the header layouts ("paths") of a packet spec, as a hardware
  parser sees them.

  A path is one way through the layer graph: which layers follow each other,
  where each starts and how long it is. Header-length fields (IPv4 IHL) are
  enumerated over their valid values, so every step of a path has a constant
  start and size, and every field a constant byte position. A path holds the
  conditions on field values that select it:

    * `{:in, values}` / `{:not_in, values}` for `next:` selectors (the latter
      for `default:` branches)
    * `{:eq, value}` for header-length fields

  Paths are mutually exclusive: two paths share a prefix and then differ in
  the condition on one field. The SystemVerilog backend matches all paths in
  parallel; their number grows with the product of the choices, so it is
  capped at #{4096}.
  """
  alias ExHdl.Protocol.{Layer, Spec}

  @max_paths 4096

  defmodule Step do
    @moduledoc "One layer instance on a path: `inst` is `{layer, index}`."
    defstruct [:inst, :layer, :start, :hlen]
  end

  defmodule Path do
    @moduledoc "A header layout: steps in wire order, conditions, payload offset in bytes."
    defstruct [:id, :steps, :conds, :payload]
  end

  @doc "All paths of the spec, in a deterministic order."
  def paths(%Spec{} = spec) do
    root = hd(spec.layers)

    spec
    |> walk(root, %{}, 0, [], [])
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn {{steps, conds, p}, i} ->
      %Path{id: i, steps: Enum.reverse(steps), conds: Enum.reverse(conds), payload: p}
    end)
  end

  defp walk(spec, %Layer{} = l, counts, offset, steps, conds, acc \\ []) do
    idx = Map.get(counts, l.name, 0)

    if idx >= l.max do
      acc
    else
      counts = Map.put(counts, l.name, idx + 1)
      inst = {l.name, idx}

      Enum.reduce(hlen_choices(l), acc, fn {hlen, hconds}, acc ->
        step = %Step{inst: inst, layer: l, start: offset, hlen: hlen}
        hconds = Enum.map(hconds, fn {f, c} -> {inst, offset, f, c} end)
        steps = [step | steps]
        conds = Enum.reverse(hconds, conds)
        next_offset = offset + hlen

        Enum.reduce(branches(l), acc, fn {target, cond}, acc ->
          conds =
            case cond do
              nil -> conds
              {f, c} -> [{inst, offset, f, c} | conds]
            end

          case target do
            :payload ->
              if length(acc) >= @max_paths,
                do: Spec.fail!(spec.name, "more than #{@max_paths} header layouts")

              [{steps, conds, next_offset} | acc]

            name ->
              walk(spec, Spec.layer(spec, name), counts, next_offset, steps, conds, acc)
          end
        end)
      end)
    end
  end

  defp hlen_choices(%Layer{hlen_field: nil} = l), do: [{l.fixed_bytes, []}]

  defp hlen_choices(%Layer{} = l) do
    f = Layer.field(l, l.hlen_field)

    for v <- 0..(Bitwise.bsl(1, f.bits) - 1),
        v * f.header_length >= l.fixed_bytes,
        do: {v * f.header_length, [{f.name, {:eq, v}}]}
  end

  # {target, condition}: one branch per distinct target, then the default.
  defp branches(%Layer{next: nil}), do: [{:payload, nil}]

  defp branches(%Layer{next: {f, cases}, default: default}) do
    by_target =
      cases
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
      |> Enum.sort_by(fn {t, _} -> Enum.find_index(cases, &(elem(&1, 1) == t)) end)

    listed = for {t, vals} <- by_target, do: {t, {f, {:in, vals}}}
    all = Enum.map(cases, &elem(&1, 0))

    cond do
      default == :reject -> listed
      all == [] -> [{default, nil}]
      true -> listed ++ [{default, {f, {:not_in, all}}}]
    end
  end

  @doc "Largest payload offset (header bytes) over all paths."
  def max_header_bytes(paths), do: paths |> Enum.map(& &1.payload) |> Enum.max()

  @doc "Instances `{layer, index}` that occur on some path, in first-seen order."
  def instances(paths) do
    paths
    |> Enum.flat_map(fn p -> Enum.map(p.steps, & &1.inst) end)
    |> Enum.uniq()
    |> Enum.sort_by(fn {l, i} -> {first_pos(paths, {l, i}), i} end)
  end

  defp first_pos(paths, inst) do
    paths
    |> Enum.flat_map(fn p -> Enum.map(p.steps, &{&1.inst, &1.start}) end)
    |> Enum.filter(&(elem(&1, 0) == inst))
    |> Enum.map(&elem(&1, 1))
    |> Enum.min()
  end

  @doc false
  # Checks that need the layer graph: every layer is reachable, a layer with a
  # segment checksum is directly followed by the payload, pseudo-header
  # layers precede it on every path.
  def validate!(%Spec{} = spec) do
    paths = paths(spec)
    if paths == [], do: Spec.fail!(spec.name, "no header layout reaches the payload")

    used =
      paths |> Enum.flat_map(fn p -> Enum.map(p.steps, &elem(&1.inst, 0)) end) |> MapSet.new()

    for l <- spec.layers,
        not MapSet.member?(used, l.name),
        do: Spec.fail!(spec.name, "layer #{inspect(l.name)} is not reachable")

    for p <- paths, {step, i} <- Enum.with_index(p.steps), f <- step.layer.fields do
      if f.checksum == :segment do
        if i != length(p.steps) - 1 or step.layer.hlen_field != nil,
          do:
            Spec.fail!(
              spec.name,
              "field #{inspect(f.name)}: a segment checksum needs a fixed-size layer " <>
                "directly before the payload"
            )

        for {lname, _} <- Enum.filter(f.pseudo, &is_tuple/1),
            not Enum.any?(Enum.take(p.steps, i), &(elem(&1.inst, 0) == lname)),
            do:
              Spec.fail!(
                spec.name,
                "field #{inspect(f.name)}: pseudo layer #{inspect(lname)} missing on a path"
              )
      end
    end

    :ok
  end
end
