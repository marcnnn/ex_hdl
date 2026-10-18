#!/usr/bin/env bash
# Runs the set-theoretic law suites against several Elixir releases.
#
#   scripts/type_laws_matrix.sh "1.18.3-otp-27:27.3.3" "1.20.3-otp-29:29.0.2"
#
# Each argument is <asdf elixir version>:<asdf erlang version>. Every version
# gets its own build root, so findings end up in
# _build/elixir-<version>/test/type_findings/. Tune with LAW_RUNS, LAW_DEPTH
# and SEED.
set -u
cd "$(dirname "$0")/.."

for pair in "$@"; do
  ev=${pair%%:*}
  ov=${pair##*:}
  root="_build/elixir-$ev"
  rm -rf "$root/test/type_findings"
  echo "== Elixir $ev (OTP $ov)"
  ASDF_ELIXIR_VERSION=$ev ASDF_ERLANG_VERSION=$ov MIX_BUILD_ROOT=$root \
    mix test --only elixir_types --seed "${SEED:-0}" 2>&1 |
    grep -E "law .* (does not hold|exceeded|crashed)|Finished|properties" | sed 's/^ *//'
  ls "$root/test/type_findings" 2>/dev/null | sed 's/^/  finding: /'
done
