defmodule ExHdl.DVBT.ReedSolomon do
  @moduledoc """
  DVB outer code RS(204, 188, t = 8) (ETSI EN 300 744, 4.3.2): shortened
  from the systematic RS(255, 239) code over GF(2^8) with field polynomial
  `x^8 + x^4 + x^3 + x^2 + 1` and generator `g(x) = (x + l^0)(x + l^1)...(x + l^15)`,
  `l = 0x02`. A 188-byte packet is prefixed with 51 zero bytes, encoded,
  and the zeros are dropped again.

  Reference implementation (exact integer arithmetic); decoding uses
  syndromes, Berlekamp-Massey, Chien search and Forney's algorithm.
  """
  import Bitwise

  @field_poly 0x11D
  @n 255
  @k 239
  @parity 16
  @shortening 51

  # exp/log tables, built at compile time
  {exp, log} =
    Enum.reduce(0..254, {%{}, %{}, 1}, fn i, {exp, log, x} ->
      next = x <<< 1
      next = if next > 0xFF, do: bxor(next, @field_poly), else: next
      {Map.put(exp, i, x), Map.put(log, x, i), next}
    end)
    |> then(fn {exp, log, _} -> {exp, log} end)

  @exp exp |> Enum.sort() |> Enum.map(&elem(&1, 1)) |> List.to_tuple()
  @log log

  @doc "GF(256) multiplication."
  def mul(0, _), do: 0
  def mul(_, 0), do: 0
  def mul(a, b), do: elem(@exp, rem(@log[a] + @log[b], 255))

  @doc "GF(256) division `a / b`, `b != 0`."
  def divide(0, _), do: 0
  def divide(a, b), do: elem(@exp, rem(@log[a] - @log[b] + 255, 255))

  @doc "`l^i` for the primitive element `l = 0x02`."
  def pow_alpha(i), do: elem(@exp, Integer.mod(i, 255))

  def inverse(a), do: divide(1, a)

  # Generator polynomial, highest degree first.
  @generator Enum.reduce(0..(@parity - 1), [1], fn i, g ->
               # g * (x + l^i)
               root = elem(@exp, i)
               shifted = g ++ [0]

               scaled = [
                 0
                 | Enum.map(
                     g,
                     &if(&1 == 0 or root == 0,
                       do: 0,
                       else: elem(@exp, rem(@log[&1] + @log[root], 255))
                     )
                   )
               ]

               Enum.zip_with(shifted, scaled, &bxor/2)
             end)

  def generator, do: @generator

  @doc "Encodes a 188-byte packet into 204 bytes (packet followed by 16 parity bytes)."
  def encode(<<packet::binary-size(188)>>) do
    msg = :binary.copy(<<0>>, @shortening) <> packet
    remainder = poly_mod(:binary.bin_to_list(msg) ++ List.duplicate(0, @parity))
    packet <> :binary.list_to_bin(remainder)
  end

  # Remainder of the polynomial division by the (monic) generator.
  defp poly_mod(coeffs) do
    [_ | g_rest] = @generator
    do_mod(coeffs, g_rest, length(coeffs) - @parity)
  end

  defp do_mod(r, _g, 0), do: r

  defp do_mod([lead | rest], g, steps) do
    rest =
      if lead == 0,
        do: rest,
        else:
          Enum.zip_with(
            rest,
            g ++ List.duplicate(0, length(rest) - length(g)),
            &bxor(&1, mul(lead, &2))
          )

    do_mod(rest, g, steps - 1)
  end

  @doc """
  Decodes a 204-byte codeword. Returns `{:ok, packet, corrected}` with the
  number of corrected bytes, or `{:error, :uncorrectable, packet}` with the
  uncorrected payload.
  """
  def decode(<<codeword::binary-size(204)>>) do
    received = :binary.bin_to_list(:binary.copy(<<0>>, @shortening) <> codeword)
    syndromes = for i <- 0..(@parity - 1), do: eval(received, pow_alpha(i))

    if Enum.all?(syndromes, &(&1 == 0)) do
      {:ok, binary_part(codeword, 0, 188), 0}
    else
      locator = berlekamp_massey(syndromes)
      errors = length(locator) - 1
      # positions: coefficient of x^p is received[n - 1 - p]
      roots = for p <- 0..(@n - 1), eval_low(locator, pow_alpha(-p)) == 0, do: p

      cond do
        length(roots) != errors or errors > div(@parity, 2) ->
          {:error, :uncorrectable, binary_part(codeword, 0, 188)}

        Enum.any?(roots, &(&1 >= @n - @shortening)) ->
          # an "error" in the shortened (always zero) part means failure
          {:error, :uncorrectable, binary_part(codeword, 0, 188)}

        true ->
          omega = syndromes |> poly_mul_low(locator) |> Enum.take(@parity)
          derivative = formal_derivative(locator)

          corrected =
            Enum.reduce(roots, List.to_tuple(received), fn p, acc ->
              x_inv = pow_alpha(-p)
              # Forney with first consecutive root l^0: e = X * Omega(X^-1) / Lambda'(X^-1)
              magnitude =
                mul(pow_alpha(p), divide(eval_low(omega, x_inv), eval_low(derivative, x_inv)))

              idx = @n - 1 - p
              put_elem(acc, idx, bxor(elem(acc, idx), magnitude))
            end)

          bytes = corrected |> Tuple.to_list() |> Enum.drop(@shortening) |> Enum.take(188)
          {:ok, :binary.list_to_bin(bytes), errors}
      end
    end
  end

  # Horner evaluation, coefficients highest degree first.
  defp eval(coeffs, x), do: Enum.reduce(coeffs, 0, fn c, acc -> bxor(mul(acc, x), c) end)

  # Evaluation with coefficients lowest degree first.
  defp eval_low(coeffs, x), do: coeffs |> Enum.reverse() |> eval(x)

  # Error locator Lambda(x) (lowest degree first) from syndromes S_0..S_15.
  defp berlekamp_massey(s) do
    s = List.to_tuple(s)

    {lambda, _b, _l, _m, _bb} =
      Enum.reduce(0..(@parity - 1), {[1], [1], 0, 1, 1}, fn r, {c, b, l, m, bb} ->
        d =
          Enum.reduce(0..l, 0, fn i, acc -> bxor(acc, mul(Enum.at(c, i, 0), elem(s, r - i))) end)

        cond do
          d == 0 ->
            {c, b, l, m + 1, bb}

          2 * l <= r ->
            t = c
            c = poly_sub_shift(c, b, divide(d, bb), m)
            {c, t, r + 1 - l, 1, d}

          true ->
            {poly_sub_shift(c, b, divide(d, bb), m), b, l, m + 1, bb}
        end
      end)

    trim(lambda)
  end

  # c - coef * x^m * b (lowest degree first)
  defp poly_sub_shift(c, b, coef, m) do
    shifted = List.duplicate(0, m) ++ Enum.map(b, &mul(&1, coef))
    len = max(length(c), length(shifted))
    pad = fn p -> p ++ List.duplicate(0, len - length(p)) end
    Enum.zip_with(pad.(c), pad.(shifted), &bxor/2)
  end

  defp poly_mul_low(a, b) do
    for k <- 0..(length(a) + length(b) - 2) do
      Enum.reduce(0..k, 0, fn i, acc -> bxor(acc, mul(Enum.at(a, i, 0), Enum.at(b, k - i, 0))) end)
    end
  end

  # d/dx over GF(2^m): odd-power terms survive.
  defp formal_derivative([_ | rest]) do
    rest |> Enum.with_index(1) |> Enum.map(fn {c, i} -> if rem(i, 2) == 1, do: c, else: 0 end)
  end

  defp trim(p) do
    p |> Enum.reverse() |> Enum.drop_while(&(&1 == 0)) |> Enum.reverse()
  end

  @doc false
  def params, do: %{n: @n, k: @k, parity: @parity, shortening: @shortening}
end
