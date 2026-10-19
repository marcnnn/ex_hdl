#!/usr/bin/env bash
# Regenerates the DVB-T reference data (test/fixtures/dvbt/) with gr-dtv,
# which needs the Debian GNU Radio image (Fedora's package lacks gr-dtv).
set -euo pipefail
cd "$(dirname "$0")/.."
podman build -q -t exhdl-gnuradio-dtv test/gnuradio/debian >/dev/null
mkdir -p test/fixtures/dvbt/2k_qpsk_1_2
podman run --rm -v "$PWD/test:/work/test:Z" -w /work exhdl-gnuradio-dtv \
  python3 test/gnuradio/dvbt_golden.py test/fixtures/dvbt/2k_qpsk_1_2 2>&1 | grep -v -e vmcircbuf -e buffer_double_mapped
