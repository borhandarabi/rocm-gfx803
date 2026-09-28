#!/usr/bin/env bash
# Apply gfx1010-unique-hipcub-scan.patch to a PyTorch checkout.
#
# Usage:
#   ./gfx1010-unique-hipcub-scan.sh /path/to/pytorch
#
# Verifies its own result: greps the patched file for compute_unique_gfx1010 and
# fails loudly if missing.

set -euo pipefail

SRC="${1:-}"
PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$PATCH_DIR/gfx1010-unique-hipcub-scan.patch"
TARGET="$SRC/aten/src/ATen/native/cuda/UniqueCub.cu"

if [[ -z "$SRC" || ! -d "$SRC" ]]; then
    echo "usage: $0 /path/to/pytorch" >&2
    exit 1
fi

if [[ ! -f "$TARGET" ]]; then
    echo "FATAL: $TARGET not found" >&2
    exit 1
fi

if grep -q 'compute_unique_gfx1010' "$TARGET"; then
    echo "already patched in $TARGET, skipping"
    exit 0
fi

patch -p1 -d "$SRC" --batch < "$PATCH"

if ! grep -q 'compute_unique_gfx1010' "$TARGET"; then
    echo "FATAL: compute_unique_gfx1010 marker not found after patch reported success" >&2
    exit 1
fi

echo "gfx1010-unique-hipcub-scan.patch applied and verified in $TARGET"
