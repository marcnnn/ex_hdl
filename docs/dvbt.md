# DVB-T: full chain against GNU Radio (gr-dtv)

ExHdl contains a complete DVB-T transmitter and receiver (ETSI EN 300 744,
2k mode, non-hierarchical) as exact reference implementations in Elixir
(`ExHdl.DVBT.*`), compared stage by stage and end to end with GNU Radio
3.10.12's gr-dtv. Fedora's GNU Radio lacks gr-dtv; the reference runs in a
Debian image (`test/gnuradio/debian/Containerfile`).

Configuration: 2k, QPSK, code rate 1/2, guard interval 1/32, cell id 0.

## Stage by stage

| Stage | Result |
|---|---|
| Energy dispersal, RS(204,188), Forney interleaver | bit-identical (SHA-256 over 6 superframes) |
| Convolutional code + puncturing, bit and symbol interleaver | bit-identical |
| QPSK mapping | bit-identical float32 values |
| OFDM: pilots, TPS (sync, parameters, cell id, BCH), IFFT, guard | samples equal to 138 dB (float32 precision); TPS signs of a whole superframe exact |
| Receiver back end (deinterleavers, Viterbi, RS, descrambler) on gr-dtv's receiver input | source TS, starting at the same packet as gr-dtv; deinterleaver outputs equal |
| Receiver front end (FFT, pilot channel estimate, linear interpolation, equalisation) | 137 dB against the ideal constellation on a noise-free channel; hard decisions equal to gr-dtv's |

Observation: on the same noise-free signal gr-dtv's equalised output drops
to 40-67 dB against the ideal points for some symbols (its per-symbol
frequency/sampling corrections), while hard decisions stay correct.

## End to end with noise

ExHdl's transmitter (4 superframes, 1008 packets) -> AWGN -> both receivers
on the identical samples (`MIX_ENV=test mix run scripts/dvbt_compare.exs 4.0 4.5 5.0`):

| SNR per sample (C/N in band) | ExHdl correct packets | gr-dtv correct packets |
|---|---|---|
| noise-free | 992 / 992 | 640 / 640 |
| 3.5 dB (4.3 dB) | 0.1 % | 0 % |
| 4.0 dB (4.8 dB) | 50 % | 3 % |
| 4.5 dB (5.3 dB) | 98.6 % | 91.9 % |
| 5.0 dB (5.8 dB) | 100 % | 100 % |
| 6.0 / 8.0 dB | 100 % | 100 % |

Both receivers use hard-decision Viterbi decoding; with soft decisions the
standard expects quasi-error-free reception around C/N 3.1 dB, about 2 dB
lower. The comparison is not yet like for like:

- ExHdl's receiver gets the symbol timing (no acquisition yet); gr-dtv
  synchronises itself (cyclic prefix correlation, TPS) and starts output
  one superframe later.
- ExHdl's Viterbi traces back over the whole block; gr-dtv uses a short
  traceback (about 40 bits at rate 1/2).

## Not done yet

- Acquisition (timing, frequency offset) in ExHdl's receiver.
- Soft-decision Viterbi.
- Fixed-point front end (integer FFT, conjugate-multiply equalisation) and
  the SIMD/FPGA paths; the Elixir reference receiver needs about 70 s for
  4 superframes.
- 16/64-QAM, other code rates and 8k mode are implemented in the building
  blocks but not yet compared against gr-dtv.

## Running

```sh
mix test --only dvbt                                   # stage comparisons (25 s)
scripts/dvbt_golden.sh                                 # regenerate reference data
MIX_ENV=test mix run scripts/dvbt_compare.exs 4.5 5.0  # end to end, needs podman image
```
