#!/bin/sh
# Build the PyTorch wheel for one architecture and install it.
set -eu

ARCH="${ROCM_ARCH:?ROCM_ARCH is required}"
TOPK_OPT="${TENSOR_TOPK_OPT_LEVEL:--O3}"
. /scripts/lib/build-jobs.sh

# TensorTopK.hip at -O3 has been measured taking 40GB of combined RSS and swap
# and several hours, on a 4-vCPU CI runner and on a 24-core workstation alike.
# A lower level for that one file clears it in under a minute and leaves every
# other kernel's codegen alone. PyTorch's build system has no per-file flag
# override, so wrap the compiler binary it invokes by absolute path. This is a
# build-environment change, not a patch on PyTorch's source.
real=/opt/rocm/lib/llvm/bin/clang++.real
mv /opt/rocm/lib/llvm/bin/clang++ "$real"
cat > /opt/rocm/lib/llvm/bin/clang++ <<EOF
#!/bin/sh
case "\$*" in
  *TensorTopK.hip*) exec $real "\$@" $TOPK_OPT ;;
  *) exec $real "\$@" ;;
esac
EOF
chmod +x /opt/rocm/lib/llvm/bin/clang++

jobs="$(resolve_build_jobs)"
echo "PyTorch build: arch $ARCH, $jobs parallel jobs, TensorTopK at $TOPK_OPT"
cd /pytorch
ulimit -s unlimited

# `python3 -m build`, not `setup.py bdist_wheel`: torch 2.14 moved to
# scikit-build-core and PEP 517, and every setup.py command except install and
# develop now fails outright. The replacement reads the same environment
# variables.
# USE_HIPSPARSELT=0: hipSPARSELt targets MI-series structured sparsity, a
# feature gfx803 does not have, so torch has no use for it on this card either
# way. More importantly, AMD's prebuilt libhipsparselt in the base image is
# compiled with unconditional AVX2 host-side code and no CPU_CAPABILITY-style
# runtime fallback (unlike torch's own CPU kernels), so linking against it lets
# a no-AVX2 host crash with a SIGILL trap deep inside the library instead of
# torch simply reporting the feature unsupported. Without this flag, torch's
# ROCm CMake auto-detects and links it whenever ROCM_HOME has a copy.
# USE_XNNPACK=0: same category of risk -- XNNPACK's own build sometimes bakes
# in a fixed minimum x86 ISA (AVX/AVX2 kernels selected without cpuinfo
# fallback in some releases) rather than torch's own scalar/DEFAULT dispatch.
# Nothing here needs XNNPACK's mobile/edge kernels, so turning it off removes
# a second AVX-only failure mode for zero functional loss on this GPU build.
env USE_ROCM=1 USE_CUDA=0 ROCM_HOME=/opt/rocm \
    "PYTORCH_ROCM_ARCH=$ARCH" \
    MAX_JOBS="$jobs" USE_MKLDNN=0 USE_CCACHE=1 USE_NINJA=1 \
    USE_FLASH_ATTENTION=0 USE_MEM_EFF_ATTENTION=0 \
    USE_DISTRIBUTED=1 USE_ROCM_CK_GEMM=0 \
    USE_HIPSPARSELT=0 USE_XNNPACK=0 \
    BUILD_TEST=0 \
    python3 -m build --wheel --no-isolation

pip install --no-cache-dir dist/torch*.whl
mkdir -p /wheels
cp dist/torch*.whl /wheels/
