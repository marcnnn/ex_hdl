// Highway implementations with runtime dispatch (foreach_target): the
// translation unit is compiled once per SIMD target and the best one for the
// CPU is picked at runtime. See kernels.h for the arithmetic contract.

#undef HWY_TARGET_INCLUDE
#define HWY_TARGET_INCLUDE "kernels.cc"
#include "hwy/foreach_target.h"  // IWYU pragma: keep

#include "hwy/highway.h"
#include "kernels.h"

#include <cstring>
#include <vector>

HWY_BEFORE_NAMESPACE();
namespace exhdl {
namespace HWY_NAMESPACE {
namespace hn = hwy::HWY_NAMESPACE;

// Q30 -> Q15 with the configured rounding; v must leave headroom for + 2^14.
template <class D, class V>
HWY_INLINE V Rescale15(D d, V v, bool round) {
  if (round) v = hn::Add(v, hn::Set(d, 1 << 14));
  return hn::ShiftRight<15>(v);
}

uint16_t DdcQ15Impl(const int16_t* HWY_RESTRICT in_i, const int16_t* HWY_RESTRICT in_q, size_t n,
                    int16_t* HWY_RESTRICT out_i, int16_t* HWY_RESTRICT out_q, const DdcParams& p) {
  const hn::ScalableTag<int32_t> d32;
  const hn::Rebind<uint32_t, decltype(d32)> du;
  const hn::Rebind<int16_t, decltype(d32)> d16;  // same lane count, int16
  const size_t lanes = hn::Lanes(d32);

  const int shift = 16 - p.lut_bits;
  const uint32_t mask = (1u << p.lut_bits) - 1;
  const uint32_t quarter = 1u << (p.lut_bits - 2);
  const uint32_t half_step = shift > 0 ? (1u << (shift - 1)) : 0;

  // Phase of lane k in the block starting at sample j: phase_j + (k + 1) * inc.
  const auto lane_steps = hn::Mul(hn::Iota(du, 1), hn::Set(du, p.phase_inc));
  const auto gain = hn::Set(d32, p.gain);
  uint32_t phase = p.phase;

  size_t j = 0;
  for (; j + lanes <= n; j += lanes) {
    auto ph = hn::And(hn::Add(hn::Set(du, phase), lane_steps), hn::Set(du, 0xFFFF));
    // Rounding the phase may reach index 2^lut_bits, which wraps to 0.
    if (p.round && shift > 0) ph = hn::Add(ph, hn::Set(du, half_step));
    const auto idx = hn::And(hn::ShiftRightSame(ph, shift), hn::Set(du, mask));
    const auto cos_idx = hn::And(hn::Add(idx, hn::Set(du, quarter)), hn::Set(du, mask));

    const auto s = hn::GatherIndex(d32, p.table, hn::BitCast(d32, idx));
    const auto c = hn::GatherIndex(d32, p.table, hn::BitCast(d32, cos_idx));
    const auto xi = hn::PromoteTo(d32, hn::LoadU(d16, in_i + j));
    const auto xq = hn::PromoteTo(d32, hn::LoadU(d16, in_q + j));

    // (xi + j xq) * (c + j s): |re|, |im| <= 2 * 32768 * 32767 < 2^31.
    auto re = Rescale15(d32, hn::Sub(hn::Mul(xi, c), hn::Mul(xq, s)), p.round);
    auto im = Rescale15(d32, hn::Add(hn::Mul(xi, s), hn::Mul(xq, c)), p.round);
    // |re| <= 65535 after the shift, times |gain| <= 32768 fits int32.
    re = Rescale15(d32, hn::Mul(re, gain), p.round);
    im = Rescale15(d32, hn::Mul(im, gain), p.round);

    hn::StoreU(hn::DemoteTo(d16, re), d16, out_i + j);  // saturating
    hn::StoreU(hn::DemoteTo(d16, im), d16, out_q + j);
    phase = (phase + static_cast<uint32_t>(lanes) * p.phase_inc) & 0xFFFF;
  }

  if (j < n) {
    DdcParams rest = p;
    rest.phase = static_cast<uint16_t>(phase);
    phase = DdcQ15Scalar(in_i + j, in_q + j, n - j, out_i + j, out_q + j, rest);
  }
  return static_cast<uint16_t>(phase);
}

void FirQ15Impl(const int16_t* HWY_RESTRICT ext, size_t n, const int32_t* HWY_RESTRICT taps,
                size_t n_taps, bool round, int16_t* HWY_RESTRICT out) {
  // Full-width int16 vectors; each tap is multiplied with a sliding window
  // of inputs and widened into two int32 accumulators in lane order
  // (WidenMulAccumulate, e.g. vmlal_s16 on NEON). The callers guarantee
  // |taps| <= 32767 and 32768 * sum(|taps|) < 2^31, so this is exact.
  const hn::ScalableTag<int16_t> d16;
  const hn::Repartition<int32_t, decltype(d16)> d32;
  const size_t lanes = hn::Lanes(d16);
  const size_t hist = n_taps - 1;

  size_t j = 0;
  for (; j + lanes <= n; j += lanes) {
    auto lo = hn::Zero(d32);
    auto hi = hn::Zero(d32);
    for (size_t k = 0; k < n_taps; ++k) {
      const auto x = hn::LoadU(d16, ext + j + hist - k);
      lo = hn::WidenMulAccumulate(d32, x, hn::Set(d16, static_cast<int16_t>(taps[k])), lo, hi);
    }
    // Saturating narrow of both halves, lanes kept in order.
    hn::StoreU(hn::OrderedDemote2To(d16, Rescale15(d32, lo, round), Rescale15(d32, hi, round)), d16, out + j);
  }
  if (j < n) FirQ15Scalar(ext + j, n - j, taps, n_taps, round, out + j);
}

// Viterbi add-compare-select over the 64 states, vectorised. Next states s
// and s + 32 (s < 32) both come from predecessors 2s (lsb 0) and 2s + 1
// (lsb 1); LoadInterleaved2 splits the metrics into those two vectors.
// Metrics are uint16 and renormalised every 256 steps by subtracting the
// minimum (a uniform shift never changes a comparison). The initial metric
// of unreachable states only needs to exceed every real path metric of the
// first 6 steps (at most 12), so 1000 gives the same decisions as the
// reference's 1000000. `expected` holds, per state, the expected x and y bit
// for predecessor lsb 0 and 1: [x0 | y0 | x1 | y1], 64 entries each.
void ViterbiDvbtSimdImpl(const uint8_t* HWY_RESTRICT rx, size_t n, bool start_unknown, uint64_t* HWY_RESTRICT decisions,
                         const uint16_t* HWY_RESTRICT expected, unsigned* final_state) {
  const hn::ScalableTag<uint16_t> d;
  const size_t lanes = hn::Lanes(d);
  const uint16_t* x0 = expected;
  const uint16_t* y0 = expected + 64;
  const uint16_t* x1 = expected + 128;
  const uint16_t* y1 = expected + 192;
  const uint64_t lane_mask = lanes >= 64 ? ~0ull : (1ull << lanes) - 1;

  HWY_ALIGN uint16_t metric[64];
  HWY_ALIGN uint16_t next[64];
  for (int s = 0; s < 64; ++s) metric[s] = start_unknown || s == 0 ? 0 : 1000;

  for (size_t i = 0; i < n; ++i) {
    const uint16_t rx_x = rx[2 * i], rx_y = rx[2 * i + 1];
    // distance per lane: (rx xor expected), zero for an erasure (2)
    const auto vx = hn::Set(d, static_cast<uint16_t>(rx_x & 1)), vy = hn::Set(d, static_cast<uint16_t>(rx_y & 1));
    const auto ex = hn::Set(d, static_cast<uint16_t>(rx_x != 2)), ey = hn::Set(d, static_cast<uint16_t>(rx_y != 2));
    uint64_t decision = 0;

    for (size_t j = 0; j < 32; j += lanes) {
      hn::Vec<decltype(d)> even, odd;
      hn::LoadInterleaved2(d, metric + 2 * j, even, odd);

      for (size_t s = j; s < 64; s += 32) {
        const auto d0 = hn::Add(hn::Mul(hn::Xor(vx, hn::LoadU(d, x0 + s)), ex), hn::Mul(hn::Xor(vy, hn::LoadU(d, y0 + s)), ey));
        const auto d1 = hn::Add(hn::Mul(hn::Xor(vx, hn::LoadU(d, x1 + s)), ex), hn::Mul(hn::Xor(vy, hn::LoadU(d, y1 + s)), ey));
        const auto c0 = hn::Add(even, d0);
        const auto c1 = hn::Add(odd, d1);
        hn::StoreU(hn::Min(c0, c1), d, next + s);

        uint8_t packed[8] = {0};
        hn::StoreMaskBits(d, hn::Lt(c1, c0), packed);
        uint64_t m = 0;
        for (size_t k = 0; k < (lanes + 7) / 8; ++k) m |= static_cast<uint64_t>(packed[k]) << (8 * k);
        decision |= (m & lane_mask) << s;
      }
    }

    decisions[i] = decision;
    for (int s = 0; s < 64; ++s) metric[s] = next[s];

    if ((i & 255) == 255) {
      uint16_t lo = metric[0];
      for (int s = 1; s < 64; ++s) lo = metric[s] < lo ? metric[s] : lo;
      for (int s = 0; s < 64; ++s) metric[s] = static_cast<uint16_t>(metric[s] - lo);
    }
  }

  unsigned best = 0;
  for (unsigned s = 1; s < 64; ++s)
    if (metric[s] < metric[best]) best = s;
  *final_state = best;
}

const char* SimdTargetImpl() { return hwy::TargetName(HWY_TARGET); }

}  // namespace HWY_NAMESPACE
}  // namespace exhdl
HWY_AFTER_NAMESPACE();

