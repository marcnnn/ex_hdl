defmodule ExHdl.Comm.OFDMTest do
  @moduledoc """
  The generic mapping, permutation and OFDM blocks with a configuration
  other than DVB-T: an IEEE 802.11a-style symbol (64-point FFT, carriers
  -26..26 without DC, pilots at -21, -7, 7, 21, 48 data carriers, 802.11
  Gray mapping and bit interleaver).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExHdl.Comm.{Constellation, OFDM, Permutation}
  alias ExHdl.Comm.OFDM.FrontEnd

  defp wifi_ofdm do
    # logical carrier k = frequency index k - 26
    pilots =
      [{-21, 1.0}, {-7, 1.0}, {7, 1.0}, {21, -1.0}]
      |> Enum.map(fn {f, v} -> {f + 26, {v, 0.0}} end)

    pilot_k = Enum.map(pilots, &elem(&1, 0))
    data = for k <- 0..52, k != 26, k not in pilot_k, do: k

    OFDM.new(
      fft: 64,
      cp: 16,
      bins: OFDM.centered_bins(64, -26, 53),
      classes: [%{pilots: pilots, data: data}],
      scale: 64 / :math.sqrt(52)
    )
  end

  # 802.11a 17.3.5.7: bit k goes to j(i(k))
  defp wifi_interleaver(n_cbps, n_bpsc) do
    s = max(div(n_bpsc, 2), 1)

    scatter =
      for k <- 0..(n_cbps - 1) do
        i = div(n_cbps, 16) * rem(k, 16) + div(k, 16)
        s * div(i, s) + rem(i + n_cbps - div(16 * i, n_cbps), s)
      end

    Permutation.scatter(scatter)
  end

  defp qam16, do: Constellation.square(Constellation.reflected_gray_axis(2), :split)

  test "802.11 16-QAM mapping (17.3.5.8): b0b1 -> I, b2b3 -> Q, 00 -3, 01 -1, 11 1, 10 3" do
    c = qam16()
    s = :math.sqrt(10)
    level = %{0b00 => -3, 0b01 => -1, 0b11 => 1, 0b10 => 3}

    for w <- 0..15 do
      {re, im} = Constellation.map(c, w)
      assert_in_delta re * s, level[Bitwise.bsr(w, 2)], 1.0e-12
      assert_in_delta im * s, level[Bitwise.band(w, 3)], 1.0e-12
    end
  end

  property "tensor hard decisions equal nearest-point decisions" do
    constellations = [
      qam16(),
      Constellation.square(Constellation.reflected_gray_axis(3), :split),
      ExHdl.DVBT.Inner.constellation(:qam64),
      # 8-PSK: generic point table, nearest point
      Constellation.new(
        for(w <- 0..7, do: {:math.cos(w * :math.pi() / 4), :math.sin(w * :math.pi() / 4)})
      )
    ]

    check all idx <- integer(0..3),
              pts <-
                list_of(tuple({float(min: -1.5, max: 1.5), float(min: -1.5, max: 1.5)}),
                  length: 64
                ),
              max_runs: 40 do
      c = Enum.at(constellations, idx)
      # off exact decision boundaries (grid values like 0.0) where the tie
      # rules differ, and off the PSK centre where f32 rounding decides
      pts = Enum.map(pts, fn {a, b} -> {a + 0.0123, b + 0.0177} end)
      ref = Enum.map(pts, &Constellation.demap(c, &1))
      t = Nx.tensor(Enum.map(pts, fn {a, b} -> Complex.new(a, b) end), type: :c64)

      assert c
             |> Constellation.demap_tensor(t, Constellation.tensor_tables(c))
             |> Nx.to_flat_list() == ref
    end
  end

  property "permutations: inverse undoes, tensor form equals list form" do
    check all size <- integer(1..40),
              count <- integer(1..3),
              tables <-
                list_of(constant(:ok), length: count)
                |> map(fn l -> Enum.map(l, fn _ -> Enum.shuffle(0..(size - 1)) end) end),
              blocks <- integer(1..6) do
      p = Permutation.new(tables)
      x = Enum.to_list(1..(size * blocks))
      y = Permutation.apply(p, x)
      assert Permutation.apply(Permutation.inverse(p), y) == x

      tensor =
        x
        |> Nx.tensor()
        |> Nx.reshape({blocks, size})
        |> Permutation.apply_tensor(Permutation.tensor(p))

      assert Nx.to_flat_list(tensor) == y
    end
  end

  test "802.11 interleaver: first bits of a 16-QAM symbol land where the standard says" do
    # N_CBPS 192: k = 0 -> 0, k = 1 -> 13, k = 2 -> 24, k = 16 -> 1 (17.3.5.6 formulas)
    p = wifi_interleaver(192, 4)
    out = Permutation.apply(p, Enum.to_list(0..191))

    assert Enum.at(out, 0) == 0 and Enum.at(out, 13) == 1 and Enum.at(out, 24) == 2 and
             Enum.at(out, 1) == 16
  end

  test "802.11a-style symbols: modulate, flat channel and frequency offset, compiled front end recovers the bits" do
    o = wifi_ofdm()
    c = qam16()
    il = wifi_interleaver(192, 4)
    n = 40
    :rand.seed(:exsss, {1, 2, 3})
    bits = for _ <- 1..(n * 192), do: :rand.uniform(2) - 1

    symbols =
      bits
      |> then(&Permutation.apply(il, &1))
      |> Enum.chunk_every(4)
      |> Enum.map(fn b -> Enum.reduce(b, 0, &(&2 * 2 + &1)) end)
      |> Enum.chunk_every(48)
      |> Enum.map(fn words -> {0, Enum.map(words, &Constellation.map(c, &1)), []} end)

    x = OFDM.modulate(o, symbols)
    # flat channel: gain and phase; carrier offset of 0.2 subcarriers
    gain = Complex.new(0.7, -0.4)
    sym = Nx.size(x)

    rot =
      Nx.exp(Nx.multiply(Nx.complex(0.0, 2 * :math.pi() * 0.2 / 64), Nx.iota({sym}, type: :f32)))

    y = x |> Nx.multiply(gain) |> Nx.multiply(rot)

    # reference demodulation of the clean signal returns the points
    [{data, _} | _] = OFDM.demodulate(o, Nx.multiply(x, gain), 0)
    {_, first, _} = hd(symbols)

    for {{a, b}, {c0, d0}} <- Enum.zip(data, first),
        do: assert_in_delta(a, c0, 1.0e-4) && assert_in_delta(b, d0, 1.0e-4)

    out =
      FrontEnd.run(y, 0.2, %{ofdm: o, constellation: c, cells: nil, bits: Permutation.inverse(il)})

    assert :binary.bin_to_list(out) == bits
  end

  test "sync: timing and frequency offset of an 802.11a-style stream" do
    o = wifi_ofdm()
    c = qam16()
    :rand.seed(:exsss, {4, 5, 6})

    symbols =
      for _ <- 1..60,
          do: {0, for(_ <- 1..48, do: Constellation.map(c, :rand.uniform(16) - 1)), []}

    x = OFDM.modulate(o, symbols)
    {noise, _} = Nx.Random.normal(Nx.Random.key(1), 0.0, 0.01, shape: {37, 2}, type: :f32)
    lead = Nx.complex(noise[[.., 0]], noise[[.., 1]])
    # 37 samples of noise first, offset 3.3 subcarriers
    n = Nx.size(x) + 37

    rot =
      Nx.exp(Nx.multiply(Nx.complex(0.0, 2 * :math.pi() * 3.3 / 64), Nx.iota({n}, type: :f32)))

    y = Nx.concatenate([lead, x]) |> Nx.multiply(rot)

    {theta, frac} = ExHdl.Comm.OFDM.Sync.timing(o, y, 40)
    assert rem(theta, 80) == 37
    assert_in_delta frac, 0.3, 0.02

    # 802.11 pilots are not boosted: use the occupied band (energy moves
    # into the guard carriers when the shift is wrong)
    class = hd(o.classes)
    used = Enum.map(class.pilots, &elem(&1, 0)) ++ class.data
    assert ExHdl.Comm.OFDM.Sync.integer_offset(o, y, theta, frac, 8, used) == 3
  end
end
