defmodule ExHdl.Test.Gen do
  @moduledoc false
  # StreamData generators derived from a packet spec.
  use ExUnitProperties
  import Bitwise
  alias ExHdl.Protocol.Spec

  def int(bits, true), do: integer(-(1 <<< (bits - 1))..((1 <<< (bits - 1)) - 1))
  def int(bits, false), do: integer(0..((1 <<< bits) - 1))

  @doc "Header map for the non-asserted fields."
  def header(%Spec{fields: fields}) do
    fields
    |> Enum.filter(&is_nil(&1.assert))
    |> Map.new(fn f -> {f.name, int(f.bits, f.signed)} end)
    |> fixed_map()
  end

  def payload(%Spec{payload: p}, opts \\ []) do
    elem = int(p.elem_bits, p.signed)
    elem = if p.complex, do: tuple({elem, elem}), else: elem
    list_of(elem, Keyword.merge([min_length: 1, max_length: 64], opts))
  end

  @doc """
  A packet case: `{:good, bin}` or `{:bad, bin}` (bad assert, runt, or header
  without payload). Bad cases are only generated if the kind applies.
  """
  def packet_case(%Spec{} = spec, encode) do
    asserted = Enum.filter(spec.fields, & &1.assert)

    kinds =
      [{6, constant(:good)}, {1, constant(:runt)}, {1, constant(:header_only)}] ++
        if(asserted != [], do: [{2, constant(:bad_assert)}], else: [])

    gen all(
          kind <- frequency(kinds),
          header <- header(spec),
          payload <- payload(spec),
          bad_field <- member_of(if asserted == [], do: [nil], else: asserted),
          cut <- integer(1..(Spec.header_bytes(spec) - 1))
        ) do
      good = encode.(header, payload)

      case kind do
        :good ->
          {:good, good}

        :runt ->
          {:bad, binary_part(good, 0, cut)}

        :header_only ->
          {:bad, binary_part(good, 0, Spec.header_bytes(spec))}

        :bad_assert ->
          # Flip the lowest bit: stays in range and differs from the assert.
          wrong = Bitwise.bxor(bad_field.assert, 1)

          wrong =
            if Spec.fits?(wrong, bad_field.bits, bad_field.signed),
              do: wrong,
              else: bad_field.assert - 1

          {:bad, encode.(Map.put(header, bad_field.name, wrong), payload)}
      end
    end
  end
end
