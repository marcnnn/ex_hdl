#!/usr/bin/env python3
"""DVB-T reference data from GNU Radio's gr-dtv (transmitter and receiver).

Usage: dvbt_golden.py <output dir>   (via scripts/dvbt_golden.sh, Debian image)

Runs the gr-dtv transmitter on a deterministic transport stream, then the
gr-dtv receiver on the (noise-free) transmitter output, and records every
stage. Bit-level streams are stored as SHA-256 + length + the first bytes
(they are regenerated exactly by ExHdl's implementation); for the float
front end a window of time-domain samples and the receiver's equalised
carriers are stored.

Configuration: 2k mode, QPSK, code rate 1/2, guard interval 1/32,
non-hierarchical, cell id included (EN 300 744).
"""
import hashlib
import json
import os
import sys

import numpy as np
from gnuradio import blocks, digital, dtv, fft, gr
from gnuradio.fft import window

SUPERFRAMES = 6
PACKETS = 252 * SUPERFRAMES        # 2k QPSK 1/2: 252 TS packets per superframe
FFT, CP, CARRIERS, ACTIVE = 2048, 64, 1512, 1705
HEAD = 4096                         # bytes of each stream kept for debugging
WINDOW = 8                          # OFDM symbols stored for front-end tests


def ts_packets(n):
    """Deterministic transport stream, reproduced by ExHdl.DVBT.TestSignal."""
    out = bytearray()
    for i in range(n):
        pid = 0x100 + i % 3
        out += bytes([0x47, (pid >> 8) & 0x1F, pid & 0xFF, 0x10 | (i & 0x0F)])
        out += bytes((i * 7 + j * 13 + (j * j) % 251) & 0xFF for j in range(184))
    return bytes(out)


def describe(name, data, dtype):
    raw = np.asarray(data, dtype=dtype).tobytes()
    return name, {"dtype": np.dtype(dtype).name, "items": len(data), "sha256": hashlib.sha256(raw).hexdigest()}, raw[:HEAD]


