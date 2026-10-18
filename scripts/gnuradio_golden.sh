#!/usr/bin/env bash
# Regenerates the GNU Radio reference data in test/fixtures/gnuradio/.
# Uses a native GNU Radio if /usr/bin/python3 can import it, otherwise the
# podman image from test/gnuradio/Containerfile (rootless, no sudo).
set -euo pipefail
cd "$(dirname "$0")/.."
out=test/fixtures/gnuradio

if /usr/bin/python3 -c "import gnuradio" 2>/dev/null; then
  /usr/bin/python3 test/gnuradio/golden.py "$out"
else
  podman build -q -t exhdl-gnuradio test/gnuradio >/dev/null
  podman run --rm -v "$PWD/test:/work/test:Z" -w /work exhdl-gnuradio \
    python3 test/gnuradio/golden.py "$out"
fi
