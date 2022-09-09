// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#pragma once

#include "core/framework/op_kernel.h"
#include "core/framework/allocator.h"
#include "core/providers/xnnpack/detail/utils.h"
#include "core/providers/cpu/tensor/transpose.h"

namespace onnxruntime {
class GraphViewer;
namespace xnnpack {


class Transpose final : public OpKernel, public TransposeBase {
 public:
  Transpose(const OpKernelInfo& info);

  Status Compute(OpKernelContext* ctx) const override;
  static bool IsOnnxNodeSupported(const NodeUnit& nodeunit, const GraphViewer& graph);

 private:
  InlinedVector<size_t> perm_;
  OpComputeType op_type_ = OpComputeType::op_compute_type_invalid;
  XnnpackOperator op0_;
};
}  // namespace xnnpack
}  // namespace onnxruntime