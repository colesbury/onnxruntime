/*
 * SPDX-FileCopyrightText: Copyright (c) 1993-2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//#include "common.cuh"
#include <cassert>
#include <cstring>
#include <iostream>
#include <tuple>
#include <vector>

#include "mha_runner.h"
#include "fused_multihead_attention_v2.h"

namespace onnxruntime {
namespace contrib {
namespace cuda {

static inline void set_alpha(uint32_t& alpha, float norm, Data_type dtype)
{
    if (dtype == DATA_TYPE_FP16)
    {
        half2 h2 = __float2half2_rn(norm);
        alpha = reinterpret_cast<const uint32_t&>(h2);
    }
    else if (dtype == DATA_TYPE_FP32)
    {
        alpha = reinterpret_cast<const uint32_t&>(norm);
    }
    else if (dtype == DATA_TYPE_INT32)
    {
        int32_t inorm = static_cast<int32_t>(norm);
        alpha = reinterpret_cast<const uint32_t&>(inorm);
    }
    else
    {
        ORT_ENFORCE(false);
    }
}

class FusedMHARunnerFP16v2::mhaImpl
{
public:
    mhaImpl(FusedMHARunnerFP16v2* interface)
        : interface(interface)
        , sm(interface->mSm)
        , xmmaKernel(getXMMAKernelsV2(DATA_TYPE_FP16, sm))
    {
      ORT_ENFORCE((sm == kSM_72 || sm == kSM_75 || sm == kSM_80 || sm == kSM_86 || sm == kSM_87),
                  "Unsupported architecture");
      params.clear();
    }

    ~mhaImpl() {}

    size_t getPackedMaskSizeInBytes() const
    {
        // check that we initialized
        ORT_ENFORCE(xmmas_m > 0);
        ORT_ENFORCE(threads_per_cta > 0);
        ORT_ENFORCE(interface->mB > 0);
        return interface->mB * xmmas_m * threads_per_cta * sizeof(uint32_t);
    }

    void setup(const int S, const int B)
    {
        // TODO these implementation details might be better centralized into the XMMA code, since they are needed in
        // several places (also outside of this plugin)
        size_t warps_m{};
        size_t warps_n{};
        size_t warps_k = 1;
        if (S == 64 || S == 96 || S == 128)
        {
            warps_m = 2;
            warps_n = 2;
        }
        else if (S == 256 || S == 192)
        {
            warps_m = 1;
            warps_n = 4;
        }
        else if (S == 384 || S == 512)
        {
            warps_m = 1;
            warps_n = 8;
        }

        else
        {
            ORT_ENFORCE(false, "Unsupporte sequence length");
        }
        // The number of threads per CTA.
        threads_per_cta = warps_m * warps_n * warps_k * 32;
        // The number of xmmas in the M dimension. We use one uint32_t per XMMA in the M dimension.
        xmmas_m = (S + 16 * warps_m - 1) / (16 * warps_m);
        // The number of xmmas in the N dimension.
        xmmas_n = (S + 16 * warps_n - 1) / (16 * warps_n);

        const float scale_bmm1 = interface->mRsqrtHeadSize;
        const float scale_softmax = 1.f; // Seems to be only required for int8
        const float scale_bmm2 = 1.f;

        Data_type scale_type = DATA_TYPE_FP16;
        set_alpha(params.scale_bmm1, scale_bmm1, scale_type);
        set_alpha(params.scale_softmax, scale_softmax, scale_type);
        set_alpha(params.scale_bmm2, scale_bmm2, scale_type);

        params.b = B;
        params.h = interface->mNumHeads;
        params.s = S;
        params.d = interface->mHeadSize;

        // mLdQKV = 3 * B * mNumHeads * mHeadSize;
        // mLdOut = B * mNumHeads * mHeadSize;

        params.qkv_stride_in_bytes = 3 * interface->mNumHeads * interface->mHeadSize * sizeof(half);
        params.packed_mask_stride_in_bytes = xmmas_m * threads_per_cta * sizeof(uint32_t);
        params.o_stride_in_bytes = interface->mNumHeads * interface->mHeadSize * sizeof(half);
    }

    void run(const void* qkvPtr,
             const void* maskPtr, const void* cuSeqlenPtr, void* output, void* workspace, cudaStream_t stream)
    {

        params.qkv_ptr = const_cast<void*>(qkvPtr);

        // dummy input in V2/V3 because now we use cu_seqlens
        params.packed_mask_ptr = nullptr;

        params.o_ptr = output;

        params.cu_seqlens = static_cast<int*>(const_cast<void*>(cuSeqlenPtr));
        xmmaKernel->run(params, stream);
        CUDA_CALL_THROW(cudaPeekAtLastError());
    }

    bool isValid(int s) const
    {
        return xmmaKernel->isValid(s);
    }

private:
    FusedMHARunnerFP16v2* interface;
    Fused_multihead_attention_params_v2 params;
    int sm;
    const FusedMultiHeadAttentionXMMAKernelV2* xmmaKernel;
    size_t xmmas_m;
    size_t xmmas_n;
    size_t threads_per_cta;
};

FusedMHARunnerFP16v2::FusedMHARunnerFP16v2(const int numHeads, const int headSize, const int sm)
    : MHARunner(numHeads, headSize, 2)
    , mSm(sm)
    , pimpl(new mhaImpl(this))
{
}

void FusedMHARunnerFP16v2::setup(const int S, const int B)
{
    MHARunner::setup(S, B);
    pimpl->setup(S, B);
}

size_t FusedMHARunnerFP16v2::getWorkspaceSize() const
{
    return 0;
}

void FusedMHARunnerFP16v2::setScaleList(const float scaleQkv, const float scaleCtx, const float dqProbs)
{
}

bool FusedMHARunnerFP16v2::isValid(int s) const
{
    return pimpl->isValid(s);
}

// Int8 starts here: TODO refactor the duplicate stuff

class FusedMHARunnerInt8v2::mhaImpl
{

public:
    mhaImpl(FusedMHARunnerInt8v2* interface)
        : interface(interface)
        , sm(interface->mSm)
        , xmmaKernel(getXMMAKernelsV2(DATA_TYPE_INT8, sm))
        , mDqProbs(interface->mDqProbs)
    {
      ORT_ENFORCE((sm == kSM_72 || sm == kSM_75 || sm == kSM_80 || sm == kSM_86 || sm == kSM_87),
                  "Unsupported architecture");
      params.clear();
    }

    ~mhaImpl() {}

    size_t getPackedMaskSizeInBytes() const
    {
        ORT_ENFORCE(xmmas_m > 0);
        ORT_ENFORCE(threads_per_cta > 0);
        ORT_ENFORCE(interface->mB > 0);
        return interface->mB * xmmas_m * threads_per_cta * sizeof(uint32_t);
    }

    void setup(const int S, const int B)
    {
        size_t warps_m{};
        size_t warps_n{};
        size_t warps_k = 1;
        if (S == 128)
        {
            warps_m = 2;
            warps_n = 2;
        }
        else if (S == 256 || S == 192)
        {
            warps_m = 1;
            warps_n = 4;
        }
        else if (S == 384 || S == 512)
        {
            warps_m = 1;
            warps_n = 8;
        }

        else
        {
            ORT_ENFORCE(false, "Unsupported sequence length");
        }
        // The number of threads per CTA.
        threads_per_cta = warps_m * warps_n * warps_k * 32;
        // The number of xmmas in the M dimension. We use one uint32_t per XMMA in the M dimension.
        xmmas_m = (S + 16 * warps_m - 1) / (16 * warps_m);
        // The number of xmmas in the N dimension.
        xmmas_n = (S + 16 * warps_n - 1) / (16 * warps_n);

        params.b = B;
        params.h = interface->mNumHeads;
        params.s = S;
        params.d = interface->mHeadSize;
        params.use_int8_scale_max = true;
        params.packed_mask_stride_in_bytes = xmmas_m * threads_per_cta * sizeof(uint32_t);
        params.qkv_stride_in_bytes = 3 * interface->mNumHeads * interface->mHeadSize * sizeof(int8_t);
        params.o_stride_in_bytes = interface->mNumHeads * interface->mHeadSize * sizeof(int8_t);
    }

    void run(const void* qkvPtr,
        const void* maskPtr, const void* cuSeqlenPtr, void* output, void* workspace, cudaStream_t stream)
    {
        float scaleQkv = interface->mScaleQkv;
        float scaleCtx = interface->mScaleCtx;
        float dqProbs = interface->mDqProbs;

        float scaleBmm1 = scaleQkv * scaleQkv * interface->mRsqrtHeadSize;
        float scaleBmm2 = dqProbs * scaleQkv / scaleCtx;
        float scaleSoftmax = 1.f / dqProbs;

        params.scale_bmm1 = reinterpret_cast<const uint32_t&>(scaleBmm1);
        params.scale_bmm2 = reinterpret_cast<const uint32_t&>(scaleBmm2);
        params.scale_softmax = reinterpret_cast<const uint32_t&>(scaleSoftmax);

        params.enable_i2f_trick
            = -double(1 << 22) * double(scaleBmm2) <= -128.f && double(1 << 22) * double(scaleBmm2) >= 127.f;

        params.qkv_ptr = const_cast<void*>(qkvPtr);

        // dummy input in V2/V3 because now we use cu_seqlens
        params.packed_mask_ptr = nullptr;

        params.use_int8_scale_max = true;

        params.o_ptr = output;

        params.cu_seqlens = static_cast<int*>(const_cast<void*>(cuSeqlenPtr));

        xmmaKernel->run(params, stream);
        CUDA_CALL_THROW(cudaPeekAtLastError());
    }

    bool isValid(int s) const
    {
        return xmmaKernel->isValid(s);
    }

private:
    float mDqProbs;
    FusedMHARunnerInt8v2* interface;
    Fused_multihead_attention_params_v2 params;
    int sm;
    const FusedMultiHeadAttentionXMMAKernelV2* xmmaKernel;
    size_t xmmas_m;
    size_t xmmas_n;
    size_t threads_per_cta;
};

FusedMHARunnerInt8v2::FusedMHARunnerInt8v2(const int numHeads, const int headSize, const int sm)
    : MHARunner(numHeads, headSize, 1)
    , mSm(sm)
    , pimpl(new mhaImpl(this))
{
}

void FusedMHARunnerInt8v2::setScaleList(const float scaleQkv, const float scaleCtx, const float dqProbs)
{
    mScaleQkv = scaleQkv;
    mScaleCtx = scaleCtx;
    mDqProbs = dqProbs;
}

void FusedMHARunnerInt8v2::setup(const int S, const int B)
{
    MHARunner::setup(S, B);
    pimpl->setup(S, B);
}

size_t FusedMHARunnerInt8v2::getWorkspaceSize() const
{
    return 0;
}

bool FusedMHARunnerInt8v2::isValid(int s) const
{
    return pimpl->isValid(s);
}

}  // namespace cuda
}  // namespace contrib
}  // namespace onnxruntime
