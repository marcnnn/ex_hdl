#!/usr/bin/env python3
"""Runs gr-dtv's DVB-T receiver (2k, QPSK, rate 1/2, GI 1/32) on a file of
little-endian complex64 samples and writes the transport stream.

Usage: dvbt_rx.py <samples.c64> <out.ts>
"""
import sys

from gnuradio import blocks, dtv, fft, gr
from gnuradio.fft import window

FFT, CP, CARRIERS, ACTIVE = 2048, 64, 1512, 1705


def main(src_path, out_path):
    c = dict(c=dtv.MOD_QPSK, h=dtv.NH, cr=dtv.C1_2, gi=dtv.GI_1_32, m=dtv.T2k)
    tb = gr.top_block()
    src = blocks.file_source(gr.sizeof_gr_complex, src_path, False)
    chain = [
        dtv.dvbt_ofdm_sym_acquisition(1, FFT, ACTIVE, CP, 30),
        fft.fft_vcc(FFT, True, window.rectangular(FFT), True, 1),
        dtv.dvbt_demod_reference_signals(gr.sizeof_gr_complex, FFT, CARRIERS, c["c"], c["h"], c["cr"], c["cr"], c["gi"], c["m"], 1, 0),
        dtv.dvbt_demap(CARRIERS, c["c"], c["h"], c["m"], 1),
        dtv.dvbt_symbol_inner_interleaver(CARRIERS, c["m"], 0),
        dtv.dvbt_bit_inner_deinterleaver(CARRIERS, c["c"], c["h"], c["m"]),
        blocks.vector_to_stream(1, CARRIERS),
        dtv.dvbt_viterbi_decoder(c["c"], c["h"], c["cr"], 768),
        dtv.dvbt_convolutional_deinterleaver(136, 12, 17),
        dtv.dvbt_reed_solomon_dec(2, 8, 0x11D, 255, 239, 8, 51, 8),
        dtv.dvbt_energy_descramble(8),
        blocks.file_sink(1, out_path, False),
    ]
    tb.connect(src, *chain)
    tb.run()


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
