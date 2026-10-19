# DVB-T: full chain against GNU Radio

ExHdl implements a DVB-T transmitter and receiver (ETSI EN 300 744; 2k
mode, non-hierarchical, QPSK/16-QAM/64-QAM, all code rates) and compares
them with GNU Radio's gr-dtv, stage by stage and end to end. The tested
configuration is 2k, QPSK, rate 1/2, guard interval 1/32.

| Module | Stage |
|---|---|
| `ExHdl.DVBT.EnergyDispersal` | PRBS randomisation (scramble/descramble) |
| `ExHdl.DVBT.ReedSolomon` | RS(204, 188, t = 8) encode/decode (BM, Chien, Forney) |
| `ExHdl.DVBT.OuterInterleaver` | Forney interleaver I = 12, M = 17 |
| `ExHdl.DVBT.Convolutional` | K = 7 code, all puncturing rates, hard-decision Viterbi |
| `ExHdl.DVBT.Inner` | bit/symbol interleaving, Gray mapping, hard demapping |
| `ExHdl.DVBT.TPS` | TPS bits incl. BCH(67, 53) parity |
| `ExHdl.DVBT.OFDM` | pilots, TPS DBPSK, IFFT modulation; FFT, channel estimate, equalisation |
| `ExHdl.DVBT.Transmitter`, `ExHdl.DVBT.Receiver` | complete chains |

These are exact reference implementations (integer arithmetic for the bit
level, float for the OFDM front end); fixed-point and compiled versions
are the next step.

## Stage by stage (`mix test --only dvbt`)

Reference data from `scripts/dvbt_golden.sh` (gr-dtv 3.10.12 in a Debian
image; Fedora's GNU Radio lacks gr-dtv): 6 superframes, every stage of
gr-dtv's transmitter and receiver. Bit-level streams are stored as
SHA-256 + length + the first 4 KB; ExHdl regenerates them.

| Stage | Result |
|---|---|
| energy dispersal, RS encoder, outer interleaver | bit-identical (whole stream) |
| inner coder, bit interleaver, symbol interleaver | bit-identical |
| mapper (complex64 constellation points) | bit-identical |
| OFDM modulation | 138 dB SNR vs gr-dtv's samples (float32 limit) |
| TPS | all 272 symbols x 17 carriers of a superframe identical |
| receiver back end on gr-dtv's receiver input | source TS from the same packet as gr-dtv, no RS corrections |
| receiver front end | 137 dB vs the ideal constellation; hard decisions equal to gr-dtv's |

gr-dtv's receiver demaps exactly ExHdl's transmitted carrier words
(checked by hash), so both receiver back ends get identical input.

**Observation:** on a noise-free, offset-free channel gr-dtv's equaliser
output deviates from the ideal constellation in some symbols (40-67 dB
instead of about 135 dB; e.g. the 3rd-5th symbol after lock), while
ExHdl's float equaliser stays at float precision. Hard decisions are
unaffected. Likely its per-symbol frequency/sampling offset tracking;
not investigated further.

## End to end with noise (`scripts/dvbt_compare.exs`)

ExHdl's transmitter generates 4 superframes (1008 packets), complex AWGN
is added, and both receivers decode the identical samples: ExHdl's
receiver and gr-dtv's (in the container). Score: transport packets equal
to the source.

Noise-free, gr-dtv decodes ExHdl's signal completely (640/640 packets
after locking), as does ExHdl's receiver (992/992).

| SNR per sample (C/N in band) | ExHdl | gr-dtv |
|---|---|---|
| 3.5 dB (4.3 dB) | 0.1 % | 0 % |
| 4.0 dB (4.8 dB) | 50 % | 3 % |
| 4.5 dB (5.3 dB) | 98.6 % | 92 % |
| 5.0 dB (5.8 dB) | 100 % | 100 % |

Not yet an equal comparison: ExHdl's receiver is given the symbol timing
(no acquisition, no frequency/timing offset estimation), gr-dtv
synchronises itself. Its offset estimates and its short Viterbi traceback
(about 40 bits for rate 1/2, against a full-block traceback here) are
plausible reasons for its higher threshold; neither has been measured
separately.

## Limits and next steps

- Acquisition (cyclic-prefix correlation, frequency offset) so ExHdl's
  receiver synchronises itself; channels with frequency offset and
  multipath.
- Fixed-point front end (integer FFT, equalisation by conjugate multiply)
  as an `ExHdl.Num` block, compared against the float front end.
- Speed: the Elixir receiver needs about 70 s for 4 superframes; the
  FFT/equaliser fit the compiled paths, Viterbi is a classic SIMD kernel.
- Soft-decision Viterbi; 8k mode, 16/64-QAM end to end.
