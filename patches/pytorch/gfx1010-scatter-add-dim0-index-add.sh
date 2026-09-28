#!/usr/bin/env bash
# Apply gfx1010-scatter-add-dim0-index-add.patch to a PyTorch checkout.
#
# Usage:
#   ./gfx1010-scatter-add-dim0-index-add.sh /path/to/pytorch
#
# Verifies its own result: greps the patched file for is_gfx1010_scatter_add_device and
# fails loudly if missing.

set -euo pipefail

SRC="${1:-}"
PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$PATCH_DIR/gfx1010-scatter-add-dim0-index-add.patch"
TARGET="$SRC/aten/src/ATen/native/cuda/ScatterGatherKernel.cu"

if [[ -z "$SRC" || ! -d "$SRC" ]]; then
    echo "usage: $0 /path/to/pytorch" >&2
    exit 1
fi

if [[ ! -f "$TARGET" ]]; then
    echo "FATAL: $TARGET not found" >&2
    exit 1
fi

if grep -q 'is_gfx1010_scatter_add_device' "$TARGET"; then
    echo "already patched in $TARGET, skipping"
    exit 0
fi

patch -p1 -d "$SRC" --batch < "$PATCH"

if ! grep -q 'is_gfx1010_scatter_add_device' "$TARGET"; then
    echo "FATAL: is_gfx1010_scatter_add_device marker not found after patch reported success" >&2
    exit 1
fi

echo "gfx1010-scatter-add-dim0-index-add.patch applied and verified in $TARGET"
