defmodule ExHdl.Comm.Convolutional do
  @moduledoc """
  Rate 1/n convolutional codes with optional puncturing, and hard-decision
  Viterbi decoding.

    * `constraint_length` K: the encoder register holds the current input
      (most significant bit) and the K - 1 previous ones, newest first;
      2^(K - 1) states.
    * `polynomials`: one generator per output, octal as standards print
      them (`0o171` has the current input as its leading tap).
    * `puncture`: one 0/1 row per output, all of the same period; per
      step the kept outputs are sent in polynomial order (DVB-T rate 3/4
      `[[1, 0, 1], [1, 1, 0]]` gives X1 Y1 Y2 X3). `nil` keeps everything.

  Bits are lists of 0/1, or binaries of 0/1 bytes for the native kernels
  (K 2..9, n 2..4). The decoder works over a whole block: punctured
  positions and missing bits of an incomplete last period count as
  erasures, ties prefer the predecessor with the smaller state number, and
  the traceback starts at the best end state (smallest number on ties).
  """
  import Bitwise

  defstruct [:k, :polynomials, :puncture, :outputs, :trellis]

  def new(opts) do
    k = Keyword.fetch!(opts, :constraint_length)
    polys = Keyword.fetch!(opts, :polynomials)
    n = length(polys)
    puncture = Keyword.get(opts, :puncture) || List.duplicate([1], n)

    unless k >= 2 and n >= 2 and length(puncture) == n and
             puncture |> Enum.map(&length/1) |> Enum.uniq() |> length() == 1 do
      raise ArgumentError, "needs K >= 2, n >= 2 outputs and one puncturing row per output"
    end

    key = {__MODULE__, k, polys}

    {outputs, trellis} =
      case :persistent_term.get(key, nil) do
        nil ->
          tables = tables(k, polys)
          :persistent_term.put(key, tables)
          tables

        tables ->
          tables
      end

    %__MODULE__{k: k, polynomials: polys, puncture: puncture, outputs: outputs, trellis: trellis}
  end

  def states(%__MODULE__{k: k}), do: 1 <<< (k - 1)

  @doc "Code rate as `{input bits, output bits}` per puncturing period."
  def rate(%__MODULE__{puncture: p}), do: {length(hd(p)), p |> List.flatten() |> Enum.sum()}

  # outputs: tuple indexed by the K-bit register -> tuple of output bits.
  # trellis: for each next state s, its two predecessors (lsb 0, 1) with
  # the outputs on that branch.
  defp tables(k, polys) do
    outputs =
      for reg <- 0..((1 <<< k) - 1) do
        polys |> Enum.map(&parity(reg &&& &1)) |> List.to_tuple()
      end
      |> List.to_tuple()

    s_mask = (1 <<< (k - 1)) - 1

    trellis =
      for s <- 0..s_mask do
        b = s >>> (k - 2)

        for lsb <- 0..1 do
          prev = (s <<< 1 &&& s_mask) ||| lsb
          {prev, elem(outputs, b <<< (k - 1) ||| prev)}
        end
        |> List.to_tuple()
      end
      |> List.to_tuple()

    {outputs, trellis}
  end

  defp parity(v), do: v |> Integer.digits(2) |> Enum.sum() |> rem(2)

  @doc "Encodes bits from the all-zero state; punctured output bits."
  def encode(%__MODULE__{k: k} = code, bits) do
    {steps, _} =
      Enum.map_reduce(bits, 0, fn b, state ->
        reg = b <<< (k - 1) ||| state
        {Tuple.to_list(elem(code.outputs, reg)), reg >>> 1}
      end)

    puncture(code, steps)
  end

  defp puncture(code, steps) do
    period = length(hd(code.puncture))
    columns = code.puncture |> Enum.zip() |> Enum.map(&Tuple.to_list/1)

    steps
    |> Enum.chunk_every(period)
    |> Enum.flat_map(fn chunk ->
      Enum.zip(chunk, columns)
      |> Enum.flat_map(fn {outs, keep} ->
        for {o, 1} <- Enum.zip(outs, keep), do: o
      end)
    end)
  end

  # Received bits back on the mother code grid, erasures as :e: one list
  # of n bits per step.
  defp depuncture(code, bits) do
    n = length(code.polynomials)
    slots = code.puncture |> Enum.zip() |> Enum.flat_map(&Tuple.to_list/1)
    per_period = Enum.sum(slots)

    bits
    |> Enum.chunk_every(per_period)
    |> Enum.flat_map(fn chunk ->
      {filled, _} =
        Enum.map_reduce(slots, chunk, fn
          1, [b | rest] -> {b, rest}
          1, [] -> {:e, []}
          0, rest -> {:e, rest}
        end)

      Enum.chunk_every(filled, n)
    end)
  end

  @doc """
  Received code bits (0/1 bytes) on the mother code grid with erasures (2)
  inserted, as the native decoder takes them. Same rules as `decode/3`.
  """
  def depunctured_binary(code, bits) do
    n = length(code.polynomials)
    slots = code.puncture |> Enum.zip() |> Enum.flat_map(&Tuple.to_list/1)
    per_period = Enum.sum(slots)

    if per_period == length(slots) do
      # no puncturing: pad an incomplete last step with erasures
      pad = rem(n - rem(byte_size(bits), n), n)
      bits <> :binary.copy(<<2>>, pad)
    else
      whole = div(byte_size(bits), per_period) * per_period
      <<body::binary-size(whole), tail::binary>> = bits
      full = for <<chunk::binary-size(per_period) <- body>>, into: <<>>, do: fill(slots, chunk)
      if tail == <<>>, do: full, else: full <> fill(slots, tail)
    end
  end

  defp fill(slots, chunk) do
    {out, _} =
      Enum.map_reduce(slots, chunk, fn
        1, <<b, rest::binary>> -> {b, rest}
        1, <<>> -> {2, <<>>}
        0, rest -> {2, rest}
      end)

    :binary.list_to_bin(out)
  end

  @doc """
  Viterbi decoding of received (punctured) bits; one decoded bit per step.
  Options: `start: :zero | :unknown` (encoder state at the first bit; the
  default `:zero`), `native:` (default: when the NIF is loaded).
  """
  def decode(code, bits, opts \\ []) do
    if native?(code, opts) do
      rx = depunctured_binary(code, :binary.list_to_bin(bits))
      code |> run_native(rx, opts, false) |> :binary.bin_to_list()
    else
      decode_reference(code, bits, opts)
    end
  end

  @doc """
  Native decoding of received code bits given as a binary of 0/1 bytes;
  returns the decoded bits as 0/1 bytes. Option `simd:` (default true)
  selects the vectorised kernel. Same result as `decode/3`.
  """
  def decode_binary(code, bits, opts \\ []) do
    run_native(code, depunctured_binary(code, bits), opts, Keyword.get(opts, :simd, true))
  end

  @doc "Native decoding of a depunctured binary (see `depunctured_binary/2`)."
  def run_native(code, rx, opts, simd) do
    ExHdl.SIMD.NIF.viterbi(
      rx,
      code.k,
      code.polynomials,
      Keyword.get(opts, :start, :zero) == :unknown,
      simd
    )
  end

  defp native?(code, opts) do
    Keyword.get_lazy(opts, :native, &ExHdl.SIMD.available?/0) and code.k <= 9 and
      length(code.polynomials) <= 4
  end

  @doc "The Elixir reference decoder."
  def decode_reference(code, bits, opts \\ []) do
    steps = depuncture(code, bits)
    states = states(code)
    top = code.k - 2
    s_mask = states - 1
    inf = 1_000_000

    start =
      case Keyword.get(opts, :start, :zero) do
        :zero -> List.to_tuple([0 | List.duplicate(inf, states - 1)])
        :unknown -> List.to_tuple(List.duplicate(0, states))
      end

    {metrics, decisions} =
      Enum.reduce(steps, {start, []}, fn rx, {metrics, decisions} ->
        {new, mask} =
          Enum.reduce(s_mask..0//-1, {[], 0}, fn s, {acc, mask} ->
            {{p0, o0}, {p1, o1}} = elem(code.trellis, s)
            c0 = elem(metrics, p0) + dist(rx, o0)
            c1 = elem(metrics, p1) + dist(rx, o1)
            # p0 < p1 always (lsb 0 vs 1): ties go to p0
            if c1 < c0, do: {[c1 | acc], mask ||| 1 <<< s}, else: {[c0 | acc], mask}
          end)

        {List.to_tuple(new), [mask | decisions]}
      end)

    {_, final} = metrics |> Tuple.to_list() |> Enum.with_index() |> Enum.min()

    {bits, _} =
      Enum.reduce(decisions, {[], final}, fn mask, {acc, s} ->
        lsb = mask >>> s &&& 1
        {[s >>> top | acc], (s <<< 1 &&& s_mask) ||| lsb}
      end)

    bits
  end

  defp dist(rx, expected) do
    rx
    |> Enum.zip(Tuple.to_list(expected))
    |> Enum.reduce(0, fn
      {:e, _}, acc -> acc
      {a, a}, acc -> acc
      _, acc -> acc + 1
    end)
  end
end
