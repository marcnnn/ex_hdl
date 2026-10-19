defmodule ExHdl.Comm.ReedSolomon do
  @moduledoc """
  Systematic Reed-Solomon codes over GF(2^m), optionally shortened.

      code = ExHdl.Comm.ReedSolomon.new(m: 8, field_poly: 0x11D, n: 255, k: 239,
                                        fcr: 0, prim: 1, shortening: 51)

  The generator has the `n - k` consecutive roots `beta^(fcr + i)`, with
  `beta = alpha^prim`. A shortened code transmits `k - shortening`
  information and `n - k` parity symbols; the leading zeros are implicit.

  Decoding: syndromes, Berlekamp-Massey, Chien search, Forney's algorithm
  (`e = X^(1 - fcr) * Omega(X^-1) / Lambda'(X^-1)`). A codeword is reported
  uncorrectable when the number of roots does not match the locator
  degree, more than `(n - k) / 2` errors are located, or an error falls into
  the shortened part.

  Examples: DVB / DVB-T RS(204, 188) (`field_poly: 0x11D, fcr: 0, prim: 1,
  shortening: 51`), ATSC RS(207, 187), CCSDS RS(255, 223).
  """
  import Bitwise
  alias ExHdl.Comm.GF

  defstruct [:field, :n, :k, :fcr, :prim, :shortening, :generator, :roots]

  def new(opts) do
    opts = Keyword.validate!(opts, [:m, :field_poly, :n, :k, fcr: 0, prim: 1, shortening: 0])
    field = GF.new(opts[:m], opts[:field_poly])
    n = opts[:n]
    k = opts[:k]
    parity = n - k

    unless n <= GF.order(field) and k < n and opts[:shortening] < k,
      do:
        raise(
          ArgumentError,
          "invalid RS(#{n}, #{k}) over GF(2^#{opts[:m]}) with shortening #{opts[:shortening]}"
        )

    roots = for i <- 0..(parity - 1), do: GF.pow(field, opts[:prim] * (opts[:fcr] + i))

    # g(x) = prod (x + root), highest degree first
    generator =
      Enum.reduce(roots, [1], fn root, g ->
        Enum.zip_with(g ++ [0], [0 | Enum.map(g, &GF.mul(field, &1, root))], &bxor/2)
      end)

    %__MODULE__{
      field: field,
      n: n,
      k: k,
      fcr: opts[:fcr],
      prim: opts[:prim],
      shortening: opts[:shortening],
      generator: generator,
      roots: roots
    }
  end

  def parity(%__MODULE__{n: n, k: k}), do: n - k

  @doc "Transmitted codeword length (n minus shortening)."
  def length(%__MODULE__{n: n, shortening: s}), do: n - s

  @doc "Information symbols per (shortened) codeword."
  def message_length(%__MODULE__{k: k, shortening: s}), do: k - s

  @doc "Encodes a list of `k - shortening` symbols: message ++ parity."
  def encode(code, message) when is_list(message) do
    unless Kernel.length(message) == message_length(code),
      do: raise(ArgumentError, "message must have #{message_length(code)} symbols")

    padded = List.duplicate(0, code.shortening) ++ message ++ List.duplicate(0, parity(code))
    [_ | g] = code.generator
    message ++ divide(code.field, padded, g, Kernel.length(padded) - parity(code))
  end

  defp divide(_f, r, _g, 0), do: r

  defp divide(f, [lead | rest], g, steps) do
    rest =
      if lead == 0,
        do: rest,
        else:
          Enum.zip_with(
            rest,
            g ++ List.duplicate(0, Kernel.length(rest) - Kernel.length(g)),
            &bxor(&1, GF.mul(f, lead, &2))
          )

    divide(f, rest, g, steps - 1)
  end

  @doc """
  Decodes a list of `n - shortening` symbols. Returns `{:ok, message,
  corrected}` or `{:error, :uncorrectable, message}` (uncorrected).
  """
  def decode(code, received) when is_list(received) do
    f = code.field
    n = code.n
    t = div(parity(code), 2)
    r = List.duplicate(0, code.shortening) ++ received
    syndromes = for root <- code.roots, do: GF.eval(f, r, root)
    message = Enum.take(received, message_length(code))

    if Enum.all?(syndromes, &(&1 == 0)) do
      {:ok, message, 0}
    else
      locator = berlekamp_massey(f, syndromes)
      errors = Kernel.length(locator) - 1
      beta = fn e -> GF.pow(f, code.prim * e) end
      # X = beta^p for an error at the coefficient of x^p
      positions = for p <- 0..(n - 1), GF.eval_low(f, locator, beta.(-p)) == 0, do: p

      cond do
        Kernel.length(positions) != errors or errors > t ->
          {:error, :uncorrectable, message}

        Enum.any?(positions, &(&1 >= n - code.shortening)) ->
          {:error, :uncorrectable, message}

        true ->
          omega = syndromes |> poly_mul_low(f, locator) |> Enum.take(parity(code))
          derivative = formal_derivative(locator)

          corrected =
            Enum.reduce(positions, List.to_tuple(r), fn p, acc ->
              x_inv = beta.(-p)
              num = GF.mul(f, GF.eval_low(f, omega, x_inv), beta.(p * (1 - code.fcr)))
              magnitude = GF.divide(f, num, GF.eval_low(f, derivative, x_inv))
              idx = n - 1 - p
              put_elem(acc, idx, bxor(elem(acc, idx), magnitude))
            end)

          message =
            corrected
            |> Tuple.to_list()
            |> Enum.drop(code.shortening)
            |> Enum.take(message_length(code))

          {:ok, message, errors}
      end
    end
  end

  @doc "Byte helpers for codes over GF(256)."
  def encode_bytes(%__MODULE__{field: %{m: 8}} = code, message),
    do: code |> encode(:binary.bin_to_list(message)) |> :binary.list_to_bin()

  def decode_bytes(%__MODULE__{field: %{m: 8}} = code, received) do
    case decode(code, :binary.bin_to_list(received)) do
      {:ok, msg, n} -> {:ok, :binary.list_to_bin(msg), n}
      {:error, reason, msg} -> {:error, reason, :binary.list_to_bin(msg)}
    end
  end

  @doc """
  Decodes a binary of whole codewords (GF(256) codes): returns
  `{messages, corrected_symbols, failed_codewords}`, failed codewords
  copied uncorrected. Uses the native kernel when available (same results).
  """
  def decode_all_bytes(%__MODULE__{field: %{m: 8}} = code, codewords) do
    if ExHdl.SIMD.available?() do
      ExHdl.SIMD.NIF.rs_decode(
        codewords,
        code.field.poly,
        code.n,
        code.k,
        code.fcr,
        code.prim,
        code.shortening
      )
    else
      len = __MODULE__.length(code)

      {msgs, c, f} =
        for <<cw::binary-size(len) <- codewords>>, reduce: {[], 0, 0} do
          {acc, c, f} ->
            case decode_bytes(code, cw) do
              {:ok, m, n} -> {[m | acc], c + n, f}
              {:error, _, m} -> {[m | acc], c, f + 1}
            end
        end

      {msgs |> Enum.reverse() |> IO.iodata_to_binary(), c, f}
    end
  end

  # Error locator (lowest degree first) from the syndromes.
  defp berlekamp_massey(f, s) do
    s = List.to_tuple(s)

    {lambda, _, _, _, _} =
      Enum.reduce(0..(tuple_size(s) - 1), {[1], [1], 0, 1, 1}, fn r, {c, b, l, m, bb} ->
        d =
          Enum.reduce(0..l, 0, fn i, acc ->
            bxor(acc, GF.mul(f, Enum.at(c, i, 0), elem(s, r - i)))
          end)

        cond do
          d == 0 -> {c, b, l, m + 1, bb}
          2 * l <= r -> {sub_shift(f, c, b, GF.divide(f, d, bb), m), c, r + 1 - l, 1, d}
          true -> {sub_shift(f, c, b, GF.divide(f, d, bb), m), b, l, m + 1, bb}
        end
      end)

    lambda |> Enum.reverse() |> Enum.drop_while(&(&1 == 0)) |> Enum.reverse()
  end

  defp sub_shift(f, c, b, coef, m) do
    shifted = List.duplicate(0, m) ++ Enum.map(b, &GF.mul(f, &1, coef))
    len = max(Kernel.length(c), Kernel.length(shifted))
    pad = fn p -> p ++ List.duplicate(0, len - Kernel.length(p)) end
    Enum.zip_with(pad.(c), pad.(shifted), &bxor/2)
  end

  defp poly_mul_low(a, f, b) do
    for k <- 0..(Kernel.length(a) + Kernel.length(b) - 2) do
      Enum.reduce(0..k, 0, fn i, acc ->
        bxor(acc, GF.mul(f, Enum.at(a, i, 0), Enum.at(b, k - i, 0)))
      end)
    end
  end

  defp formal_derivative([_ | rest]),
    do: rest |> Enum.with_index(1) |> Enum.map(fn {c, i} -> if rem(i, 2) == 1, do: c, else: 0 end)
end
