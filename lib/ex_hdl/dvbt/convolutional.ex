defmodule ExHdl.DVBT.Convolutional do
  @moduledoc """
  Inner code (ETSI EN 300 744, 4.3.4): rate 1/2 mother code, 64 states,
  generators G1 = 171 (octal, output X) and G2 = 133 (output Y), punctured
  to 2/3, 3/4, 5/6 or 7/8. Bits are lists of 0/1, MSB-first per byte.

  `decode/2` is a hard-decision Viterbi decoder over a whole block
  (punctured positions count as erasures) with a final traceback from the
  best state.
  """
  import Bitwise

  # {X pattern, Y pattern} per code rate (EN 300 744, table 2)
  @puncture %{
    {1, 2} => {[1], [1]},
    {2, 3} => {[1, 0], [1, 1]},
    {3, 4} => {[1, 0, 1], [1, 1, 0]},
    {5, 6} => {[1, 0, 1, 0, 1], [1, 1, 0, 1, 0]},
    {7, 8} => {[1, 0, 0, 0, 1, 0, 1], [1, 1, 1, 1, 0, 1, 0]}
  }

  def rates, do: Map.keys(@puncture)

  # Register: bit 6 = current input, bits 5..0 = previous inputs (newest first).
  # Output pair per register value, as a tuple indexed by the 7-bit register.
  @outputs (for reg <- 0..127 do
              x = (reg &&& 0o171) |> Integer.digits(2) |> Enum.sum() |> rem(2)
              y = (reg &&& 0o133) |> Integer.digits(2) |> Enum.sum() |> rem(2)
              {x, y}
            end)
           |> List.to_tuple()

  @doc "Encodes bits; the transmitted order per period is X1 Y1 Y2 X3 ... (table 2)."
  def encode(bits, rate \\ {1, 2}) do
    {mother, _} =
      Enum.map_reduce(bits, 0, fn b, state ->
        reg = b <<< 6 ||| state
        {elem(@outputs, reg), reg >>> 1}
      end)

    puncture(mother, rate)
  end

  defp puncture(pairs, rate) do
    {xp, yp} = @puncture[rate]
    period = length(xp)

    pairs
    |> Enum.chunk_every(period)
    |> Enum.flat_map(fn chunk ->
      chunk
      |> Enum.with_index()
      |> Enum.flat_map(fn {{x, y}, i} ->
        if(Enum.at(xp, i) == 1, do: [x], else: []) ++ if Enum.at(yp, i) == 1, do: [y], else: []
      end)
    end)
  end

  # Inserts erasures (:e) where bits were punctured: a list of {x, y}.
  defp depuncture(bits, rate) do
    {xp, yp} = @puncture[rate]
    slots = Enum.zip(xp, yp) |> Enum.flat_map(fn {x, y} -> [{:x, x}, {:y, y}] end)
    per_period = Enum.sum(xp) + Enum.sum(yp)

    bits
    |> Enum.chunk_every(per_period)
    |> Enum.flat_map(fn chunk ->
      {filled, _} =
        Enum.map_reduce(slots, chunk, fn
          {_, 1}, [b | rest] -> {b, rest}
          {_, 1}, [] -> {:e, []}
          {_, 0}, rest -> {:e, rest}
        end)

      filled |> Enum.chunk_every(2) |> Enum.map(&List.to_tuple/1)
    end)
  end

  # For each next state s (= reg >>> 1): its two predecessors p = (s <<< 1 &&& 63) ||| lsb,
  # the input bit b = s >>> 5 that leads there, and the expected outputs.
  @trellis (for s <- 0..63 do
              b = s >>> 5

              for lsb <- 0..1 do
                prev = (s <<< 1 &&& 63) ||| lsb
                {x, y} = elem(@outputs, b <<< 6 ||| prev)
                {prev, x, y}
              end
              |> List.to_tuple()
            end)
           |> List.to_tuple()

  @doc """
  Hard-decision Viterbi decoding of a received (punctured) bit list.
  Returns the decoded bits (one per mother-code pair). Ties prefer the
  predecessor with the smaller state number; the final traceback starts at
  the best end state (smallest number on ties).
  """
  def decode(bits, rate \\ {1, 2}, opts \\ []) do
    if ExHdl.SIMD.available?() and Keyword.get(opts, :native, true) do
      # native kernel, bit-identical to decode_reference/3
      rx =
        for {x, y} <- depuncture(bits, rate), into: <<>>, do: <<code(x), code(y)>>

      rx
      |> ExHdl.SIMD.NIF.viterbi_dvbt(Keyword.get(opts, :start, :zero) == :unknown)
      |> :binary.bin_to_list()
    else
      decode_reference(bits, rate, opts)
    end
  end

  @doc """
  Native decoding of received code bits given as a binary of 0/1 bytes
  (punctured stream); returns the decoded bits as 0/1 bytes. Same result
  as `decode/3`.
  """
  def decode_binary(bits, rate \\ {1, 2}, opts \\ []) do
    rx = depunctured_binary(bits, rate)
    unknown = Keyword.get(opts, :start, :zero) == :unknown

    if Keyword.get(opts, :simd, true),
      do: ExHdl.SIMD.NIF.viterbi_dvbt_simd(rx, unknown),
      else: ExHdl.SIMD.NIF.viterbi_dvbt(rx, unknown)
  end

  @doc "Received code bits (0/1 bytes) as mother-code pairs with erasures (2) inserted."
  def depunctured_binary(bits, rate) do
    {xp, yp} = @puncture[rate]
    per_period = Enum.sum(xp) + Enum.sum(yp)
    slots = Enum.zip(xp, yp) |> Enum.flat_map(fn {x, y} -> [x, y] end)

    if rate == {1, 2} do
      # as depuncture/2: a trailing single bit gets an erased partner
      if rem(byte_size(bits), 2) == 1, do: bits <> <<2>>, else: bits
    else
      whole = div(byte_size(bits), per_period) * per_period
      <<body::binary-size(whole), tail::binary>> = bits

      full =
        for <<chunk::binary-size(per_period) <- body>>, into: <<>> do
          fill(slots, chunk)
        end

      # an incomplete last period: received bits in order, erasures after
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

  defp code(:e), do: 2
  defp code(b), do: b

  @doc "The Elixir reference Viterbi decoder (same results as the native one)."
  def decode_reference(bits, rate \\ {1, 2}, opts \\ []) do
    pairs = depuncture(bits, rate)
    inf = 1_000_000

    # `start: :zero` when the encoder starts from the all-zero state;
    # `start: :unknown` (e.g. mid-stream at a superframe boundary) gives all
    # states the same metric.
    start =
      case Keyword.get(opts, :start, :zero) do
        :zero -> List.to_tuple([0 | List.duplicate(inf, 63)])
        :unknown -> List.to_tuple(List.duplicate(0, 64))
      end

    {metrics, decisions} =
      Enum.reduce(pairs, {start, []}, fn {rx, ry}, {metrics, decisions} ->
        {new, mask} =
          Enum.reduce(63..0//-1, {[], 0}, fn s, {acc, mask} ->
            {{p0, x0, y0}, {p1, x1, y1}} = elem(@trellis, s)
            c0 = elem(metrics, p0) + dist(rx, x0) + dist(ry, y0)
            c1 = elem(metrics, p1) + dist(rx, x1) + dist(ry, y1)
            # p0 < p1 always (lsb 0 vs 1): ties go to p0
            if c1 < c0, do: {[c1 | acc], mask ||| 1 <<< s}, else: {[c0 | acc], mask}
          end)

        {List.to_tuple(new), [mask | decisions]}
      end)

    {_, final} = metrics |> Tuple.to_list() |> Enum.with_index() |> Enum.min()

    {bits, _} =
      Enum.reduce(decisions, {[], final}, fn mask, {acc, s} ->
        lsb = mask >>> s &&& 1
        {[s >>> 5 | acc], (s <<< 1 &&& 63) ||| lsb}
      end)

    bits
  end

  defp dist(:e, _), do: 0
  defp dist(a, a), do: 0
  defp dist(_, _), do: 1
end