#if HWY_ONCE
namespace exhdl {

HWY_EXPORT(DdcQ15Impl);
HWY_EXPORT(FirQ15Impl);
HWY_EXPORT(SimdTargetImpl);
HWY_EXPORT(ViterbiDvbtSimdImpl);

uint16_t DdcQ15(const int16_t* in_i, const int16_t* in_q, size_t n, int16_t* out_i,
                int16_t* out_q, const DdcParams& p) {
  return HWY_DYNAMIC_DISPATCH(DdcQ15Impl)(in_i, in_q, n, out_i, out_q, p);
}

void FirQ15(const int16_t* ext, size_t n, const int32_t* taps, size_t n_taps, bool round,
            int16_t* out) {
  HWY_DYNAMIC_DISPATCH(FirQ15Impl)(ext, n, taps, n_taps, round, out);
}

const char* SimdTarget() { return HWY_DYNAMIC_DISPATCH(SimdTargetImpl)(); }

// -- scalar reference --------------------------------------------------------

static inline int32_t rescale15(int32_t v, bool round) { return (round ? v + (1 << 14) : v) >> 15; }

static inline int16_t sat16(int32_t v) {
  return static_cast<int16_t>(v < -32768 ? -32768 : (v > 32767 ? 32767 : v));
}

uint16_t DdcQ15Scalar(const int16_t* in_i, const int16_t* in_q, size_t n, int16_t* out_i,
                      int16_t* out_q, const DdcParams& p) {
  const int shift = 16 - p.lut_bits;
  const uint32_t mask = (1u << p.lut_bits) - 1;
  const uint32_t quarter = 1u << (p.lut_bits - 2);
  uint32_t phase = p.phase;

  for (size_t j = 0; j < n; ++j) {
    phase = (phase + p.phase_inc) & 0xFFFF;
    uint32_t ph = phase;
    if (p.round && shift > 0) ph += 1u << (shift - 1);
    const uint32_t idx = (ph >> shift) & mask;
    const int32_t s = p.table[idx];
    const int32_t c = p.table[(idx + quarter) & mask];
    const int32_t xi = in_i[j], xq = in_q[j];
    int32_t re = rescale15(xi * c - xq * s, p.round);
    int32_t im = rescale15(xi * s + xq * c, p.round);
    out_i[j] = sat16(rescale15(re * p.gain, p.round));
    out_q[j] = sat16(rescale15(im * p.gain, p.round));
  }
  return static_cast<uint16_t>(phase);
}

void FirQ15Scalar(const int16_t* ext, size_t n, const int32_t* taps, size_t n_taps, bool round,
                  int16_t* out) {
  const size_t hist = n_taps - 1;
  for (size_t j = 0; j < n; ++j) {
    int32_t acc = 0;
    for (size_t k = 0; k < n_taps; ++k) acc += taps[k] * ext[j + hist - k];
    out[j] = sat16(rescale15(acc, round));
  }
}

// A true recurrence: sequential by nature (one subtract, multiply, shift and
// add per sample). Independent channels could share SIMD lanes later.
int16_t OnePoleQ15(const int16_t* x, size_t n, int16_t y0, int16_t alpha, bool round, int16_t* out) {
  int32_t y = y0;
  for (size_t j = 0; j < n; ++j) {
    // |alpha * (x - y)| <= 32768 * 65535 < 2^31 - 2^14
    y = sat16(y + rescale15(alpha * (x[j] - y), round));
    out[j] = static_cast<int16_t>(y);
  }
  return static_cast<int16_t>(y);
}

// -- DVB-T Viterbi ----------------------------------------------------------

namespace {
struct Trellis {
  // for next state s and predecessor choice c (0: lsb 0, 1: lsb 1)
  uint8_t prev[64][2];
  uint8_t x[64][2];
  uint8_t y[64][2];

