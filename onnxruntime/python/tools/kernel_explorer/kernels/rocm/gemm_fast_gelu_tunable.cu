// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "python/tools/kernel_explorer/kernels/rocm/gemm_fast_gelu_tunable.h"

#include <pybind11/stl.h>

#include <string>
#include <vector>

#include "core/providers/rocm/tunable/gemm_fast_gelu_common.h"
#include "core/providers/rocm/tunable/gemm_fast_gelu_tunable.cuh"
#include "python/tools/kernel_explorer/device_array.h"
#include "python/tools/kernel_explorer/kernel_explorer_interface.h"

using namespace onnxruntime::rocm::tunable::blas;
using namespace onnxruntime::rocm::tunable::blas::internal;

namespace py = pybind11;

namespace onnxruntime {
template <typename T>
class GemmFastGeluTunable : public IKernelExplorer {
 public:
  GemmFastGeluTunable(BlasOp opa, BlasOp opb,
                      int64_t m, int64_t n, int64_t k,
                      double alpha,
                      DeviceArray& a, int64_t lda,
                      DeviceArray& b, int64_t ldb,
                      DeviceArray& bias,
                      double beta,
                      DeviceArray& c, int64_t ldc) : params_{} {
    ROCBLAS_CALL_THROW(rocblas_create_handle(&rocblas_handle_));
    params_.tuning = true;
    params_.stream = Stream();
    params_.handle = rocblas_handle_;
    params_.opa = opa;
    params_.opb = opb;
    params_.m = m;
    params_.n = n;
    params_.k = k;
    params_.alpha = alpha;
    params_.a = static_cast<T*>(a.ptr());
    params_.lda = lda;
    params_.b = static_cast<T*>(b.ptr());
    params_.ldb = ldb;
    params_.bias = static_cast<T*>(bias.ptr());
    params_.beta = beta;
    params_.c = static_cast<T*>(c.ptr());
    params_.ldc = ldc;

    op_.EnableTuning();
  }

  ~GemmFastGeluTunable() {
    ROCBLAS_CALL_THROW(rocblas_destroy_handle(rocblas_handle_));
    rocblas_handle_ = nullptr;
  }

  void Run() override {
    ORT_THROW_IF_ERROR((op_(&params_)));
  }

  std::vector<std::string> ListOps() const {
    return {"GemmFastGeluTunable"};
  }

  bool SelectOp(const std::string& name) {
    return name == "GemmFastGeluTunable";
  }

 private:
  using ParamsT = GemmFastGeluParams<T>;
  ParamsT params_{};
  rocblas_handle rocblas_handle_;
  GemmFastGeluTunableOp<T> op_{};
};

#define REGISTER_OP(type)                                                \
  py::class_<GemmFastGeluTunable<type>>(m, "GemmFastGeluTunable_" #type) \
      .def(py::init<BlasOp, BlasOp, int64_t, int64_t, int64_t,           \
                    double,                                              \
                    DeviceArray&, int64_t,                               \
                    DeviceArray&, int64_t,                               \
                    DeviceArray&,                                        \
                    double,                                              \
                    DeviceArray&, int64_t>())                            \
      .def("SetRepeats", &GemmFastGeluTunable<type>::SetRepeats)         \
      .def("Run", &GemmFastGeluTunable<type>::Run)                       \
      .def("Profile", &GemmFastGeluTunable<type>::Profile)               \
      .def("ListOps", &GemmFastGeluTunable<type>::ListOps)               \
      .def("SelectOp", &GemmFastGeluTunable<type>::SelectOp);

void InitGemmFastGeluTunable(py::module m) {
  REGISTER_OP(float)
  REGISTER_OP(half)
}

#undef REGISTER_OP

}  // namespace onnxruntime
