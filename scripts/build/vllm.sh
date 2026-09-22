#!/bin/sh
# Build the gfx803 vLLM wheel and the three hand-written gfx803 HIP kernels.
#
# Produces /wheels/*.whl (the vllm package and its C++/HIP extension) and
# /kernels/<relative path under site-packages/vllm>/*.so (the three kernels),
# kept in the same directory shape their Python ctypes loaders expect, so
# final.Dockerfile can copy each one straight onto the installed vllm package
# with no per-file name mapping to keep in sync. See vllm/BUILD.md for what
# each kernel does and the exact hipcc command this mirrors.
set -eu

ROCM_ARCH="${ROCM_ARCH:?ROCM_ARCH is required}"
. /scripts/lib/build-jobs.sh

cd /vllm-src

jobs="$(resolve_build_jobs)"
echo "vLLM build: arch $ROCM_ARCH, $jobs parallel jobs"

# VLLM_VERSION_OVERRIDE: this vendored tree carries no .git of its own (this
# repo tracks the fork directly), so setuptools-scm has no
# tag or commit history to derive a version from and fails outright. The
# value names the upstream release the port sits on, so the built wheel says
# which vLLM line it is. Bump it whenever vllm/ is re-based onto a new
# upstream release.
env "MAX_JOBS=$jobs" "PYTORCH_ROCM_ARCH=$ROCM_ARCH" "VLLM_VERSION_OVERRIDE=0.29.0+gfx803" \
    pip wheel --no-build-isolation --no-deps --no-cache-dir -w /wheels .

# These three kernels are hand-written for gfx803/GCN3 specifically: they
# hardcode WARP_SIZE=64 (see gfx803_attn_split.hip) and are tuned around
# GCN3's register-spill behaviour (see gfx803_gemm_lib.hip's header). RDNA
# (gfx10+, wave32-native) is a different execution model, so these must never
# be compiled with --offload-arch set to a non-gfx803 target -- always target
# gfx803 explicitly here, never "$ROCM_ARCH" as a whole, and skip the step
# entirely when this build doesn't include gfx803 at all. At runtime,
# vllm/model_executor/layers/utils.py additionally gates every call site
# behind on_gfx803(), so even a multi-arch image only ever dispatches to
# these kernels on real gfx803 hardware -- this build-time gate exists so a
# gfx1010-only (or other non-gfx803) build doesn't waste time compiling, or
# risk miscompiling, .so files nothing will load.
case "$ROCM_ARCH" in
    *gfx803*)
        hipcc="/opt/rocm/bin/hipcc"
        kernels="/vllm-src/vllm/gfx803_kernels"

        mkdir -p /kernels/model_executor/layers /kernels/v1/attention/ops

        "$hipcc" --offload-arch=gfx803 -O3 -shared -fPIC \
            -o /kernels/model_executor/layers/libgfx803gemm.so \
            "$kernels/gfx803_gemm_lib.hip"

        "$hipcc" --offload-arch=gfx803 -O3 -shared -fPIC \
            -o /kernels/model_executor/layers/libgfx803gemv_m.so \
            "$kernels/gfx803_gemv_m.hip"

        "$hipcc" --offload-arch=gfx803 -O3 -shared -fPIC \
            -o /kernels/v1/attention/ops/libgfx803attn.so \
            "$kernels/gfx803_attn_split.hip"
        ;;
    *)
        echo "gfx803 not in ROCM_ARCH ($ROCM_ARCH) -- skipping the three hand-written gfx803 kernels"
        mkdir -p /kernels/model_executor/layers /kernels/v1/attention/ops
        ;;
esac
