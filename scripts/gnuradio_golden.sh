#!/usr/bin/env bash
# Runs the shared DSP cases (test/dsp_cases/*.json) through GNU Radio.
#
#   scripts/gnuradio_golden.sh            # regenerate test/fixtures/gnuradio/
#   scripts/gnuradio_golden.sh <out dir>  # write elsewhere (used by the live tests)
#
# Uses a native GNU Radio if /usr/bin/python3 can import it, otherwise the
# podman image from test/gnuradio/Containerfile (rootless, no sudo).
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-test/fixtures/gnuradio}
mkdir -p "$out"
out=$(cd "$out" && pwd)

if /usr/bin/python3 -c "import gnuradio" 2>/dev/null; then
  /usr/bin/python3 test/gnuradio/golden.py test/dsp_cases "$out"
else
  podman build -q -t exhdl-gnuradio test/gnuradio >/dev/null
  podman run --rm -v "$PWD/test:/work/test:ro,Z" -v "$out:/out:Z" -w /work exhdl-gnuradio \
    python3 test/gnuradio/golden.py test/dsp_cases /out 2>&1 | grep -v vmcircbuf_prefs
fi
