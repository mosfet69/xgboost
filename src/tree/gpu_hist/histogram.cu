/*!
 * Copyright 2020 by XGBoost Contributors
 */
#include <thrust/reduce.h>
#include <thrust/iterator/transform_iterator.h>
#include <algorithm>
#include <ctgmath>
#include <limits>

#include "xgboost/base.h"
#include "row_partitioner.cuh"

#include "histogram.cuh"

#include "../../data/ellpack_page.cuh"
#include "../../common/device_helpers.cuh"

namespace xgboost {
namespace tree {
// Following 2 functions are slightly modifed version of fbcuda.

/* \brief Constructs a rounding factor used to truncate elements in a sum such that the
   sum of the truncated elements is the same no matter what the order of the sum is.

 * Algorithm 5: Reproducible Sequential Sum in 'Fast Reproducible Floating-Point
 * Summation' by Demmel and Nguyen

 * In algorithm 5 the bound is calculated as $max(|v_i|) * n$.  Here we use the bound
 *
 * \begin{equation}
 *   max( fl(\sum^{V}_{v_i>0}{v_i}), fl(\sum^{V}_{v_i<0}|v_i|) )
 * \end{equation}
 *
 * to avoid outliers, as the full reduction is reproducible on GPU with reduction tree.
 */
template <typename T>
DEV_INLINE __host__ T CreateRoundingFactor(T max_abs, int n) {
  T delta = max_abs / (static_cast<T>(1.0) - 2 * n * std::numeric_limits<T>::epsilon());

  // Calculate ceil(log_2(delta)).
  // frexpf() calculates exp and returns `x` such that
  // delta = x * 2^exp, where `x` in (-1.0, -0.5] U [0.5, 1).
  // Because |x| < 1, exp is exactly ceil(log_2(delta)).
  int exp;
  std::frexp(delta, &exp);

  // return M = 2 ^ ceil(log_2(delta))
  return std::ldexp(static_cast<T>(1.0), exp);
}

namespace {
struct Pair {
  GradientPair first;
  GradientPair second;
};
DEV_INLINE Pair operator+(Pair const& lhs, Pair const& rhs) {
  return {lhs.first + rhs.first, lhs.second + rhs.second};
}
}  // anonymous namespace

struct Clip : public thrust::unary_function<GradientPair, Pair> {
  static DEV_INLINE float Pclip(float v) {
    return v > 0 ? v : 0;
  }
  static DEV_INLINE float Nclip(float v) {
    return v < 0 ? abs(v) : 0;
  }

