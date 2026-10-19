defmodule ExHdl.Comm.OFDM.FrontEnd do
  @moduledoc """
  OFDM receiver front end compiled into one computation (`Nx.Defn`, EXLA
  when available): frequency correction, FFT, carrier extraction, pilot
  channel estimate and equalisation, hard decisions, cell and bit
  deinterleaving, bit unpacking. Output: one `u8` (0/1) per code bit, the
  input of a Viterbi decoder.

  A spec is a map:

    * `:ofdm` - `ExHdl.Comm.OFDM` configuration
    * `:constellation` - `ExHdl.Comm.Constellation`
    * `:cells` - `ExHdl.Comm.Permutation` applied to the words of each
      symbol (the deinterleaver; block index = symbol index), or `nil`
    * `:bits` - `ExHdl.Comm.Permutation` over the code bits (the
      deinterleaver), or `nil`

  The samples start at a symbol of class 0; whole multiples of the class
  period (and of the cell permutation's table count) are used.
  """
  import Nx.Defn
  alias ExHdl.Comm.{Constellation, OFDM, Permutation}

  @pi :math.pi()

  @doc "Runs the front end; returns the code bits as a binary of 0/1 bytes."
  def run(samples, freq_offset, spec) do
    o = spec.ofdm
    group = lcm(OFDM.period(o), cell_tables(spec))
    n = div(div(Nx.size(samples), OFDM.symbol_length(o)), group) * group
    x = Nx.slice(samples, [0], [n * OFDM.symbol_length(o)])
    t = tables(spec)
    compiled(n, spec, t).(x, Nx.tensor(freq_offset, type: :f32), t) |> Nx.to_binary()
  end

  defp cell_tables(%{cells: nil}), do: 1
  defp cell_tables(%{cells: p}), do: length(p.tables)

  defp lcm(a, b), do: div(a * b, Integer.gcd(a, b))

  defp compiled(n, spec, t) do
    key = {__MODULE__, n, :erlang.phash2(spec)}

    case :persistent_term.get(key, nil) do
      nil ->
        o = spec.ofdm

        static = [
          fft: o.fft,
          cp: o.cp,
          period: OFDM.period(o),
          constellation: spec.constellation,
          cells?: spec.cells != nil,
          bits?: spec.bits != nil
        ]

        templates = [Nx.template({n * OFDM.symbol_length(o)}, :c64), Nx.template({}, :f32), t]
        compiler = if Code.ensure_loaded?(EXLA), do: EXLA, else: Nx.Defn.Evaluator
        f = Nx.Defn.compile(&front_end/4, templates ++ [static], compiler: compiler)
        :persistent_term.put(key, f)
        f

      f ->
        f
    end
  end

  # all tables as tensor arguments (not constants folded into the graph)
  defp tables(spec) do
    key = {__MODULE__, :tables, :erlang.phash2(spec)}

    case :persistent_term.get(key, nil) do
      nil ->
        t = %{
          bins: Nx.tensor(spec.ofdm.bins),
          ofdm: OFDM.tables(spec.ofdm),
          demap: Constellation.tensor_tables(spec.constellation),
          cells: if(spec.cells, do: Permutation.tensor(spec.cells), else: Nx.tensor(0)),
          bits: if(spec.bits, do: Permutation.tensor(spec.bits), else: Nx.tensor(0))
        }

        :persistent_term.put(key, t)
        t

      t ->
        t
    end
  end

  defn front_end(x, freq_offset, t, opts \\ []) do
    opts = keyword!(opts, [:fft, :cp, :period, :constellation, :cells?, :bits?])
    fft = opts[:fft]
    cp = opts[:cp]
    period = opts[:period]
    sym = fft + cp
    n = div(Nx.size(x), sym)

    phase = Nx.complex(0.0, -2 * @pi / fft) * freq_offset * Nx.iota({n * sym}, type: :f32)

    carriers =
      (x * Nx.exp(phase))
      |> Nx.reshape({n, sym})
      |> Nx.slice_along_axis(cp, fft, axis: 1)
      |> Nx.fft()
      |> Nx.take(t.bins, axis: 1)

    # symbol i has class i mod period: group the classes with a reshape
    eq = equalise(carriers, t.ofdm, period)
    words = demap(eq, t.demap, opts[:constellation])
    words = cells(words, t.cells, opts[:cells?])
    code_bits(words, t.bits, opts[:constellation], opts[:bits?])
  end

  deftransformp equalise(carriers, t, period) do
    {n, k} = Nx.shape(carriers)
    carriers |> Nx.reshape({div(n, period), period, k}) |> OFDM.equalise_grouped(t, period)
  end

  deftransformp demap(points, t, constellation),
    do: Constellation.demap_tensor(constellation, points, t)

  deftransformp cells(words, t, apply?) do
    if apply?, do: Permutation.apply_tensor(words, t), else: words
  end

  deftransformp code_bits(words, t, constellation, apply?) do
    v = constellation.bits
    shifts = Nx.tensor(Enum.to_list((v - 1)..0//-1), type: :u8)

    bits =
      words
      |> Nx.reshape({:auto, 1})
      |> Nx.right_shift(shifts)
      |> Nx.bitwise_and(1)
      |> Nx.as_type(:u8)

    if apply? do
      {_, size} = Nx.shape(t)
      bits |> Nx.reshape({:auto, size}) |> Permutation.apply_tensor(t) |> Nx.flatten()
    else
      Nx.flatten(bits)
    end
  end
end
