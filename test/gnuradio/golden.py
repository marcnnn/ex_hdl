#!/usr/bin/env python3
"""Generates GNU Radio reference data for ExHdl's fixed-point kernels.

Usage: golden.py <output dir>   (normally via scripts/gnuradio_golden.sh)

Every case writes into <output dir>/<case>/:
  case.json     parameters, GNU Radio/numpy versions, file formats
  input.s16le   the Q15 input exactly as ExHdl sees it (interleaved I/Q for complex)
  gnuradio.f32le  GNU Radio's float output for that input, scaled so 1.0 = full scale

GNU Radio computes in float. ExHdl's Q15 results are compared against this
with a quality metric (SNR), not bit for bit.
"""
import json
import os
import sys

import numpy as np
from gnuradio import analog, blocks, filter, gr  # noqa: F401  (analog kept for future cases)

N = 4096
FULL_SCALE = 32768.0


def q15(x):
    """Rounds floats in [-1, 1) to int16, saturating."""
    return np.clip(np.round(np.asarray(x) * FULL_SCALE), -32768, 32767).astype(np.int16)


def run(source, blocks_chain, sink):
    tb = gr.top_block()
    tb.connect(source, *blocks_chain, sink)
    tb.run()
    return np.asarray(sink.data())


def ddc_rotator(rng):
    """NCO mixing plus gain: rotator_cc followed by multiply_const_cc."""
    n = np.arange(N)
    x = (
        0.45 * np.exp(2j * np.pi * 0.05 * n)
        + 0.2 * np.exp(-2j * np.pi * 0.17 * n + 0.3j)
        + 1e-3 * (rng.standard_normal(N) + 1j * rng.standard_normal(N))
    )
    i16, q16 = q15(x.real), q15(x.imag)
    phase_inc, gain_q15 = 3001, 26214

    src = blocks.vector_source_c((i16 + 1j * q16).astype(np.complex64) / FULL_SCALE)
    out = run(
        src,
        [blocks.rotator_cc(2 * np.pi * phase_inc / 65536), blocks.multiply_const_cc(gain_q15 / FULL_SCALE)],
        blocks.vector_sink_c(),
    )

    params = {
        "phase_inc": phase_inc,
        "gain_q15": gain_q15,
        # ExHdl adds phase_inc before the lookup; starting one step back makes
        # the first sample use phase 0, like rotator_cc.
        "initial_phase": (-phase_inc) % 65536,
    }
    interleaved_in = np.stack([i16, q16], axis=1).reshape(-1)
    interleaved_out = np.stack([out.real, out.imag], axis=1).reshape(-1).astype(np.float32)
    return "complex", params, interleaved_in, interleaved_out


def single_pole_iir(alpha_q15):
    def case(rng):
        n = np.arange(N)
        x = 0.4 * np.sin(2 * np.pi * 0.003 * n) + 0.3 * (n >= N // 2) + 1e-3 * rng.standard_normal(N)
        x16 = q15(x)
        src = blocks.vector_source_f(x16.astype(np.float32) / FULL_SCALE)
        out = run(src, [filter.single_pole_iir_filter_ff(alpha_q15 / FULL_SCALE)], blocks.vector_sink_f())
        return "real", {"alpha_q15": alpha_q15}, x16, out.astype(np.float32)

    return case


CASES = {
    "ddc_rotator": ddc_rotator,
    "single_pole_iir_a8192": single_pole_iir(8192),
    "single_pole_iir_a328": single_pole_iir(328),
}


def main(out_dir):
    for seed, (name, make) in enumerate(sorted(CASES.items())):
        rng = np.random.default_rng(1000 + seed)
        kind, params, x16, ref = make(rng)
        case_dir = os.path.join(out_dir, name)
        os.makedirs(case_dir, exist_ok=True)
        x16.astype("<i2").tofile(os.path.join(case_dir, "input.s16le"))
        ref.astype("<f4").tofile(os.path.join(case_dir, "gnuradio.f32le"))
        manifest = {
            "case": name,
            "samples": N,
            "kind": kind,
            "params": params,
            "input": "input.s16le: little-endian int16" + (", interleaved I/Q" if kind == "complex" else ""),
            "reference": "gnuradio.f32le: little-endian float32, 1.0 = 32768" + (", interleaved I/Q" if kind == "complex" else ""),
            "gnuradio": gr.version(),
            "numpy": np.__version__,
            "generator": "test/gnuradio/golden.py",
        }
        with open(os.path.join(case_dir, "case.json"), "w") as f:
            json.dump(manifest, f, indent=2, sort_keys=True)
            f.write("\n")
        print(f"{name}: {N} samples")


if __name__ == "__main__":
    main(sys.argv[1])
