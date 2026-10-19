# DVB-T: full chain against GNU Radio (gr-dtv)

ExHdl contains a complete DVB-T transmitter and receiver (ETSI EN 300 744,
2k mode, non-hierarchical) as exact reference implementations in Elixir
(`ExHdl.DVBT.*`), compared stage by stage and end to end with GNU Radio
3.10.12's gr-dtv. Fedora's GNU Radio lacks gr-dtv; the reference runs in a
Debian image (`test/gnuradio/debian/Containerfile`).

Configuration: 2k, QPSK, code rate 1/2, guard interval 1/32, cell id 0.

| Module | Stage |
|---|---|
| `ExHdl.DVBT.EnergyDispersal` | PRBS randomisation (scramble/descramble) |
| `ExHdl.DVBT.ReedSolomon` | RS(204, 188, t = 8) encode/decode (Berlekamp-Massey, Chien, Forney) |
| `ExHdl.DVBT.OuterInterleaver` | Forney interleaver I = 12, M = 17 |
| `ExHdl.DVBT.Convolutional` | K = 7 code, all puncturing rates, hard-decision Viterbi |
| `ExHdl.DVBT.Inner` | bit/symbol interleaving, Gray mapping, hard demapping |
| `ExHdl.DVBT.TPS` | TPS bits incl. BCH(67, 53) parity |
| `ExHdl.DVBT.OFDM` | pilots, TPS DBPSK, IFFT modulation; FFT, channel estimate, equalisation |
| `ExHdl.DVBT.Transmitter`, `ExHdl.DVBT.Receiver` | complete chains |

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

## End to end: fair comparison

ExHdl's transmitter (4 superframes, 1008 packets), then an unknown start
(3333 samples of noise in front), a carrier frequency offset of 1.37
subcarriers (6.1 kHz) and AWGN. Both receivers synchronise themselves and
decode the identical samples (`MIX_ENV=test mix run scripts/dvbt_compare.exs 4.0 4.5 5.0`):

| SNR per sample (C/N in band) | ExHdl correct packets | gr-dtv correct packets |
|---|---|---|
| noise-free | 992 / 992 | 640 / 640 |
| 3.5 dB (4.3 dB) | 0.2 % | 0 % |
| 4.0 dB (4.8 dB) | 49.1 % | 9.9 % |
| 4.5 dB (5.3 dB) | 99.3 % | 91.9 % |
| 5.0 / 6.0 / 8.0 dB | 100 % | 100 % |

ExHdl's acquisition (`ExHdl.DVBT.Sync`): cyclic prefix correlation for
timing and fractional frequency offset, continual pilot energy for the
integer offset, TPS sync word and frame number for the superframe start;
it finds the start to the sample and the offset to within 0.003
subcarriers. ExHdl outputs from the first complete superframe, gr-dtv one
superframe later (it locks during the first).

Both use hard-decision Viterbi decoding; with soft decisions the standard
expects quasi-error-free reception around C/N 3.1 dB. The remaining 0.3-0.5
dB advantage near the threshold is plausibly ExHdl's full-block Viterbi
traceback (gr-dtv: about 40 bits at rate 1/2) and its equaliser (see the
observation above); not separated yet.

## Speed

Same 2.3M samples (4 superframes), Neoverse-N1, one process each:

| Receiver | Time | Throughput |
|---|---|---|
| gr-dtv (C++, VOLK) | 16.4 s | 0.14 Msamples/s |
| ExHdl fast path (`Receiver.receive_sync/2`: EXLA tensors + native Viterbi) | 1.4-1.7 s | 1.4-1.6 Msamples/s |
| ExHdl list reference (`Receiver.receive/2`) | 81 s | 0.03 Msamples/s |

Real time for 2k DVB-T is 9.14 Msamples/s; neither receiver reaches it on
this machine. In ExHdl's fast path the native Viterbi decoder runs at
about 5 Mbit/s (scalar C++); the fast path makes the same hard decisions
and decodes to the same output as the reference.

## Not done yet

- Soft-decision Viterbi.
- Fixed-point front end (integer FFT, conjugate-multiply equalisation) and
  its SIMD/FPGA paths; a SIMD Viterbi.
- 16/64-QAM, other code rates and 8k mode are implemented in the building
  blocks but not yet compared against gr-dtv.

## Running

```sh
mix test --only dvbt                                   # stage comparisons and end to end
mix test --only dvbt_live                              # end to end against gr-dtv (podman)
scripts/dvbt_golden.sh                                 # regenerate reference data
MIX_ENV=test mix run scripts/dvbt_compare.exs 4.5 5.0  # end to end, needs podman image
```
