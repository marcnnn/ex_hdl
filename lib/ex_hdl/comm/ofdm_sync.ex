defmodule ExHdl.Comm.OFDM.Sync do
  @moduledoc """
  Generic OFDM acquisition steps for an `ExHdl.Comm.OFDM` configuration.

    * `timing/3`: symbol timing and fractional frequency offset from the
      cyclic prefix correlation (van de Beek, Sandell, Boerjesson 1997),
      summed over `m` symbols.
    * `integer_offset/6`: integer frequency offset (subcarrier spacings)
      from the energy of known boosted carriers (continual pilots) over
      candidate bin shifts.
  """
  alias ExHdl.Comm.OFDM

  @doc "`{theta, frac}`: first sample of a symbol (its cyclic prefix) and the fractional offset."
  def timing(%OFDM{fft: fft, cp: cp}, x, m) do
    sym = fft + cp
    len = (m + 1) * sym
    a = Nx.slice(x, [0], [len])
    b = Nx.slice(x, [fft], [len])
    p = Nx.multiply(a, Nx.conjugate(b))
    c = Nx.cumulative_sum(Nx.concatenate([Nx.tensor([Complex.new(0.0, 0.0)], type: :c64), p]))
    window = Nx.subtract(Nx.slice(c, [cp], [len - cp + 1]), Nx.slice(c, [0], [len - cp + 1]))
    gamma = window |> Nx.slice([0], [m * sym]) |> Nx.reshape({m, sym}) |> Nx.sum(axes: [0])
    theta = gamma |> Nx.abs() |> Nx.argmax() |> Nx.to_number()
    g = gamma[theta] |> Nx.to_number()
    # r[k] r*[k + N] = |s|^2 exp(-j 2 pi eps) for an offset of eps subcarriers
    {theta, -:math.atan2(Complex.imag(g), Complex.real(g)) / (2 * :math.pi())}
  end

  @doc """
  The bin shift in `-max_shift..max_shift` that puts the most energy on
  `reference_carriers` (logical carriers), over `symbols` symbols from
  `theta` with the fractional offset `frac` removed.
  """
  def integer_offset(
        %OFDM{fft: fft, cp: cp} = o,
        x,
        theta,
        frac,
        max_shift,
        reference_carriers,
        symbols \\ 8
      ) do
    sym = fft + cp

    power =
      x
      |> Nx.slice([theta], [symbols * sym])
      |> Nx.multiply(
        Nx.exp(
          Nx.multiply(
            Nx.complex(0.0, -2 * :math.pi() * frac / fft),
            Nx.iota({symbols * sym}, type: :f32)
          )
        )
      )
      |> Nx.reshape({symbols, sym})
      |> Nx.slice_along_axis(cp, fft, axis: 1)
      |> Nx.fft()
      |> Nx.abs()
      |> Nx.pow(2)
      |> Nx.sum(axes: [0])
      |> Nx.to_flat_list()
      |> List.to_tuple()

    bins = List.to_tuple(o.bins)

    Enum.max_by(-max_shift..max_shift, fn d ->
      Enum.reduce(reference_carriers, 0.0, fn k, acc ->
        acc + elem(power, Integer.mod(elem(bins, k) + d, fft))
      end)
    end)
  end
end
