# Communication blocks (`ExHdl.Comm`)

Generic, parameterised building blocks for digital transmission chains.
A protocol is a configuration of these blocks plus whatever is truly
specific to it (frame signalling, its tables). DVB-T (`docs/dvbt.md`) is
built this way and stays bit-identical to GNU Radio's gr-dtv; the blocks
are also tested with parameters of other standards.

Every block has an Elixir reference. Where speed matters there is a native
kernel (Highway SIMD NIF) or a tensor form (Nx, compiled by EXLA) taking
the same parameters, with property tests proving it equal to the
reference.

| Block | Parameters | Fast form | Tested with |
|---|---|---|---|
| `GF`, `ReedSolomon` | GF(2^m) field polynomial, n, k, first root, root spacing, shortening | native decoder (GF(256)) | DVB, ATSC, CCSDS (fcr 112, prim 11), GF(16) |
| `LFSR` | length, taps, seed, output (feedback or last stage) | tables | DVB PRBS and pilot PRBS, 802.11 scrambler |
| `Scrambler` | one period as keep/xor byte masks | native | DVB energy dispersal |
| `ConvInterleaver` | branches I, unit depth M | native | random I, M |
| `Convolutional` | constraint length (native: 2-9), 1/n generators (native: n 2-4), puncturing matrix | scalar and SIMD Viterbi | DVB-T/802.11 K=7, GSM K=5, IS-95 K=9, rate 1/3 and 1/4 |
| `Constellation` | point table, or square QAM from an axis map and bit layout | tensor hard decisions | DVB QPSK/16/64-QAM, 802.11 16/64-QAM, 8-PSK |
| `Permutation` | gather tables, cycling per block | tensor | DVB bit and symbol interleavers, 802.11 interleaver |
| `OFDM` | FFT, cyclic prefix, carrier-to-bin map, per-class pilots and data carriers, scale | `carriers/4`, `equalise/3` | DVB-T 2k, 802.11a-style symbol |
| `OFDM.FrontEnd` | an OFDM config, a constellation, cell and bit deinterleavers | one compiled computation | DVB-T, 802.11a-style symbol |
| `OFDM.Sync` | CP timing and fractional offset, integer offset over reference carriers | tensor | DVB-T, 802.11a-style stream |
| `Bits` | packing 0/1 bytes | binaries | |

## Speed

DVB-T, 252 ms of signal on one Neoverse-N1 core (`scripts/dvbt_realtime.exs`),
before and after moving to the generic blocks:

| Stage | DVB-specific | generic |
|---|---|---|
| Front end (compiled) | 90-95 ms | 98-102 ms |
| Viterbi (SIMD) | 24 ms per 600k steps | 23 ms per 600k steps |
| Reed-Solomon | 17 ms | 12-15 ms |

The SIMD Viterbi has compile-time variants for 64 states (K = 7, the most
common constraint length) and a run-time state count for the rest.

## Semantics worth knowing

- Convolutional codes: the encoder register holds the current input as
  its most significant bit (octal generators as printed in standards).
  With puncturing, an incomplete last period is padded with erasures and
  decodes to a whole period.
- Hard decisions: the tensor form makes the same decisions as the
  nearest-point reference except exactly on a decision boundary.
- OFDM: the channel estimate is linear across frequency between pilots,
  extended past the outer pilots; pilot positions and values can differ
  per symbol class (DVB-T scattered pilot phases). Per-symbol pilot
  polarity sequences (802.11) are not modelled yet.
