defmodule ExHdl.DVBT.Sync do
  @moduledoc """
  DVB-T acquisition (2k): finds symbol timing, carrier frequency offset and
  the first superframe start in a stream of baseband samples.

    1. Symbol timing and fractional frequency offset from the cyclic
       prefix correlation (`ExHdl.Comm.OFDM.Sync.timing/3`).
    2. Integer frequency offset from the energy of the continual pilots
       (boosted to 4/3, `ExHdl.Comm.OFDM.Sync.integer_offset/7`).
    3. Frame position from TPS: DBPSK bits from consecutive symbols, the
       16-bit synchronisation word (inverted in frames 2 and 4), and the
       frame number (TPS bits 23-24).

  The scattered pilot pattern (symbol index mod 4) is reported as a cross
  check.
  """
  import Bitwise
  alias ExHdl.DVBT.OFDM

  @fft 2048
  @cp 64
  @sym @fft + @cp
  @sync [0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 0]

  @doc """
  Returns `{:ok, %{start: sample, freq_offset: subcarriers, timing: theta,
  frame: f, scattered_phase_ok: bool}}` with `start` the first sample
  (cyclic prefix) of the first complete superframe, or `{:error, reason}`.

  Options: `:max_integer_offset` (bins, default 16), `:timing_symbols`
  (symbols averaged for timing, default 32).
  """
  def acquire(samples, opts \\ []) do
    backend = if Code.ensure_loaded?(EXLA.Backend), do: EXLA.Backend, else: Nx.BinaryBackend

    Nx.with_default_backend(backend, fn ->
      do_acquire(Nx.backend_transfer(samples, backend), opts)
    end)
  end

  defp do_acquire(x, opts) do
    total = Nx.size(x)
    m = Keyword.get(opts, :timing_symbols, 32)

    if total < (m + 1) * @sym + 2 * 272 * @sym do
      {:error, :too_short}
    else
      o = OFDM.ofdm()
      {theta, frac} = ExHdl.Comm.OFDM.Sync.timing(o, x, m)

      int =
        ExHdl.Comm.OFDM.Sync.integer_offset(
          o,
          x,
          theta,
          frac,
          Keyword.get(opts, :max_integer_offset, 16),
          OFDM.continual_pilots()
        )

      offset = frac + int

      # enough symbols to see a frame start and the frame number
      n = min(div(total - theta, @sym), 272 + 2 * 68)

      carriers =
        ExHdl.Comm.OFDM.carriers(OFDM.ofdm(), Nx.slice(x, [theta], [n * @sym]), n, offset)

      with {:ok, frame_start, frame} <- frame_position(carriers) do
        # first superframe start at or after frame_start
        superframe = frame_start + rem(4 - frame, 4) * 68

        {:ok,
         %{
           start: theta + superframe * @sym,
           freq_offset: offset,
           timing: theta,
           frame: frame,
           scattered_phase_ok: scattered_phase_ok?(carriers, frame_start)
         }}
      end
    end
  end

  # TPS bit l of a frame = phase flip on the TPS carriers between symbols
  # l - 1 and l (majority over the 17 carriers via the summed products).
  defp frame_position(carriers) do
    tps = carriers |> Nx.take(Nx.tensor(OFDM.tps_carriers()), axis: 1)
    n = Nx.axis_size(tps, 0)
    prev = Nx.slice_along_axis(tps, 0, n - 1, axis: 0)
    cur = Nx.slice_along_axis(tps, 1, n - 1, axis: 0)

    # bits index i is the TPS bit of symbol i + 1
    bits =
      Nx.multiply(cur, Nx.conjugate(prev))
      |> Nx.real()
      |> Nx.sum(axes: [1])
      |> Nx.less(0)
      |> Nx.to_flat_list()
      |> List.to_tuple()

    inverted = Enum.map(@sync, &(1 - &1))
    max_start = tuple_size(bits) - 25

    found =
      Enum.find_value(0..max_start//1, fn s0 ->
        # symbol s0 is l = 0, so bit l sits at index s0 + l - 1
        word = for l <- 1..16, do: elem(bits, s0 + l - 1)
        if word == @sync or word == inverted, do: s0
      end)

    case found do
      nil ->
        {:error, :no_tps_sync}

      s0 ->
        frame = elem(bits, s0 + 22) <<< 1 ||| elem(bits, s0 + 23)
        {:ok, s0, frame}
    end
  end

  # The scattered pilot pattern must agree with the frame position found
  # (symbols before frame_start may still be noise).
  defp scattered_phase_ok?(carriers, frame_start) do
    count = min(16, Nx.axis_size(carriers, 0) - frame_start)
    power = carriers |> Nx.slice_along_axis(frame_start, count, axis: 0) |> Nx.abs() |> Nx.pow(2)

    energies =
      for p <- 0..3 do
        power |> Nx.take(Nx.tensor(OFDM.scattered_pilots(p)), axis: 1) |> Nx.sum(axes: [1])
      end

    found = energies |> Nx.stack(axis: 1) |> Nx.argmax(axis: 1) |> Nx.to_flat_list()
    found == Enum.map(0..(count - 1), &rem(&1, 4))
  end
end