def main(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    ts = ts_packets(PACKETS)
    cfg = dict(c=dtv.MOD_QPSK, h=dtv.NH, cr=dtv.C1_2, gi=dtv.GI_1_32, m=dtv.T2k)

    # -- transmitter --------------------------------------------------------
    tb = gr.top_block()
    src = blocks.vector_source_b(list(ts), False)
    ed = dtv.dvbt_energy_dispersal(1)
    rs = dtv.dvbt_reed_solomon_enc(2, 8, 0x11D, 255, 239, 8, 51, 8)
    ci = dtv.dvbt_convolutional_interleaver(136, 12, 17)
    ic = dtv.dvbt_inner_coder(1, CARRIERS, cfg["c"], cfg["h"], cfg["cr"])
    bi = dtv.dvbt_bit_inner_interleaver(CARRIERS, cfg["c"], cfg["h"], cfg["m"])
    si = dtv.dvbt_symbol_inner_interleaver(CARRIERS, cfg["m"], 1)
    mp = dtv.dvbt_map(CARRIERS, cfg["c"], cfg["h"], cfg["m"], 1)
    rf = dtv.dvbt_reference_signals(gr.sizeof_gr_complex, CARRIERS, FFT, cfg["c"], cfg["h"], cfg["cr"], cfg["cr"], cfg["gi"], cfg["m"], 1, 0)
    cp = digital.ofdm_cyclic_prefixer(FFT, FFT + CP, 0, "")

    tx_sinks = {
        "tx_energy_dispersal": (ed, blocks.vector_sink_b(1504)),
        "tx_reed_solomon": (rs, blocks.vector_sink_b(1632)),
        "tx_outer_interleaver": (ci, blocks.vector_sink_b(1)),
        "tx_inner_coder": (ic, blocks.vector_sink_b(CARRIERS)),
        "tx_bit_interleaver": (bi, blocks.vector_sink_b(CARRIERS)),
        "tx_symbol_interleaver": (si, blocks.vector_sink_b(CARRIERS)),
        "tx_map": (mp, blocks.vector_sink_c(CARRIERS)),
        "tx_ofdm": (cp, blocks.vector_sink_c(1)),
    }
    tb.connect(src, ed, rs, ci, ic, bi, si, mp, rf, cp)
    for blk, sink in tx_sinks.values():
        tb.connect(blk, sink)
    tb.run()
    tx = {k: np.asarray(s.data()) for k, (_, s) in tx_sinks.items()}

    # -- receiver -----------------------------------------------------------
    tb = gr.top_block()
    rsrc = blocks.vector_source_c(tx["tx_ofdm"].astype(np.complex64).tolist(), False)
    acq = dtv.dvbt_ofdm_sym_acquisition(1, FFT, ACTIVE, CP, 30)
    ff = fft.fft_vcc(FFT, True, window.rectangular(FFT), True, 1)
    drs = dtv.dvbt_demod_reference_signals(gr.sizeof_gr_complex, FFT, CARRIERS, cfg["c"], cfg["h"], cfg["cr"], cfg["cr"], cfg["gi"], cfg["m"], 1, 0)
    dm = dtv.dvbt_demap(CARRIERS, cfg["c"], cfg["h"], cfg["m"], 1)
    sd = dtv.dvbt_symbol_inner_interleaver(CARRIERS, cfg["m"], 0)
    bd = dtv.dvbt_bit_inner_deinterleaver(CARRIERS, cfg["c"], cfg["h"], cfg["m"])
    v2s = blocks.vector_to_stream(1, CARRIERS)
    vit = dtv.dvbt_viterbi_decoder(cfg["c"], cfg["h"], cfg["cr"], 768)
    cd = dtv.dvbt_convolutional_deinterleaver(136, 12, 17)
    rsd = dtv.dvbt_reed_solomon_dec(2, 8, 0x11D, 255, 239, 8, 51, 8)
    eds = dtv.dvbt_energy_descramble(8)

    rx_sinks = {
        "rx_equalised": (drs, blocks.vector_sink_c(CARRIERS)),
        "rx_demap": (dm, blocks.vector_sink_b(CARRIERS)),
        "rx_symbol_deinterleaver": (sd, blocks.vector_sink_b(CARRIERS)),
        "rx_bit_deinterleaver": (bd, blocks.vector_sink_b(CARRIERS)),
        "rx_viterbi": (vit, blocks.vector_sink_b(1)),
        "rx_outer_deinterleaver": (cd, blocks.vector_sink_b(1632)),
        "rx_reed_solomon": (rsd, blocks.vector_sink_b(1504)),
        "rx_ts": (eds, blocks.vector_sink_b(1)),
    }
    tb.connect(rsrc, acq, ff, drs, dm, sd, bd, v2s, vit, cd, rsd, eds)
    for blk, sink in rx_sinks.values():
        tb.connect(blk, sink)
    tb.run()
    rx = {k: np.asarray(s.data()) for k, (_, s) in rx_sinks.items()}
    tags = [
        {"offset": t.offset, "key": str(t.key), "value": int(gr.pmt.to_python(t.value)) if gr.pmt.is_integer(t.value) else str(t.value)}
        for t in rx_sinks["rx_equalised"][1].tags()
    ]

    # Which transmitted OFDM symbol is the receiver's first output symbol?
    tx_sym = tx["tx_symbol_interleaver"].reshape(-1, CARRIERS)
    rx_sym = rx["rx_demap"].reshape(-1, CARRIERS)
    first_tx_symbol = next((k for k in range(len(tx_sym)) if np.array_equal(tx_sym[k], rx_sym[0])), None)

    # Where does the received transport stream start in the transmitted one?
    rx_ts = bytes(rx["rx_ts"].astype(np.uint8))
    ts_offset = ts.find(rx_ts[:188 * 4]) if len(rx_ts) >= 188 * 4 else -1
    matching = 0
    if ts_offset >= 0:
        while matching < len(rx_ts) and ts_offset + matching < len(ts) and rx_ts[matching] == ts[ts_offset + matching]:
            matching += 1

    streams, heads = {}, {}
    for name, data in list(tx.items()) + list(rx.items()):
        dtype = np.complex64 if data.dtype.kind == "c" else np.uint8
        key, info, head = describe(name, data, dtype)
        streams[key] = info
        heads[key] = head
        with open(os.path.join(out_dir, f"{name}.head"), "wb") as f:
            f.write(head)

    # Front-end window: transmitted samples and equalised carriers for WINDOW
    # symbols starting at the receiver's first output symbol.
    if first_tx_symbol is not None:
        start = first_tx_symbol * (FFT + CP)
        tx["tx_ofdm"][start:start + WINDOW * (FFT + CP)].astype("<c8").tofile(os.path.join(out_dir, "window_tx_samples.c64"))
        rx["rx_equalised"][: WINDOW * CARRIERS].astype("<c8").tofile(os.path.join(out_dir, "window_rx_equalised.c64"))

    # TPS carrier signs (Re > 0 -> 0) of every symbol of superframe 1,
    # taken from the transmitted samples: checks the TPS bits incl. BCH.
    tps_carriers = [34, 50, 209, 346, 413, 569, 595, 688, 790, 901, 1073, 1219, 1262, 1286, 1469, 1594, 1687]
    sym_len = FFT + CP
    tps_signs = []
    for sym in range(272, 544):
        t = tx["tx_ofdm"][sym * sym_len + CP:(sym + 1) * sym_len]
        spec = np.fft.fft(t)
        tps_signs.append("".join("0" if spec[(k + 172 - FFT // 2) % FFT].real > 0 else "1" for k in tps_carriers))

    manifest = {
        "config": {"mode": "2k", "constellation": "qpsk", "code_rate": [1, 2], "guard_interval": [1, 32], "hierarchy": "none",
                   "fft": FFT, "cyclic_prefix": CP, "data_carriers": CARRIERS, "active_carriers": ACTIVE, "cell_id": 0},
        "superframes": SUPERFRAMES,
        "packets": PACKETS,
        "streams": streams,
        "rx_tags": tags[:64],
        "rx_first_tx_symbol": first_tx_symbol,
        "rx_ts_offset_in_tx": ts_offset,
        "rx_ts_matching_bytes": matching,
        "rx_ts_bytes": len(rx_ts),
        "window_symbols": WINDOW,
        "tps_signs_superframe1": tps_signs,
        "gnuradio": gr.version(),
        "numpy": np.__version__,
    }
    with open(os.path.join(out_dir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")

    print(f"tx symbols {len(tx_sym)}, rx symbols {len(rx_sym)}, first rx = tx symbol {first_tx_symbol}")
    print(f"rx TS {len(rx_ts)} bytes, starts at tx byte {ts_offset}, {matching} bytes identical")


if __name__ == "__main__":
    main(sys.argv[1])
