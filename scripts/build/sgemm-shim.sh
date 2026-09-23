#!/bin/sh
# Build the LD_PRELOAD SGEMM shim.
#
# rocBLAS and Tensile's own SGEMM kernels are wrong on gfx803 for every shape
# tested, so this shim answers standard-algo f32 rocblas_sgemm and
# rocblas_gemm_ex with a kernel that was verified on the card. It also takes over
# fp16 gemm_ex and the small-problem rocblas_gemm_strided_batched_ex that
# MIGraphX's batched attention dots land in. The final image sets LD_PRELOAD.
#
# This is always compiled for gfx803 only, never for $ROCM_ARCH as a whole:
#
# - gfx803_gemm_lib.hip and gfx803_sgemm.h are hand-written for GCN3
#   specifically (see sgemm_shim.cpp's NOTE 2: the bug this shim works around
#   is gfx803's GSU-reduction kernels doing a software compare-and-swap
#   because "Polaris/GCN3 has no native float atomic-add" -- gfx1010/RDNA1
#   does have one, so there is no reason to believe its SGEMM kernels share
#   this bug, and no evidence they do).
# - passing a semicolon-joined "gfx803;gfx1010" as a single --offload-arch
#   value is not valid clang syntax in the first place -- the unquoted
#   semicolon gets parsed as a shell command separator, which is the
#   "sh: 1: gfx1010: not found" half of the error this fixes. hipcc/clang
#   embed multiple targets via repeated --offload-arch flags, not a
#   delimited list in one.
# - every rocblas_* entry point below launches its custom kernel and only
#   commits to the result after checking hipGetLastError(), falling back to
#   the real rocBLAS symbol (via dlsym(RTLD_NEXT, ...)) on any launch
#   failure. A gfx803-only .so launched against a gfx1010 device has no
#   matching code object, so that launch fails immediately and every call
#   this shim intercepts transparently falls through to rocBLAS's own
#   gfx1010 kernels -- this is what actually makes it safe to LD_PRELOAD
#   unconditionally (docker/final.Dockerfile does, for every ROCM_ARCH
#   combination) on a system with a gfx1010 card, or a gfx803+gfx1010 pair.
#   This has not been verified on real gfx1010 hardware -- confirm the
#   "falling back to rocBLAS" message actually appears (and results are
#   still correct) on the RX 5700 XT before trusting it in production.
set -eu

SHIM=/opt/rocm/lib/libgfx803_sgemm_shim.so

hipcc -O2 -fPIC -shared --offload-arch=gfx803 -I/opt/rocm/include \
    /patches/rocblas/sgemm-shim/sgemm_shim.cpp \
    /patches/rocblas/sgemm-shim/gfx803_gemm_lib.hip \
    -o "$SHIM" \
    -L/opt/rocm/lib -Wl,-rpath,/opt/rocm/lib -lrocblas -ldl

# Each marker is a string the corresponding source fix adds. An old source tree
# links and loads fine, so only the marker tells the versions apart.
if ! strings "$SHIM" | grep -q "sb-takeover-no-algo-gate"; then
    echo "FATAL: shim built without the strided-batched takeover fix (algo gate)." >&2
    exit 1
fi
if ! strings "$SHIM" | grep -q "f16-takeover"; then
    echo "FATAL: shim built without the fp16 takeover." >&2
    exit 1
fi
if ! strings "$SHIM" | grep -q "f16-map-nm"; then
    echo "FATAL: shim built with the old fp16 operand mapping. It hands the kernel" >&2
    echo "       (m, n) where the column-major contract needs (n, m), which" >&2
    echo "       transposes the answer and reads past both operands when m != n." >&2
    exit 1
fi
echo "OK: SGEMM shim built for gfx803 with all three fixes."