  Trellis() {
    auto parity = [](unsigned v) { return static_cast<uint8_t>(__builtin_popcount(v) & 1); };
    for (unsigned s = 0; s < 64; ++s) {
      const unsigned b = s >> 5;
      for (unsigned c = 0; c < 2; ++c) {
        const unsigned p = ((s << 1) & 63) | c;
        const unsigned reg = (b << 6) | p;
        prev[s][c] = static_cast<uint8_t>(p);
        x[s][c] = parity(reg & 0171);
        y[s][c] = parity(reg & 0133);
      }
    }
  }
};
const Trellis kTrellis;

inline uint32_t dist(uint8_t r, uint8_t e) { return r == 2 ? 0 : (r != e); }
}  // namespace

void ViterbiDvbt(const uint8_t* rx, size_t n, bool start_unknown, uint8_t* bits) {
  uint32_t metric[64], next[64];
  for (int s = 0; s < 64; ++s) metric[s] = start_unknown || s == 0 ? 0 : 1000000;
  std::vector<uint64_t> decisions(n);

  for (size_t i = 0; i < n; ++i) {
    const uint8_t rx_x = rx[2 * i], rx_y = rx[2 * i + 1];
    // branch metric of each expected output pair (x, y)
    const uint32_t bm[2][2] = {{dist(rx_x, 0) + dist(rx_y, 0), dist(rx_x, 0) + dist(rx_y, 1)},
                               {dist(rx_x, 1) + dist(rx_y, 0), dist(rx_x, 1) + dist(rx_y, 1)}};
    uint64_t mask = 0;
    for (unsigned s = 0; s < 64; ++s) {
      const uint32_t c0 = metric[kTrellis.prev[s][0]] + bm[kTrellis.x[s][0]][kTrellis.y[s][0]];
      const uint32_t c1 = metric[kTrellis.prev[s][1]] + bm[kTrellis.x[s][1]][kTrellis.y[s][1]];
      const bool take1 = c1 < c0;
      next[s] = take1 ? c1 : c0;
      mask |= static_cast<uint64_t>(take1) << s;
    }
    decisions[i] = mask;
    // Renormalise (subtracting the minimum keeps every comparison) so the
    // metrics stay small for arbitrarily long blocks.
    uint32_t lo = next[0];
    for (int s = 1; s < 64; ++s) lo = next[s] < lo ? next[s] : lo;
    for (int s = 0; s < 64; ++s) metric[s] = next[s] - lo;
  }

  unsigned best = 0;
  for (unsigned s = 1; s < 64; ++s)
    if (metric[s] < metric[best]) best = s;

  unsigned s = best;
  for (size_t i = n; i-- > 0;) {
    const unsigned lsb = (decisions[i] >> s) & 1;
    bits[i] = static_cast<uint8_t>(s >> 5);
    s = ((s << 1) & 63) | lsb;
  }
}

void ViterbiDvbtSimd(const uint8_t* rx, size_t n, bool start_unknown, uint8_t* bits) {
  if (n == 0) return;
  // expected (x, y) per next state and predecessor choice, as in Trellis
  alignas(64) uint16_t expected[256];
  for (unsigned s = 0; s < 64; ++s)
    for (unsigned c = 0; c < 2; ++c) {
      expected[128 * c + s] = kTrellis.x[s][c];
      expected[128 * c + 64 + s] = kTrellis.y[s][c];
    }

  std::vector<uint64_t> decisions(n);
  unsigned s = 0;
  HWY_DYNAMIC_DISPATCH(ViterbiDvbtSimdImpl)(rx, n, start_unknown, decisions.data(), expected, &s);

  for (size_t i = n; i-- > 0;) {
    const unsigned lsb = (decisions[i] >> s) & 1;
    bits[i] = static_cast<uint8_t>(s >> 5);
    s = ((s << 1) & 63) | lsb;
  }
}

// -- DVB-T outer stages ------------------------------------------------------

void ForneyDeinterleave(const uint8_t* in, size_t n, uint8_t* out) {
  constexpr int I = 12, M = 17;
  // branch j: FIFO of (I - 1 - j) * M bytes, as a ring buffer
  std::vector<uint8_t> fifo[I];
  size_t pos[I] = {0};
  for (int j = 0; j < I; ++j) fifo[j].assign((I - 1 - j) * M, 0);
  for (size_t k = 0; k < n; ++k) {
    const int j = static_cast<int>(k % I);
    if (fifo[j].empty()) {
      out[k] = in[k];
      continue;
    }
    out[k] = fifo[j][pos[j]];
    fifo[j][pos[j]] = in[k];
    pos[j] = (pos[j] + 1) % fifo[j].size();
  }
}

namespace {
// GF(256) for a given primitive polynomial.
struct GF {
  uint8_t exp[512];
  uint8_t log[256];
  explicit GF(unsigned poly) {
    unsigned x = 1;
    for (int i = 0; i < 255; ++i) {
      exp[i] = static_cast<uint8_t>(x);
      log[x] = static_cast<uint8_t>(i);
      x <<= 1;
      if (x & 0x100) x ^= poly;
    }
    for (int i = 255; i < 512; ++i) exp[i] = exp[i - 255];
    log[0] = 0;
  }
  uint8_t mul(uint8_t a, uint8_t b) const { return (a && b) ? exp[log[a] + log[b]] : 0; }
  uint8_t div(uint8_t a, uint8_t b) const { return a ? exp[log[a] + 255 - log[b]] : 0; }
  uint8_t pow(long i) const { return exp[((i % 255) + 255) % 255]; }
};

uint8_t eval_low(const GF& gf, const uint8_t* p, int len, uint8_t x) {
  uint8_t acc = 0;
  for (int i = len - 1; i >= 0; --i) acc = gf.mul(acc, x) ^ p[i];
  return acc;
}

// Same algorithm and failure rules as ExHdl.Comm.ReedSolomon.decode/2.
// cw: n - shortening symbols; out: k - shortening symbols. -1 on failure.
int rs_decode(const GF& gf, const RsParams& c, const uint8_t* cw, uint8_t* out) {
  const int n = c.n, parity = c.n - c.k, len = c.n - c.shortening, msg = c.k - c.shortening;
  uint8_t r[255] = {0};
  std::memcpy(r + c.shortening, cw, len);

  uint8_t syn[255];
  bool zero = true;
  for (int i = 0; i < parity; ++i) {
    const uint8_t x = gf.pow(static_cast<long>(c.prim) * (c.fcr + i));
    uint8_t acc = 0;
    for (int k = 0; k < n; ++k) acc = gf.mul(acc, x) ^ r[k];
    syn[i] = acc;
    zero = zero && acc == 0;
  }
  std::memcpy(out, cw, msg);
  if (zero) return 0;

  // Berlekamp-Massey (lowest degree first)
  uint8_t lam[256] = {1}, b[256] = {1}, t[256];
  int l = 0, m = 1;
  uint8_t bb = 1;
  for (int rr = 0; rr < parity; ++rr) {
    uint8_t dd = 0;
    for (int i = 0; i <= l; ++i) dd ^= gf.mul(lam[i], syn[rr - i]);
    if (dd == 0) {
      ++m;
      continue;
    }
    const uint8_t coef = gf.div(dd, bb);
    std::memcpy(t, lam, sizeof lam);
    for (int i = 0; i + m <= parity; ++i) lam[i + m] ^= gf.mul(coef, b[i]);
    if (2 * l <= rr) {
      l = rr + 1 - l;
      std::memcpy(b, t, sizeof b);
      bb = dd;
      m = 1;
    } else {
      ++m;
    }
  }
  int deg = parity;
  while (deg > 0 && lam[deg] == 0) --deg;

  int roots[256];
  int nroots = 0;
  for (int p = 0; p < n; ++p)
    if (eval_low(gf, lam, deg + 1, gf.pow(-static_cast<long>(c.prim) * p)) == 0) roots[nroots++] = p;
  if (nroots != deg || deg > parity / 2) return -1;
  for (int i = 0; i < nroots; ++i)
    if (roots[i] >= n - c.shortening) return -1;

  uint8_t omega[256] = {0};
  for (int k = 0; k < parity; ++k)
    for (int i = 0; i <= k && i <= deg; ++i) omega[k] ^= gf.mul(lam[i], syn[k - i]);
  uint8_t deriv[256] = {0};
  for (int i = 1; i <= deg; ++i)
    if (i % 2 == 1) deriv[i - 1] = lam[i];

  for (int i = 0; i < nroots; ++i) {
    const long p = roots[i];
    const uint8_t xinv = gf.pow(-static_cast<long>(c.prim) * p);
    const uint8_t num = gf.mul(eval_low(gf, omega, parity, xinv), gf.pow(static_cast<long>(c.prim) * p * (1 - c.fcr)));
    r[n - 1 - p] ^= gf.div(num, eval_low(gf, deriv, deg, xinv));
  }
  std::memcpy(out, r + c.shortening, msg);
  return deg;
}

// PRBS 1 + x^14 + x^15 from 100101010000000, as bytes for one group of 8
// packets: 187 bytes, then 1 (sync, generator running but unused), ...
struct Prbs {
  uint8_t bytes[8 * 188];
  Prbs() {
    unsigned reg = 0x4A80;  // 0b100101010000000
    for (int i = 0; i < 8 * 188; ++i) {
      uint8_t byte = 0;
      for (int k = 0; k < 8; ++k) {
        const unsigned out = ((reg >> 1) ^ reg) & 1;
        byte = static_cast<uint8_t>((byte << 1) | out);
        reg = (reg >> 1) | (out << 14);
      }
      bytes[i] = byte;
    }
  }
};
const Prbs kPrbs;
}  // namespace

void RsDecode(const RsParams& c, const uint8_t* in, size_t count, uint8_t* out, size_t* corrected, size_t* failed) {
  const GF gf(c.field_poly);
  const size_t len = c.n - c.shortening, msg = c.k - c.shortening;
  *corrected = 0;
  *failed = 0;
  for (size_t i = 0; i < count; ++i) {
    const int r = rs_decode(gf, c, in + len * i, out + msg * i);
    if (r < 0) ++*failed; else *corrected += static_cast<size_t>(r);
  }
}

void Descramble(const uint8_t* in, size_t n_groups, uint8_t* out) {
  for (size_t g = 0; g < n_groups; ++g) {
    const uint8_t* src = in + g * 1504;
    uint8_t* dst = out + g * 1504;
    // PRBS byte index: payload of packet p starts after p sync bytes
    size_t prbs = 0;
    for (int p = 0; p < 8; ++p) {
      dst[188 * p] = 0x47;
      if (p > 0) ++prbs;  // the generator runs through sync bytes 2..8
      for (int k = 1; k < 188; ++k) dst[188 * p + k] = src[188 * p + k] ^ kPrbs.bytes[prbs++];
    }
  }
}

}  // namespace exhdl
#endif  // HWY_ONCE
