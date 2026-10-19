defmodule ExHdl.DVBT.Fast do
  @moduledoc """
  Tensor implementation of the DVB-T receiver path (2k), for speed:
  everything from FFT to the Viterbi input works on whole superframes as
  Nx tensors (on EXLA when available), the Viterbi decoder is the native
  kernel. Hard decisions and decoded bits agree with the list reference
  (`ExHdl.DVBT.OFDM.demodulate/3`, `ExHdl.DVBT.Receiver.decode/2`).
  """
  import Bitwise
  alias ExHdl.DVBT.{Inner, OFDM}

  @fft 2048
  @cp 64
  @sym @fft + @cp
  @active 1705
  @offset 172

  # -- tables (computed once) ---------------------------------------------------------

  defp tables do
    case :persistent_term.get({__MODULE__, :tables}, nil) do
      nil ->
        prbs = OFDM.prbs()

        phases =
          for p <- 0..3 do
            pilots = OFDM.pilots(p)
            values = Enum.map(pilots, &OFDM.pilot_value(prbs, &1))
            # for each carrier: index of the left pilot (into `pilots`) and weight
            {left, weight} =
              for k <- 0..(@active - 1) do
                j = Enum.count(pilots, &(&1 <= k)) - 1
                j = min(max(j, 0), length(pilots) - 2)
                {k0, k1} = {Enum.at(pilots, j), Enum.at(pilots, j + 1)}
                {j, (k - k0) / (k1 - k0)}
              end
              |> Enum.unzip()

            %{
              pilots: Nx.tensor(pilots),
              values: Nx.tensor(values, type: :f32),
              left: Nx.tensor(left),
              weight: Nx.tensor(weight, type: :f32),
              data: Nx.tensor(OFDM.data_carriers(p))
            }
          end

        bins =
          Nx.tensor(for k <- 0..(@active - 1), do: Integer.mod(k + @offset - div(@fft, 2), @fft))

        t = %{phases: List.to_tuple(phases), bins: bins}
        :persistent_term.put({__MODULE__, :tables}, t)
        t

      t ->
        t
    end
  end

  # -- front end -------------------------------------------------------------------------

  @doc """
  FFT of `n` symbols starting at a symbol boundary (cyclic prefix
  included): the 1705 active carriers, `c64[n][1705]`, carrier order.
  `freq_offset` (in subcarrier spacings) is removed first.
  """
  def carriers(samples, n, freq_offset \\ 0.0) do
    x = Nx.slice(samples, [0], [n * @sym])

    x =
      if freq_offset == 0.0,
        do: x,
        else:
          Nx.multiply(
            x,
            Nx.exp(
              Nx.multiply(
                Nx.complex(0.0, -2 * :math.pi() * freq_offset / @fft),
                Nx.iota({n * @sym}, type: :f32)
              )
            )
          )

    x
    |> Nx.reshape({n, @sym})
    |> Nx.slice_along_axis(@cp, @fft, axis: 1)
    |> Nx.fft()
    |> Nx.take(tables().bins, axis: 1)
  end

  @doc """
  Equalised data carriers `c64[n][1512]` for carriers of symbols whose
  frame index starts at `first_l`: pilot channel estimate, linear
  interpolation across frequency, division.
  """
  def equalise(carriers, first_l) do
    n = Nx.axis_size(carriers, 0)
    t = tables()

    groups =
      for p <- 0..3 do
        rows = for i <- 0..(n - 1)//1, rem(first_l + i, 4) == p, do: i
        {p, rows}
      end
      |> Enum.reject(fn {_, rows} -> rows == [] end)

    parts =
      for {p, rows} <- groups do
        ph = elem(t.phases, p)
        c = Nx.take(carriers, Nx.tensor(rows), axis: 0)
        gains = Nx.divide(Nx.take(c, ph.pilots, axis: 1), ph.values)
        left = Nx.take(gains, ph.left, axis: 1)
        right = Nx.take(gains, Nx.add(ph.left, 1), axis: 1)
        h = Nx.add(left, Nx.multiply(Nx.subtract(right, left), ph.weight))
        Nx.divide(Nx.take(c, ph.data, axis: 1), Nx.take(h, ph.data, axis: 1))
      end

    order =
      groups
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.with_index()
      |> Enum.sort()
      |> Enum.map(&elem(&1, 1))

    parts |> Nx.concatenate(axis: 0) |> Nx.take(Nx.tensor(order), axis: 0)
  end

  @doc """
  Hard decisions: words `u8[...]` from equalised points, per-axis Gray
  thresholds (the same decisions as nearest-point demapping).
  """
  def demap(points, constellation) do
    v = Inner.bits_per_symbol(constellation)
    scale = %{qpsk: :math.sqrt(2), qam16: :math.sqrt(10), qam64: :math.sqrt(42)}[constellation]
    re = Nx.multiply(Nx.real(points), scale)
    im = Nx.multiply(Nx.imag(points), scale)
    axis_bits = fn a -> axis_bits(a, div(v, 2)) end
    {ib, qb} = {axis_bits.(re), axis_bits.(im)}

    # word bits y0..y(v-1): y0 = I sign, y1 = Q sign, y2 = I bit 1, y3 = Q bit 1, ...
    Enum.zip(ib, qb)
    |> Enum.flat_map(fn {i, q} -> [i, q] end)
    |> Enum.with_index()
    |> Enum.reduce(Nx.broadcast(Nx.tensor(0, type: :u8), Nx.shape(re)), fn {bit, j}, acc ->
      Nx.bitwise_or(acc, Nx.left_shift(Nx.as_type(bit, :u8), v - 1 - j))
    end)
  end

  defp axis_bits(a, 1), do: [Nx.less(a, 0)]
  defp axis_bits(a, 2), do: [Nx.less(a, 0), Nx.less(Nx.abs(a), 2)]

  defp axis_bits(a, 3) do
    m = Nx.abs(a)
    inner = Nx.less(m, 4)
    [Nx.less(a, 0), inner, Nx.select(inner, Nx.greater_equal(m, 2), Nx.less(m, 6))]
  end

  # -- deinterleavers ---------------------------------------------------------------------

  @doc "Symbol deinterleaving of `u8[n][1512]` words, frame index of row 0 = `first_l`."
  def symbol_deinterleave(words, first_l) do
    h = Inner.symbol_permutation(:"2k") |> Tuple.to_list()
    inverse = h |> Enum.with_index() |> Enum.sort() |> Enum.map(&elem(&1, 1))
    even = Nx.take(words, Nx.tensor(h), axis: 1)
    odd = Nx.take(words, Nx.tensor(inverse), axis: 1)
    n = Nx.axis_size(words, 0)

    is_even =
      Nx.tensor(for(i <- 0..(n - 1)//1, do: if(rem(first_l + i, 2) == 0, do: 1, else: 0)),
        type: :u8
      )
      |> Nx.reshape({n, 1})

    Nx.select(Nx.broadcast(is_even, Nx.shape(even)), even, odd)
  end

  @offsets [0, 63, 105, 42, 21, 84]

  @doc "Bit deinterleaving of words (a multiple of 126), as `Inner.bit_deinterleave/2`."
  def bit_deinterleave(words, constellation) do
    v = Inner.bits_per_symbol(constellation)
    demux = %{2 => [0, 1], 4 => [0, 2, 1, 3], 6 => [0, 2, 4, 1, 3, 5]}[v]
    blocks = words |> Nx.reshape({:auto, 126})

    demux
    |> Enum.with_index()
    |> Enum.reduce(Nx.broadcast(Nx.tensor(0, type: :u8), Nx.shape(blocks)), fn {e, i}, acc ->
      src = Nx.tensor(for w <- 0..125, do: Integer.mod(w - Enum.at(@offsets, e), 126))
      bit = blocks |> Nx.take(src, axis: 1) |> Nx.right_shift(v - 1 - e) |> Nx.bitwise_and(1)
      Nx.bitwise_or(acc, Nx.left_shift(bit, v - 1 - i))
    end)
    |> Nx.flatten()
  end

  @doc "Code bits (MSB first per word) as a binary of 0/1 bytes."
  def unpack(words, constellation) do
    v = Inner.bits_per_symbol(constellation)
    shifts = Nx.tensor(Enum.to_list((v - 1)..0//-1), type: :u8)

    words
    |> Nx.reshape({:auto, 1})
    |> Nx.right_shift(shifts)
    |> Nx.bitwise_and(1)
    |> Nx.as_type(:u8)
    |> Nx.to_binary()
  end

  @doc "Packs 0/1 bytes into bytes, MSB first."
  def pack(bits) do
    for <<b0, b1, b2, b3, b4, b5, b6, b7 <- binary_part(bits, 0, div(byte_size(bits), 8) * 8)>>,
      into: <<>>,
      do:
        <<b0 <<< 7 ||| b1 <<< 6 ||| b2 <<< 5 ||| b3 <<< 4 ||| b4 <<< 3 ||| b5 <<< 2 ||| b6 <<< 1 |||
            b7>>
  end
end

defmodule ExHdl.DVBT.FastJit do
  @moduledoc """
  The 2k receiver front end as one `defn` (frequency correction, FFT,
  carrier extraction, channel estimate, equalisation, hard decisions,
  symbol and bit deinterleaving, bit unpacking), so `Nx.Defn.jit/2` with
  EXLA compiles it into a single fused computation instead of one call per
  tensor operation. Same results as the eager `ExHdl.DVBT.Fast` pipeline.

  Input: `n` whole symbols starting at a superframe boundary. Output:
  `u8[n * 1512 * v]` code bits for the Viterbi decoder.
  """
  import Nx.Defn
  alias ExHdl.DVBT.{Fast, Inner, OFDM}

  @fft 2048
  @cp 64
  @sym @fft + @cp
  @pi :math.pi()

  @doc "Compiled front end for `n` symbols (cached per `n` and constellation)."
  def compiled(n, constellation) do
    key = {__MODULE__, n, constellation}

    case :persistent_term.get(key, nil) do
      nil ->
        args = [Nx.template({n * @sym}, :c64), Nx.template({}, :f32), tables(constellation)]
        compiler = if Code.ensure_loaded?(EXLA), do: EXLA, else: Nx.Defn.Evaluator

        f =
          Nx.Defn.compile(&front_end/4, args ++ [[constellation: constellation]],
            compiler: compiler
          )

        :persistent_term.put(key, f)
        f

      f ->
        f
    end
  end

  @doc "Runs the compiled front end; returns the code bits as a binary."
  def run(samples, freq_offset, constellation) do
    n = div(Nx.size(samples), @sym)
    x = Nx.slice(samples, [0], [n * @sym])
    f = compiled(n, constellation)
    f.(x, Nx.tensor(freq_offset, type: :f32), tables(constellation)) |> Nx.to_binary()
  end

  # Index and weight tables as tensors (passed as arguments, not constants).
  defp tables(constellation) do
    key = {__MODULE__, :tables, constellation}

    case :persistent_term.get(key, nil) do
      nil ->
        prbs = OFDM.prbs()
        max_pilots = 0..3 |> Enum.map(&length(OFDM.pilots(&1))) |> Enum.max()

        per_phase =
          for p <- 0..3 do
            pilots = OFDM.pilots(p)

            {left, weight} =
              for k <- 0..1704 do
                j = (Enum.count(pilots, &(&1 <= k)) - 1) |> max(0) |> min(length(pilots) - 2)
                {k0, k1} = {Enum.at(pilots, j), Enum.at(pilots, j + 1)}
                {j, (k - k0) / (k1 - k0)}
              end
              |> Enum.unzip()

            # pilot index padded to a common length (repeat the last pilot)
            pad = max_pilots - length(pilots)

            {Nx.tensor(pilots ++ List.duplicate(List.last(pilots), pad)),
             Nx.tensor(
               Enum.map(pilots, &OFDM.pilot_value(prbs, &1)) ++
                 List.duplicate(OFDM.pilot_value(prbs, List.last(pilots)), pad),
               type: :f32
             ), Nx.tensor(left), Nx.tensor(weight, type: :f32), Nx.tensor(OFDM.data_carriers(p))}
          end

        h = Inner.symbol_permutation(:"2k") |> Tuple.to_list()
        inverse = h |> Enum.with_index() |> Enum.sort() |> Enum.map(&elem(&1, 1))
        v = Inner.bits_per_symbol(constellation)
        demux = %{2 => [0, 1], 4 => [0, 2, 1, 3], 6 => [0, 2, 4, 1, 3, 5]}[v]
        offsets = [0, 63, 105, 42, 21, 84]

        bit_src =
          for e <- demux do
            Nx.tensor(for w <- 0..125, do: Integer.mod(w - Enum.at(offsets, e), 126))
          end

        t = %{
          bins: Nx.tensor(for k <- 0..1704, do: Integer.mod(k + 172 - 1024, 2048)),
          pilots: per_phase |> Enum.map(&elem(&1, 0)) |> Nx.stack(),
          values: per_phase |> Enum.map(&elem(&1, 1)) |> Nx.stack(),
          left: per_phase |> Enum.map(&elem(&1, 2)) |> Nx.stack(),
          weight: per_phase |> Enum.map(&elem(&1, 3)) |> Nx.stack(),
          data: per_phase |> Enum.map(&elem(&1, 4)) |> Nx.stack(),
          symbol_h: Nx.tensor(h),
          symbol_inverse: Nx.tensor(inverse),
          bit_src: Nx.stack(bit_src)
        }

        :persistent_term.put(key, t)
        t

      t ->
        t
    end
  end

  defn front_end(x, freq_offset, t, opts \\ []) do
    opts = keyword!(opts, [:constellation])
    n = div(Nx.size(x), @sym)

    phase = Nx.complex(0.0, -2 * @pi / @fft) * freq_offset * Nx.iota({n * @sym}, type: :f32)

    carriers =
      (x * Nx.exp(phase))
      |> Nx.reshape({n, @sym})
      |> Nx.slice_along_axis(@cp, @fft, axis: 1)
      |> Nx.fft()
      |> Nx.take(t.bins, axis: 1)

    # all four scattered pilot phases for every symbol, selected per row
    row_phase = Nx.remainder(Nx.iota({n, 1}), 4)

    eq =
      equalise_phase(carriers, t, 0) * (row_phase == 0) +
        equalise_phase(carriers, t, 1) * (row_phase == 1) +
        equalise_phase(carriers, t, 2) * (row_phase == 2) +
        equalise_phase(carriers, t, 3) * (row_phase == 3)

    words = demap(eq, opts[:constellation])

    even = Nx.take(words, t.symbol_h, axis: 1)
    odd = Nx.take(words, t.symbol_inverse, axis: 1)
    is_even = Nx.broadcast(Nx.remainder(Nx.iota({n, 1}), 2) == 0, Nx.shape(even))
    deint = Nx.select(is_even, even, odd)

    bits_out(deint, t.bit_src, opts[:constellation])
  end

  deftransformp equalise_phase(carriers, t, p) do
    pilots = t.pilots[p]
    values = t.values[p]
    gains = Nx.divide(Nx.take(carriers, pilots, axis: 1), values)
    left = Nx.take(gains, t.left[p], axis: 1)
    right = Nx.take(gains, Nx.add(t.left[p], 1), axis: 1)
    h = Nx.add(left, Nx.multiply(Nx.subtract(right, left), t.weight[p]))
    Nx.divide(Nx.take(carriers, t.data[p], axis: 1), Nx.take(h, t.data[p], axis: 1))
  end

  deftransformp demap(points, constellation), do: Fast.demap(points, constellation)

  deftransformp bits_out(words, bit_src, constellation) do
    v = Inner.bits_per_symbol(constellation)
    demux = %{2 => [0, 1], 4 => [0, 2, 1, 3], 6 => [0, 2, 4, 1, 3, 5]}[v]
    blocks = Nx.reshape(words, {:auto, 126})

    deinterleaved =
      demux
      |> Enum.with_index()
      |> Enum.reduce(Nx.broadcast(Nx.tensor(0, type: :u8), Nx.shape(blocks)), fn {e, i}, acc ->
        bit =
          blocks |> Nx.take(bit_src[i], axis: 1) |> Nx.right_shift(v - 1 - e) |> Nx.bitwise_and(1)

        Nx.bitwise_or(acc, Nx.left_shift(bit, v - 1 - i))
      end)

    shifts = Nx.tensor(Enum.to_list((v - 1)..0//-1), type: :u8)

    deinterleaved
    |> Nx.reshape({:auto, 1})
    |> Nx.right_shift(shifts)
    |> Nx.bitwise_and(1)
    |> Nx.as_type(:u8)
    |> Nx.flatten()
  end
end
