defmodule ExHdl.Comm.GF do
  @moduledoc """
  Arithmetic in GF(2^m), 2 <= m <= 16, for a given primitive polynomial
  (e.g. `0x11D` for GF(256) in DVB/CCSDS-style Reed-Solomon codes).
  Elements are integers `0..2^m - 1`; `alpha = 2` is the primitive element.
  Tables are built once per field and cached.
  """
  import Bitwise

  defstruct [:m, :poly, :size, :exp, :log]

  @doc "The field for `m` bits and primitive polynomial `poly` (including the x^m term)."
  def new(m, poly) when m in 2..16 do
    key = {__MODULE__, m, poly}

    case :persistent_term.get(key, nil) do
      nil ->
        size = 1 <<< m

        {exp, log, _} =
          Enum.reduce(0..(size - 2), {[], %{}, 1}, fn i, {exp, log, x} ->
            next = x <<< 1
            next = if next >= size, do: bxor(next, poly), else: next
            {[x | exp], Map.put(log, x, i), next}
          end)

        exp = exp |> Enum.reverse() |> List.to_tuple()

        if map_size(log) != size - 1,
          do:
            raise(
              ArgumentError,
              "polynomial #{inspect(poly, base: :hex)} is not primitive for m = #{m}"
            )

        f = %__MODULE__{m: m, poly: poly, size: size, exp: exp, log: log}
        :persistent_term.put(key, f)
        f

      f ->
        f
    end
  end

  def order(%__MODULE__{size: size}), do: size - 1

  def mul(_f, 0, _), do: 0
  def mul(_f, _, 0), do: 0
  def mul(f, a, b), do: elem(f.exp, rem(f.log[a] + f.log[b], order(f)))

  def divide(_f, 0, _), do: 0
  def divide(f, a, b), do: elem(f.exp, Integer.mod(f.log[a] - f.log[b], order(f)))

  @doc "`alpha^i` (any integer i)."
  def pow(f, i), do: elem(f.exp, Integer.mod(i, order(f)))

  @doc "Horner evaluation, coefficients highest degree first."
  def eval(f, coeffs, x), do: Enum.reduce(coeffs, 0, fn c, acc -> bxor(mul(f, acc, x), c) end)

  @doc "Evaluation with coefficients lowest degree first."
  def eval_low(f, coeffs, x), do: eval(f, Enum.reverse(coeffs), x)
end
