defmodule ExHdl.RTL.Sim.VCD do
  @moduledoc false
  # Value change dump of a simulator trace. Hierarchy follows the dotted
  # signal paths; clocks fall half a period after each rising edge.

  alias ExHdl.RTL.Expr

  def render(sim, opts) do
    trace = ExHdl.RTL.Sim.trace(sim)
    clocks = MapSet.new(sim.flat.clocks)

    sigs =
      sim.flat.sigs
      |> Enum.filter(fn {id, s} -> s.kind != :clock or MapSet.member?(clocks, id) end)
      |> Enum.sort()

    codes = sigs |> Enum.with_index() |> Map.new(fn {{id, _}, i} -> {id, code(i)} end)
    widths = Map.new(sigs, fn {id, s} -> {id, Expr.width(s.type)} end)
    timescale = Keyword.get(opts, :timescale, "1ns")

    header = [
      "$version ExHdl.RTL.Sim $end\n",
      "$timescale #{timescale} $end\n",
      scopes(sim.module.name, sigs, codes),
      "$enddefinitions $end\n"
    ]

    # rising clocks come from the trace, falling edges half a period later
    falls =
      for {t, fire, _} <- trace, c <- fire do
        {period, _} = sim.periods[c]
        {t + max(div(period, 2), 1), c}
      end

    events =
      (Enum.map(trace, fn {t, fire, snap} -> {t, 0, Map.merge(snap, Map.new(fire, &{&1, 1}))} end) ++
         Enum.map(falls, fn {t, c} -> {t, 1, %{c => 0}} end))
      |> Enum.sort_by(fn {t, k, _} -> {t, k} end)
      |> Enum.chunk_by(&elem(&1, 0))
      |> Enum.map(fn [{t, _, _} | _] = same ->
        {t, 0, Enum.reduce(same, %{}, &Map.merge(&2, elem(&1, 2)))}
      end)

    {body, _} =
      Enum.reduce(events, {[], %{}}, fn {t, _, snap}, {out, last} ->
        snap =
          if t == 0 and last == %{}, do: Map.merge(Map.new(clocks, &{&1, 0}), snap), else: snap

        changes =
          for {id, v} <- Enum.sort(snap),
              Map.get(last, id) != v,
              do: value(v, widths[id], codes[id])

        out = if changes == [], do: out, else: [out, "##{t}\n", changes]
        {out, Map.merge(last, snap)}
      end)

    [header, body]
  end

  defp scopes(top, sigs, codes) do
    tree =
      Enum.reduce(sigs, %{}, fn {id, s}, tree ->
        path = String.split(id, ".")
        put_in_tree(tree, path, {id, s})
      end)

    ["$scope module #{top} $end\n", emit_tree(tree, codes), "$upscope $end\n"]
  end

  defp put_in_tree(tree, [leaf], v), do: Map.put(tree, {:leaf, leaf}, v)

  defp put_in_tree(tree, [scope | rest], v),
    do: Map.update(tree, {:scope, scope}, put_in_tree(%{}, rest, v), &put_in_tree(&1, rest, v))

  defp emit_tree(tree, codes) do
    tree
    |> Enum.sort()
    |> Enum.map(fn
      {{:leaf, name}, {id, s}} ->
        "$var wire #{Expr.width(s.type)} #{codes[id]} #{name} $end\n"

      {{:scope, name}, sub} ->
        ["$scope module #{name} $end\n", emit_tree(sub, codes), "$upscope $end\n"]
    end)
  end

  defp value(v, 1, code), do: "#{Expr.raw(v, {:u, 1})}#{code}\n"

  defp value(v, w, code) do
    bits = v |> Expr.raw({:u, w}) |> Integer.to_string(2)
    "b#{bits} #{code}\n"
  end

  # Identifier codes from the printable ASCII range.
  defp code(i) when i < 94, do: <<33 + i>>
  defp code(i), do: code(div(i, 94) - 1) <> <<33 + rem(i, 94)>>
end
