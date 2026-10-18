# Set-theoretic types: testing ground

ExHdl's range analysis uses `ExHdl.Types.IntSet`, a set-theoretic type
domain for integers. The same machinery is used to test Elixir's own type
system implementation (`Module.Types.Descr`).

## Pieces

| Module | Role |
|---|---|
| `ExHdl.Types.SetAlgebra` | Behaviour shaped after `Module.Types.Descr` |
| `ExHdl.Types.IntSet` | Integers as canonical unions of intervals |
| `ExHdl.Types.ElixirDescr` | Adapter over Elixir's `Module.Types.Descr` |
| `ExHdl.Types.Refined` | Prototype: Descr with `integer()` refined to an `IntSet` |
| `ExHdl.Types.Expr` | Version-independent symbolic type expressions |
| `ExHdl.Types.Laws` | Lattice, complement, membership and congruence laws as data |
| `ExHdl.Types.Rewrite` | Meaning-preserving rewrites for congruence (metamorphic) tests |
| `ExHdl.Types.Minimize` | Delta debugging of failing cases |

A law fails if it does not hold, crashes, or exceeds the time budget
(1 s per case). Failing cases are shrunk and written as standalone scripts
to `_build/<env>/test/type_findings/`. Scripts for `ElixirDescr` only use
`Module.Types.Descr`, so they run with plain `elixir file.exs` on any
release and can be attached to an upstream issue.

## Running

```sh
mix test                          # IntSet laws only (fast)
mix test --only elixir_types      # Descr and Refined laws on the current Elixir
LAW_RUNS=1000 LAW_DEPTH=6 mix test --only elixir_types   # bigger and more cases

scripts/type_laws_matrix.sh 1.18.3-otp-27:27.3.3 1.19.5-otp-27:27.3.3 1.20.3-otp-29:29.0.2

# shrink a finding further, on the Elixir version that shows it
mix ex_hdl.types.minimize _build/test/type_findings/elixir_descr_double_negation.exs
```

`LAW_DEPTH` (default 4) bounds the nesting of generated types; at 6 they
average about 70 nodes.
