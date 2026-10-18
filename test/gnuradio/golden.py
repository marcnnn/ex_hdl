#!/usr/bin/env python3
"""GNU Radio runner for the shared DSP cases in test/dsp_cases/*.json.

Usage: golden.py <cases dir> <output dir>   (normally via scripts/gnuradio_golden.sh)

For every case it generates the input signal (seeded numpy), quantises it to
Q15 exactly as ExHdl sees it, runs the case's GNU Radio block chain and
writes <output dir>/<case>/:

  input.s16le     little-endian int16 (interleaved I/Q for complex input)
  gnuradio.f32le  little-endian float32, 1.0 = 32768 (interleaved I/Q for complex)
  manifest.json   versions and the SHA-256 of the case file it was made from

GNU Radio computes in float; the ExHdl runner (test/gnuradio_reference_test.exs)
compares its Q15 results against this per sample and by SNR.
"""
import glob
import hashlib
import importlib
import json
import math
import os
import sys

import numpy as np
from gnuradio import blocks, gr

FULL_SCALE = 32768.0


def q15(x):
    """Rounds floats in [-1, 1) to int16, saturating."""
    return np.clip(np.round(np.asarray(x) * FULL_SCALE), -32768, 32767).astype(np.int16)


def make_input(spec, samples, rng):
    """The input signal described by a case's "input" section, as Q15 ints."""
    n = np.arange(samples)
    complex_input = spec["type"] == "complex"
    x = np.zeros(samples, dtype=np.complex128 if complex_input else np.float64)

    for tone in spec.get("tones", []):
        angle = 2 * np.pi * tone["freq"] * n + tone.get("phase", 0.0)
        x = x + tone["amp"] * (np.exp(1j * angle) if complex_input else np.sin(angle))

    for step in spec.get("steps", []):
        x = x + step["amp"] * (n >= step["at"])

    noise = spec.get("noise_rms", 0.0)
    if complex_input:
        x = x + noise * (rng.standard_normal(samples) + 1j * rng.standard_normal(samples))
        return np.stack([q15(x.real), q15(x.imag)], axis=1).reshape(-1)
    return q15(x + noise * rng.standard_normal(samples))


def make_block(spec, params):
    """Instantiates e.g. {"block": "blocks.rotator_cc", "args": ["2 * pi * phase_inc / 65536"]}."""
    module, name = spec["block"].rsplit(".", 1)
    cls = getattr(importlib.import_module("gnuradio." + module), name)
    env = {"pi": math.pi, **{k: v for k, v in params.items() if isinstance(v, (int, float))}}
    args = [eval(a, {"__builtins__": {}}, env) if isinstance(a, str) else a for a in spec.get("args", [])]
    return cls(*args)


def run_case(case):
    rng = np.random.default_rng(case["seed"])
    x16 = make_input(case["input"], case["samples"], rng)
    complex_input = case["input"]["type"] == "complex"

    if complex_input:
        data = (x16[0::2] + 1j * x16[1::2]).astype(np.complex64) / FULL_SCALE
        source, sink = blocks.vector_source_c(data), blocks.vector_sink_c()
    else:
        source, sink = blocks.vector_source_f(x16.astype(np.float32) / FULL_SCALE), blocks.vector_sink_f()

    chain = [make_block(b, case["params"]) for b in case["gnuradio"]]
    tb = gr.top_block()
    tb.connect(source, *chain, sink)
    tb.run()

    out = np.asarray(sink.data())
    if complex_input:
        out = np.stack([out.real, out.imag], axis=1).reshape(-1)
    return x16, out.astype(np.float32)


def main(cases_dir, out_dir):
    for path in sorted(glob.glob(os.path.join(cases_dir, "*.json"))):
        with open(path, "rb") as f:
            raw = f.read()
        case = json.loads(raw)
        x16, ref = run_case(case)

        case_dir = os.path.join(out_dir, case["name"])
        os.makedirs(case_dir, exist_ok=True)
        x16.astype("<i2").tofile(os.path.join(case_dir, "input.s16le"))
        ref.astype("<f4").tofile(os.path.join(case_dir, "gnuradio.f32le"))
        manifest = {
            "case": case["name"],
            "case_sha256": hashlib.sha256(raw).hexdigest(),
            "gnuradio": gr.version(),
            "numpy": np.__version__,
        }
        with open(os.path.join(case_dir, "manifest.json"), "w") as f:
            json.dump(manifest, f, indent=2, sort_keys=True)
            f.write("\n")
        print(f"{case['name']}: {case['samples']} samples")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
