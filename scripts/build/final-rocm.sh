#!/bin/sh
# Put the last gfx803 pieces into /opt/rocm and prove that all of them landed.
#
# Every component reaches this image as a prebuilt image, so a stale or wrongly
# wired one is the failure mode this guards against. Each check below names the
# input that is wrong when it fires.
set -eu

# A component image from another ROCm line assembles, imports, and misbehaves
# only on real hardware, so fail at the first layer that inherits a whole tree.
if [ ! -d /opt/rocm/core-10.0 ]; then
    echo "FATAL: the inherited /opt/rocm has no core-10.0 (found: $(ls -d /opt/rocm/core-* 2>/dev/null | tr '\n' ' '))." >&2
    echo "       A component image from a different ROCm line is wired into this build." >&2
    exit 1
fi

# The three HIP runtime libraries must be our own rocr-clr build, but the base
# image and every published chain image can still carry a stock twin under the
# same SONAME. The base ships "-0000000", and our build ships "-<commit>" under
# CI and "-0000000" locally, so a filename pattern cannot tell them apart and one
# that assumes it can deletes the wrong file. Install from the rocr-clr image's
# own lib directory instead, which holds exactly one real file per family.
for n in libamdhip64 libhiprtc libhiprtc-builtins; do
    ours="$(find /opt/rocm-clr-lib -maxdepth 1 -name "${n}.so.7.*" -type f | head -1)"
    if [ -z "$ours" ]; then
        echo "FATAL: $n is missing from the rocr-clr image." >&2
        exit 1
    fi
    rm -f "/opt/rocm/lib/${n}.so" "/opt/rocm/lib/${n}.so.7" "/opt/rocm/lib/${n}".so.7.*
    cp -a "$ours" "/opt/rocm/lib/$(basename "$ours")"
    ln -sf "$(basename "$ours")" "/opt/rocm/lib/${n}.so.7"
    ln -s "${n}.so.7" "/opt/rocm/lib/${n}.so"
done
rm -rf /opt/rocm-clr-lib
echo "/opt/rocm/lib" > /etc/ld.so.conf.d/rocm.conf
ldconfig

if ! strings "$(readlink -f /opt/rocm/lib/libamdhip64.so)" 2>/dev/null | grep -q "Image extension queries failed"; then
    echo "FATAL: the active libamdhip64.so does not carry the gfx8 opencl patch marker." >&2
    echo "       The rocr-clr image wired into this build does not carry the gfx803 fix." >&2
    exit 1
fi

# MIOpen has no .hip_fatbin to size-check: its kernels are compiled on demand and
# served through its own kernel database, and Composable Kernel, which would add
# precompiled binaries, is off. Compare against the untouched base image instead.
# A before-and-after comparison around the copy does not work, because the
# migraphx image already carries the same fixed file forward.
resolved="$(readlink -f /opt/rocm/lib/libMIOpen.so)"
stock_ref="$(find /tmp/miopen-stock-ref -maxdepth 1 -name 'libMIOpen.so.*' -type f | sort -V | tail -1)"
if [ -z "$resolved" ] || [ ! -f "$resolved" ] || [ -z "$stock_ref" ]; then
    echo "FATAL: could not resolve libMIOpen.so ('$resolved') or the stock reference ('$stock_ref')." >&2
    exit 1
fi
new_size="$(stat -c%s "$resolved")"
stock_size="$(stat -c%s "$stock_ref")"
rm -rf /tmp/miopen-stock-ref
if [ "$new_size" = "$stock_size" ]; then
    echo "FATAL: $resolved is the same size ($new_size bytes) as the untouched base image's MIOpen." >&2
    echo "       The miopen image wired into this build does not carry the gfx803 fix." >&2
    exit 1
fi
echo "OK: MIOpen at $resolved ($new_size bytes) differs from the stock $stock_size bytes."

resolved="$(readlink -f /opt/rocm/lib/librocsolver.so)"
if [ -z "$resolved" ] || [ ! -f "$resolved" ]; then
    echo "FATAL: /opt/rocm/lib/librocsolver.so does not resolve to a real file." >&2
    exit 1
fi
objcopy -O binary --only-section=.hip_fatbin "$resolved" /tmp/rocsolver_fatbin.bin
fatbin_size="$(stat -c%s /tmp/rocsolver_fatbin.bin)"
rm -f /tmp/rocsolver_fatbin.bin
if [ "$fatbin_size" -lt 100000 ]; then
    echo "FATAL: $resolved's .hip_fatbin is only $fatbin_size bytes, too small to hold real gfx803 device code." >&2
    echo "       The rocsolver image wired into this build does not carry the gfx803 fix." >&2
    exit 1
fi
echo "OK: rocSOLVER at $resolved has a ${fatbin_size}-byte .hip_fatbin."

if ! strings /opt/rocm/lib/libgfx803_sgemm_shim.so | grep -q "f16-map-nm"; then
    echo "FATAL: the installed SGEMM shim does not carry the fp16 operand-mapping fix." >&2
    exit 1
fi
echo "OK: the SGEMM shim carries the fp16 mapping fix."

# hipSPARSELt: carried forward untouched from the base image (this repo never
# builds it), and it targets MI-series structured sparsity, a feature gfx803
# does not have -- so it is pure dead weight on this card, never functionally
# useful. AMD's prebuilt copy is compiled with unconditional AVX2 host-side
# code and no CPU_CAPABILITY-style runtime fallback, unlike PyTorch's own CPU
# kernels, so any process that dlopens it on a host whose CPU lacks AVX2
# receives an unrecoverable SIGILL trap deep inside the library instead of a
# clean "unsupported" error (see the reported crash: `trap invalid opcode ...
# in libhipsparselt.so`). scripts/build/pytorch.sh already builds PyTorch with
# USE_HIPSPARSELT=0, which stops PyTorch itself from linking or probing it, but
# the base image's copy is still on disk and any other component (or a future
# torch rebuild without that flag) can still dlopen it. Removing the files here
# is what actually makes that impossible: a caller that hard-requires the
# library now gets a clean, immediate "cannot open shared object file" instead
# of a trap that can appear mid-run, and every caller here already treats
# hipSPARSELt as optional.
hipsparselt_removed=0
for f in /opt/rocm/lib/libhipsparselt* /opt/rocm/core-*/lib/libhipsparselt*; do
    [ -e "$f" ] || continue
    rm -f "$f"
    hipsparselt_removed=1
done
if [ "$hipsparselt_removed" = "1" ]; then
    echo "OK: removed the base image's AVX2-only libhipsparselt (unused on gfx803, no CPU fallback)."
else
    echo "OK: no libhipsparselt present to remove (already absent from this base image)."
fi
