// Highway implementations with runtime dispatch (foreach_target): the
// translation unit is compiled once per SIMD target and the best one for the
// CPU is picked at runtime. See kernels.h for the arithmetic contract.

#undef HWY_TARGET_INCLUDE
#define HWY_TARGET_INCLUDE "kernels.cc"
#include "hwy/foreach_target.h"  // IWYU pragma: keep

#include "hwy/highway.h"
#include "kernels.h"

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

const char* SimdTargetImpl() { return hwy::TargetName(HWY_TARGET); }

}  // namespace HWY_NAMESPACE
}  // namespace exhdl
HWY_AFTER_NAMESPACE();

#if HWY_ONCE
namespace exhdl {

HWY_EXPORT(DdcQ15Impl);
HWY_EXPORT(FirQ15Impl);
HWY_EXPORT(SimdTargetImpl);

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

}  // namespace exhdl
#endif  // HWY_ONCE
