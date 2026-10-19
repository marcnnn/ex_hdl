// Erlang NIF bindings for the SIMD kernels (module ExHdl.SIMD.NIF).
// Inputs are read zero-copy from binaries; outputs are written directly
// into new binaries. All functions run on dirty CPU schedulers.

#include <dlfcn.h>
#include <erl_nif.h>

#include <cstring>
#include <fine.hpp>
#include <stdexcept>
#include <string>
#include <tuple>
#include <vector>

#include "kernels.h"

namespace {

// A fresh binary of `size` bytes and a pointer to write into it.
template <typename T>
std::tuple<fine::Term, T*> new_binary(ErlNifEnv* env, size_t count) {
  ERL_NIF_TERM term;
  auto* data = enif_make_new_binary(env, count * sizeof(T), &term);
  if (data == nullptr) throw std::runtime_error("cannot allocate binary");
  return {fine::Term(term), reinterpret_cast<T*>(data)};
}

template <typename T>
const T* view(const ErlNifBinary& bin, const char* what) {
  if (bin.size % sizeof(T) != 0) throw std::invalid_argument(std::string(what) + ": size is not a multiple of the element size");
  return reinterpret_cast<const T*>(bin.data);
}

}  // namespace

std::tuple<fine::Term, fine::Term, int64_t> ddc_q15(ErlNifEnv* env, ErlNifBinary in_i, ErlNifBinary in_q,
                                                    int64_t phase, int64_t phase_inc, int64_t gain,
                                                    int64_t lut_bits, bool round, ErlNifBinary table) {
  if (in_i.size != in_q.size) throw std::invalid_argument("ddc_q15: I and Q must have the same length");
  if (lut_bits < 2 || lut_bits > 14) throw std::invalid_argument("ddc_q15: lut_bits must be 2..14");
  if (table.size != (size_t{1} << lut_bits) * sizeof(int32_t))
    throw std::invalid_argument("ddc_q15: table must have 2^lut_bits int32 entries");

  const auto* t = view<int32_t>(table, "table");
  // The int32 range proof assumes |table| <= 32767 (amplitude 2^15 - 1).
  for (size_t k = 0; k < (size_t{1} << lut_bits); ++k)
    if (t[k] < -32767 || t[k] > 32767) throw std::invalid_argument("ddc_q15: table entries must be within +-32767");

  const size_t n = in_i.size / sizeof(int16_t);
  auto [out_i_term, out_i] = new_binary<int16_t>(env, n);
  auto [out_q_term, out_q] = new_binary<int16_t>(env, n);

  exhdl::DdcParams p{static_cast<uint16_t>(phase), static_cast<uint16_t>(phase_inc), static_cast<int16_t>(gain),
                     static_cast<int>(lut_bits), round, t};
  const uint16_t last = exhdl::DdcQ15(view<int16_t>(in_i, "i"), view<int16_t>(in_q, "q"), n, out_i, out_q, p);
  return {out_i_term, out_q_term, last};
}
FINE_NIF(ddc_q15, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// `history` = the previous n_taps - 1 samples (oldest first), `x` = new
// samples. Returns {y, new_history}. History and block are joined with one
// memcpy here; doing that on the Elixir side costs as much as the filter.
std::tuple<fine::Term, fine::Term> fir_q15(ErlNifEnv* env, ErlNifBinary history, ErlNifBinary x, ErlNifBinary taps,
                                           bool round) {
  const size_t n_taps = taps.size / sizeof(int32_t);
  const size_t hist = n_taps - 1;
  if (n_taps < 2) throw std::invalid_argument("fir_q15: need at least 2 taps");
  if (history.size != hist * sizeof(int16_t)) throw std::invalid_argument("fir_q15: history must have n_taps - 1 samples");

  // The int32 accumulator is exact while 32768 * sum(|taps|) < 2^31.
  const auto* t = view<int32_t>(taps, "taps");
  int64_t bound = 0;
  for (size_t k = 0; k < n_taps; ++k) {
    if (t[k] < -32767 || t[k] > 32767) throw std::invalid_argument("fir_q15: taps must be within +-32767");
    bound += t[k] < 0 ? -int64_t{t[k]} : t[k];
  }
  if (bound * 32768 >= (int64_t{1} << 31)) throw std::invalid_argument("fir_q15: taps too large for an int32 accumulator");

  const size_t n = x.size / sizeof(int16_t);
  std::vector<int16_t> ext(hist + n);
  std::memcpy(ext.data(), view<int16_t>(history, "history"), hist * sizeof(int16_t));
  std::memcpy(ext.data() + hist, view<int16_t>(x, "x"), n * sizeof(int16_t));

  auto [out_term, out] = new_binary<int16_t>(env, n);
  exhdl::FirQ15(ext.data(), n, t, n_taps, round, out);

  auto [hist_term, new_hist] = new_binary<int16_t>(env, hist);
  std::memcpy(new_hist, ext.data() + n, hist * sizeof(int16_t));
  return {out_term, hist_term};
}
FINE_NIF(fir_q15, ERL_NIF_DIRTY_JOB_CPU_BOUND);

std::tuple<fine::Term, int64_t> one_pole_q15(ErlNifEnv* env, ErlNifBinary x, int64_t y0, int64_t alpha, bool round) {
  const size_t n = x.size / sizeof(int16_t);
  auto [out_term, out] = new_binary<int16_t>(env, n);
  const int16_t last = exhdl::OnePoleQ15(view<int16_t>(x, "x"), n, static_cast<int16_t>(y0), static_cast<int16_t>(alpha), round, out);
  return {out_term, last};
}
FINE_NIF(one_pole_q15, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// Scalar reference kernels, exposed for testing the SIMD paths.
std::tuple<fine::Term, fine::Term, int64_t> ddc_q15_scalar(ErlNifEnv* env, ErlNifBinary in_i, ErlNifBinary in_q,
                                                           int64_t phase, int64_t phase_inc, int64_t gain,
                                                           int64_t lut_bits, bool round, ErlNifBinary table) {
  if (in_i.size != in_q.size || table.size != (size_t{1} << lut_bits) * sizeof(int32_t))
    throw std::invalid_argument("ddc_q15_scalar: bad arguments");
  const size_t n = in_i.size / sizeof(int16_t);
  auto [out_i_term, out_i] = new_binary<int16_t>(env, n);
  auto [out_q_term, out_q] = new_binary<int16_t>(env, n);
  exhdl::DdcParams p{static_cast<uint16_t>(phase), static_cast<uint16_t>(phase_inc), static_cast<int16_t>(gain),
                     static_cast<int>(lut_bits), round, view<int32_t>(table, "table")};
  const uint16_t last = exhdl::DdcQ15Scalar(view<int16_t>(in_i, "i"), view<int16_t>(in_q, "q"), n, out_i, out_q, p);
  return {out_i_term, out_q_term, last};
}
FINE_NIF(ddc_q15_scalar, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// rx: one byte per received code bit position of the mother code, pairs
// (x, y), values 0/1 or 2 for an erasure. Returns one byte (0/1) per pair.
fine::Term viterbi_dvbt(ErlNifEnv* env, ErlNifBinary rx, bool start_unknown) {
  if (rx.size % 2 != 0) throw std::invalid_argument("viterbi_dvbt: rx must hold (x, y) pairs");
  for (size_t i = 0; i < rx.size; ++i)
    if (rx.data[i] > 2) throw std::invalid_argument("viterbi_dvbt: values must be 0, 1 or 2");
  const size_t n = rx.size / 2;
  auto [out_term, out] = new_binary<uint8_t>(env, n);
  exhdl::ViterbiDvbt(rx.data, n, start_unknown, out);
  return out_term;
}
FINE_NIF(viterbi_dvbt, ERL_NIF_DIRTY_JOB_CPU_BOUND);

fine::Term viterbi_dvbt_simd(ErlNifEnv* env, ErlNifBinary rx, bool start_unknown) {
  if (rx.size % 2 != 0) throw std::invalid_argument("viterbi_dvbt_simd: rx must hold (x, y) pairs");
  for (size_t i = 0; i < rx.size; ++i)
    if (rx.data[i] > 2) throw std::invalid_argument("viterbi_dvbt_simd: values must be 0, 1 or 2");
  const size_t n = rx.size / 2;
  auto [out_term, out] = new_binary<uint8_t>(env, n);
  exhdl::ViterbiDvbtSimd(rx.data, n, start_unknown, out);
  return out_term;
}
FINE_NIF(viterbi_dvbt_simd, ERL_NIF_DIRTY_JOB_CPU_BOUND);

fine::Term forney_deinterleave(ErlNifEnv* env, ErlNifBinary in) {
  auto [out_term, out] = new_binary<uint8_t>(env, in.size);
  exhdl::ForneyDeinterleave(in.data, in.size, out);
  return out_term;
}
FINE_NIF(forney_deinterleave, ERL_NIF_DIRTY_JOB_CPU_BOUND);

std::tuple<fine::Term, int64_t, int64_t> rs_decode(ErlNifEnv* env, ErlNifBinary in, int64_t field_poly, int64_t n, int64_t k,
                                                     int64_t fcr, int64_t prim, int64_t shortening) {
  if (n > 255 || k >= n || shortening >= k || (field_poly & 0x100) == 0)
    throw std::invalid_argument("rs_decode: needs a GF(256) code with 0 <= shortening < k < n <= 255");
  const exhdl::RsParams c{static_cast<unsigned>(field_poly), static_cast<int>(n), static_cast<int>(k),
                          static_cast<int>(fcr), static_cast<int>(prim), static_cast<int>(shortening)};
  const size_t len = c.n - c.shortening, msg = c.k - c.shortening;
  if (in.size % len != 0) throw std::invalid_argument("rs_decode: input must be whole codewords");
  const size_t count = in.size / len;
  auto [out_term, out] = new_binary<uint8_t>(env, count * msg);
  size_t corrected = 0, failed = 0;
  exhdl::RsDecode(c, in.data, count, out, &corrected, &failed);
  return {out_term, static_cast<int64_t>(corrected), static_cast<int64_t>(failed)};
}
FINE_NIF(rs_decode, ERL_NIF_DIRTY_JOB_CPU_BOUND);

fine::Term descramble(ErlNifEnv* env, ErlNifBinary in) {
  if (in.size % 1504 != 0) throw std::invalid_argument("descramble: input must be whole groups of 8 packets");
  auto [out_term, out] = new_binary<uint8_t>(env, in.size);
  exhdl::Descramble(in.data, in.size / 1504, out);
  return out_term;
}
FINE_NIF(descramble, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// -- generated kernels (ExHdl.SIMD.Compiler) --------------------------------
// A generated shared library exports
//   extern "C" void exhdl_kernel(const void* const* in, void* const* out);
// with all shapes and types compiled in.

using KernelFn = void (*)(const void* const*, void* const*);

struct Kernel {
  void* handle = nullptr;
  KernelFn fn = nullptr;

  explicit Kernel(const std::string& path) {
    handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) throw std::runtime_error(std::string("kernel_load: ") + dlerror());
    fn = reinterpret_cast<KernelFn>(dlsym(handle, "exhdl_kernel"));
    if (fn == nullptr) throw std::runtime_error("kernel_load: exhdl_kernel not found");
  }

  void destructor(ErlNifEnv*) {
    if (handle != nullptr) dlclose(handle);
    handle = nullptr;
  }
};
FINE_RESOURCE(Kernel);

fine::ResourcePtr<Kernel> kernel_load(ErlNifEnv*, std::string path) { return fine::make_resource<Kernel>(path); }
FINE_NIF(kernel_load, ERL_NIF_DIRTY_JOB_IO_BOUND);

// Inputs are read in place; outputs are allocated as binaries of the given
// byte sizes and filled by the kernel.
std::vector<fine::Term> kernel_run(ErlNifEnv* env, fine::ResourcePtr<Kernel> kernel, std::vector<ErlNifBinary> inputs,
                                   std::vector<int64_t> output_bytes) {
  std::vector<const void*> in;
  in.reserve(inputs.size());
  for (const auto& bin : inputs) in.push_back(bin.data);

  std::vector<fine::Term> terms;
  std::vector<void*> out;
  for (int64_t bytes : output_bytes) {
    ERL_NIF_TERM term;
    auto* data = enif_make_new_binary(env, static_cast<size_t>(bytes), &term);
    if (data == nullptr) throw std::runtime_error("kernel_run: cannot allocate output");
    terms.push_back(fine::Term(term));
    out.push_back(data);
  }

  kernel->fn(in.data(), out.data());
  return terms;
}
FINE_NIF(kernel_run, ERL_NIF_DIRTY_JOB_CPU_BOUND);

std::string simd_target(ErlNifEnv*) { return exhdl::SimdTarget(); }
FINE_NIF(simd_target, 0);

FINE_INIT("Elixir.ExHdl.SIMD.NIF");
