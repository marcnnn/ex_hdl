defmodule ExHdl.Regs.Markdown do
  @moduledoc """
  Markdown documentation of an `ExHdl.Regs` map: an address map table,
  then one field table per register.
  """

  alias ExHdl.Regs

  @doc "Markdown text."
  @spec render(Regs.t()) :: String.t()
  def render(%Regs{} = m) do
    rows =
      (Enum.map(m.registers, &{&1.offset, :reg, &1}) ++
         Enum.map(m.windows, &{&1.offset, :win, &1}))
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn
        {_, :reg, r} ->
          off =
            case r.count do
              nil -> hex(r.offset)
              n -> "#{hex(r.offset)} + i * #{hex(r.stride)}, i < #{n}"
            end

          row([off, "`#{r.name}`", "register", hex(Regs.reset_value(m, r.name), 8), text(r.doc)])

        {_, :win, w} ->
          row([
            "#{hex(w.offset)} - #{hex(w.offset + w.size - 1)}",
            "`#{w.name}`",
            "window (#{w.access}, #{div(w.size, 4)} words)",
            "",
            text(w.doc)
          ])
      end)

    regs =
      Enum.map(m.registers, fn r ->
        [
          "\n### #{r.name}\n\n",
          if(r.doc, do: "#{r.doc}\n\n", else: ""),
          "| Bits | Field | Access | Reset | Description |\n|---|---|---|---|---|\n",
          r.fields
          |> Enum.sort_by(& &1.lo, :desc)
          |> Enum.map(fn f ->
            bits =
              if f.width == 1, do: "#{f.lo}", else: "#{f.lo + f.width - 1}:#{f.lo}"

            reset = hex(if(f.const != nil, do: f.const, else: f.reset), div(f.width + 3, 4))

            enum =
              case f.enum do
                [] ->
                  ""

                e ->
                  " Values: " <> Enum.map_join(e, ", ", fn {n, v} -> "#{v} = `#{n}`" end) <> "."
              end

            row([
              "#{bits}",
              "`#{f.name}`",
              "#{f.access}",
              reset,
              String.trim(text(f.doc) <> enum)
            ])
          end)
        ]
      end)

    IO.iodata_to_binary([
      "## Register map `#{m.name}`\n\n",
      if(m.doc, do: "#{m.doc}\n\n", else: ""),
      "AXI4-Lite, 32-bit data, #{m.addr_width}-bit addresses.\n\n",
      "| Offset | Name | Kind | Reset | Description |\n|---|---|---|---|---|\n",
      rows,
      regs
    ])
  end

  defp row(cells), do: "| " <> Enum.join(cells, " | ") <> " |\n"
  defp text(nil), do: ""
  defp text(d), do: d |> String.replace("|", "\\|") |> String.replace("\n", " ")
  defp hex(v, digits \\ 4), do: "0x" <> String.pad_leading(Integer.to_string(v, 16), digits, "0")
end
