// ExHdl SIMD kernels: Q15 fixed-point stream kernels, bit-identical to the
// Nx reference (ExHdl.DSP.Blocks instantiated with ExHdl.Num.q(16, 15)).
//
// Arithmetic contract (shared with the Nx reference):
//   * products and sums are exact in int32 (the ranges are proven by
//     ExHdl.Passes.WidthCheck; the callers validate the inputs that make
//     those proofs hold, e.g. |table| <= 32767),
//   * rescale from Q30 to Q15: nearest = (v + 2^14) >> 15, truncate = v >> 15
//     (arithmetic shift),
//   * quantize = rescale, then saturate to int16.
#pragma once

#include <cstddef>
#include <cstdint>

namespace exhdl {

struct DdcParams {
  uint16_t phase;        // phase word before the first sample
  uint16_t phase_inc;    // added before each lookup (mod 2^16)
  int16_t gain;          // Q15
  int lut_bits;          // sine table address bits, 2..14
  bool round;            // nearest (true) or truncate (false)
  const int32_t* table;  // 2^lut_bits entries, round(32767 * sin(2*pi*k/n))
};

// NCO + complex mix + gain. Returns the phase word after the last sample.
uint16_t DdcQ15(const int16_t* in_i, const int16_t* in_q, size_t n, int16_t* out_i,
                int16_t* out_q, const DdcParams& p);

// FIR with constant Q15 taps over `ext` = (n_taps - 1) history samples
// (oldest first) followed by n new samples: out[j] = sum_k taps[k] * x[j - k].
// The int32 accumulator must be proven not to overflow by the caller.
void FirQ15(const int16_t* ext, size_t n, const int32_t* taps, size_t n_taps, bool round,
            int16_t* out);

// One-pole low-pass y' = y + alpha * (x - y). Returns the last y.
int16_t OnePoleQ15(const int16_t* x, size_t n, int16_t y0, int16_t alpha, bool round, int16_t* out);

// Scalar implementations with identical semantics (tails and tests).
uint16_t DdcQ15Scalar(const int16_t* in_i, const int16_t* in_q, size_t n, int16_t* out_i,
                      int16_t* out_q, const DdcParams& p);
void FirQ15Scalar(const int16_t* ext, size_t n, const int32_t* taps, size_t n_taps, bool round,
                  int16_t* out);

// Rate 1/n convolutional code (ExHdl.Comm.Convolutional): constraint
// length k (2..9), n generator polynomials (2..4), the current input as the
// most significant register bit.
struct ConvCode {
  unsigned k, n;
  unsigned polys[4];
};

// Hard-decision Viterbi decoder, bit-identical to the Elixir reference:
// `rx` holds n_steps groups of n bytes, 0/1 or 2 for an erasure; ties keep
// the predecessor with the smaller state, the traceback starts at the best
// final state (smallest on ties). `start_unknown` gives all states metric 0,
// otherwise state 0 starts at 0 and the others far above. One output byte
// (0/1) per step.
void Viterbi(const ConvCode& code, const uint8_t* rx, size_t n_steps, bool start_unknown, uint8_t* bits);

// Same decoder with the add-compare-select step vectorised (Highway),
// bit-identical; falls back to Viterbi when 2^(k-2) is not a multiple of
// the vector length.
void ViterbiSimd(const ConvCode& code, const uint8_t* rx, size_t n_steps, bool start_unknown, uint8_t* bits);

// Byte-level channel coding blocks of ExHdl.Comm, bit-identical to the
// Elixir references:
// Forney interleaver (inverse = deinterleaver) with I branches and unit
// delay M, delay lines starting at zero.
void ConvInterleave(const uint8_t* in, size_t n, int branches, int depth, bool inverse, uint8_t* out);
// Reed-Solomon code over GF(256), see ExHdl.Comm.ReedSolomon: roots
// beta^(fcr + i) with beta = alpha^prim, shortened by `shortening`.
struct RsParams {
  unsigned field_poly;
  int n, k, fcr, prim, shortening;
};
// Decodes `count` codewords of n - shortening bytes into k - shortening
// bytes each; failed codewords are copied uncorrected. Same results as the
// Elixir reference.
void RsDecode(const RsParams& code, const uint8_t* in, size_t count, uint8_t* out, size_t* corrected, size_t* failed);
// out = (in & keep) ^ mask with keep/mask repeating every `period` bytes
// (periodic additive scramblers, ExHdl.Comm.Scrambler).
void ByteAffine(const uint8_t* in, size_t n, const uint8_t* keep, const uint8_t* mask, size_t period, uint8_t* out);

// Name of the SIMD target chosen at runtime (e.g. "NEON", "SVE2", "AVX2").
const char* SimdTarget();

}  // namespace exhdl