  DEV_INLINE Pair operator()(GradientPair x) const {
    auto pg = Pclip(x.GetGrad());
    auto ph = Pclip(x.GetHess());

    auto ng = Nclip(x.GetGrad());
    auto nh = Nclip(x.GetHess());

    return { GradientPair{ pg, ph }, GradientPair{ ng, nh } };
  }
};

template <typename GradientSumT>
GradientSumT CreateRoundingFactor(common::Span<GradientPair const> gpair) {
  using T = typename GradientSumT::ValueT;
  dh::XGBCachingDeviceAllocator<char> alloc;

  thrust::device_ptr<GradientPair const> gpair_beg {gpair.data()};
  thrust::device_ptr<GradientPair const> gpair_end {gpair.data() + gpair.size()};
  auto beg = thrust::make_transform_iterator(gpair_beg, Clip());
  auto end = thrust::make_transform_iterator(gpair_end, Clip());
  Pair p = thrust::reduce(thrust::cuda::par(alloc), beg, end, Pair{});
  GradientPair positive_sum {p.first}, negative_sum {p.second};

  auto histogram_rounding = GradientSumT {
    CreateRoundingFactor<T>(std::max(positive_sum.GetGrad(), negative_sum.GetGrad()),
                            gpair.size()),
    CreateRoundingFactor<T>(std::max(positive_sum.GetHess(), negative_sum.GetHess()),
                            gpair.size()) };
  return histogram_rounding;
}

template GradientPairPrecise CreateRoundingFactor(common::Span<GradientPair const> gpair);
template GradientPair CreateRoundingFactor(common::Span<GradientPair const> gpair);

template <typename GradientSumT>
__global__ void SharedMemHistKernel(xgboost::EllpackMatrix matrix,
                                    common::Span<const RowPartitioner::RowIndexT> d_ridx,
                                    GradientSumT* __restrict__ d_node_hist,
                                    const GradientPair* __restrict__ d_gpair,
                                    size_t n_elements,
                                    GradientSumT const rounding,
                                    bool use_shared_memory_histograms) {
  using T = typename GradientSumT::ValueT;
  extern __shared__ char smem[];
  GradientSumT* smem_arr = reinterpret_cast<GradientSumT*>(smem);  // NOLINT
  if (use_shared_memory_histograms) {
    dh::BlockFill(smem_arr, matrix.info.n_bins, GradientSumT());
    __syncthreads();
  }
  for (auto idx : dh::GridStrideRange(static_cast<size_t>(0), n_elements)) {
    int ridx = d_ridx[idx / matrix.info.row_stride];
    int gidx =
        matrix.gidx_iter[ridx * matrix.info.row_stride + idx % matrix.info.row_stride];
    if (gidx != matrix.info.n_bins) {
      GradientSumT truncated {
        TruncateWithRoundingFactor<T>(rounding.GetGrad(), d_gpair[ridx].GetGrad()),
        TruncateWithRoundingFactor<T>(rounding.GetHess(), d_gpair[ridx].GetHess()),
      };
      // If we are not using shared memory, accumulate the values directly into
      // global memory
      GradientSumT* atomic_add_ptr =
          use_shared_memory_histograms ? smem_arr : d_node_hist;
      dh::AtomicAddGpair(atomic_add_ptr + gidx, truncated);
    }
  }

  if (use_shared_memory_histograms) {
    // Write shared memory back to global memory
    __syncthreads();
    for (auto i : dh::BlockStrideRange(static_cast<size_t>(0), matrix.info.n_bins)) {
      GradientSumT truncated {
        TruncateWithRoundingFactor<T>(rounding.GetGrad(), smem_arr[i].GetGrad()),
        TruncateWithRoundingFactor<T>(rounding.GetHess(), smem_arr[i].GetHess()),
      };
      dh::AtomicAddGpair(d_node_hist + i, truncated);
    }
  }
}

template <typename GradientSumT>
void BuildGradientHistogram(EllpackMatrix const& matrix,
                            common::Span<GradientPair const> gpair,
                            common::Span<const uint32_t> d_ridx,
                            common::Span<GradientSumT> histogram,
                            GradientSumT rounding, bool shared) {
  const size_t smem_size =
      shared
      ? sizeof(GradientSumT) * matrix.info.n_bins
      : 0;
  auto n_elements = d_ridx.size() * matrix.info.row_stride;

  uint32_t items_per_thread = 8;
  uint32_t block_threads = 256;
  auto grid_size = static_cast<uint32_t>(
      common::DivRoundUp(n_elements, items_per_thread * block_threads));
  dh::LaunchKernel {grid_size, block_threads, smem_size} (
      SharedMemHistKernel<GradientSumT>,
      matrix, d_ridx, histogram.data(), gpair.data(), n_elements,
      rounding, shared);
}

template void BuildGradientHistogram<GradientPair>(
    EllpackMatrix const& matrix,
    common::Span<GradientPair const> gpair,
    common::Span<const uint32_t> ridx,
    common::Span<GradientPair> histogram,
    GradientPair rounding, bool shared);

template void BuildGradientHistogram<GradientPairPrecise>(
    EllpackMatrix const& matrix,
    common::Span<GradientPair const> gpair,
    common::Span<const uint32_t> ridx,
    common::Span<GradientPairPrecise> histogram,
    GradientPairPrecise rounding, bool shared);
}  // namespace tree
}  // namespace xgboost
