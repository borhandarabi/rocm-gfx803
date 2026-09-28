#!/usr/bin/env bash
# Apply gfx101-fmac-uniform.patch to a composable_kernel checkout
# (PyTorch's third_party/composable_kernel submodule).
#
# Usage:
#   ./gfx101-fmac-uniform.sh /path/to/pytorch/third_party/composable_kernel
#
# Verifies its own result: greps the patched file for the marker comment
# and fails loudly if missing.

set -euo pipefail

SRC="${1:-}"
PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$PATCH_DIR/gfx101-fmac-uniform.patch"
TARGET="$SRC/include/ck/ck.hpp"
MARKER='RDNA1 (gfx1010/1011/1012/1013): v_fmac_f32'

if [[ -z "$SRC" || ! -d "$SRC" ]]; then
    echo "usage: $0 /path/to/pytorch/third_party/composable_kernel" >&2
    exit 1
fi

if [[ ! -f "$TARGET" ]]; then
    echo "FATAL: $TARGET not found" >&2
    exit 1
fi

if grep -q "$MARKER" "$TARGET"; then
    echo "already patched in $TARGET, skipping"
    exit 0
fi

patch -p1 -d "$SRC" --batch < "$PATCH"

if ! grep -q "$MARKER" "$TARGET"; then
    echo "FATAL: marker not found after patch reported success" >&2
    exit 1
fi

echo "gfx101-fmac-uniform.patch applied and verified in $TARGET"
