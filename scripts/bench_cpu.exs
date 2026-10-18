# CPU throughput of the Q15 blocks per implementation.
#   MIX_ENV=test mix run scripts/bench_cpu.exs [block_size]
# Data is already in tensors/binaries (no per-sample Elixir data).
alias ExHdl.{CPU, DSP, Num}
alias ExHdl.DSP.Blocks
alias ExHdl.Num.Fixed

n = String.to_integer(List.first(System.argv()) || "65536")
reps = max(div(2_000_000, n), 3)
:rand.seed(:exsss, {1, 2, 3})
mk = fn -> %Fixed{t: Nx.tensor(for(_ <- 1..n, do: :rand.uniform(65536) - 32769), type: :s16), frac: 15} end
i = mk.(); q = mk.()
f = Num.q(16, 15, rounding: :nearest)
taps = [0.0, 0.0012, 0.0028, 0.0042, 0.0039, 0.0, -0.0083, -0.0186, -0.0254, -0.0212, 0.0, 0.0396, 0.0919, 0.1451, 0.1849, 0.1996, 0.1849, 0.1451, 0.0919, 0.0396, 0.0, -0.0212, -0.0254, -0.0186, -0.0083, 0.0, 0.0039, 0.0042, 0.0028, 0.0012, 0.0]

measure = fn fun ->
  fun.()
  {us, _} = :timer.tc(fn -> for _ <- 1..reps, do: fun.() end)
  n * reps / us
end

blocks = [
  {"ddc", &Blocks.ddc/5, {i, q}, Nx.u16(0), [Nx.u16(3001), Num.constant(0.8, f)], [format: f]},
  {"fir_complex (31 taps)", &Blocks.fir_complex/3, {i, q}, {Num.zeros({30}, f), Num.zeros({30}, f)}, [], [format: f, taps: taps]},
  {"one_pole", &Blocks.one_pole/4, i, Num.zeros({}, f), [Num.constant(0.01, f)], [format: f]}
]

IO.puts("block size #{n}, SIMD target #{ExHdl.SIMD.target()}, Msamples/s")
IO.puts(String.pad_trailing("block", 24) <> String.pad_leading("SIMD NIF", 10) <> String.pad_leading("Nx/EXLA", 10))

for {name, fun, samples, state, params, kopts} <- blocks do
  simd = measure.(fn -> CPU.run_block(fun, samples, state, params, kopts) end)
  exla = measure.(fn -> DSP.run_scan_stacked(fun, samples, state, params, kernel_opts: kopts) end)
  IO.puts(String.pad_trailing(name, 24) <> String.pad_leading(:erlang.float_to_binary(simd, decimals: 1), 10) <> String.pad_leading(:erlang.float_to_binary(exla, decimals: 1), 10))
end

# Kernel alone: scalar reference vs SIMD (no Nx conversions).
table = for v <- ExHdl.DSP.Primitives.sine_values(1024, 32767), into: <<>>, do: <<v::signed-native-32>>
ib = Nx.to_binary(i.t); qb = Nx.to_binary(q.t)
simd = measure.(fn -> ExHdl.SIMD.NIF.ddc_q15(ib, qb, 0, 3001, 26214, 10, true, table) end)
scalar = measure.(fn -> ExHdl.SIMD.NIF.ddc_q15_scalar(ib, qb, 0, 3001, 26214, 10, true, table) end)
IO.puts("ddc kernel only: SIMD #{Float.round(simd, 1)}, scalar #{Float.round(scalar, 1)}")
