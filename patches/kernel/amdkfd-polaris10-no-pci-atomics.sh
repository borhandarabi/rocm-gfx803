#!/bin/sh
# Apply amdkfd-polaris10-no-pci-atomics.patch (see that file for the full
# WHY/WHAT) to a kernel source tree, then verify the hunk actually landed.
# `patch -p1` rather than `git apply`: a distro kernel source package or a
# release tarball is not a git checkout, and `git apply` outside a repo would
# skip the hunk without failing.
set -eu

SRC="${1:?usage: $0 <kernel-source-root>}"
SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PATCH="$SELF_DIR/amdkfd-polaris10-no-pci-atomics.patch"
FILE="$SRC/drivers/gpu/drm/amd/amdkfd/kfd_device.c"

[ -f "$PATCH" ] || { echo "FATAL: no patch file at $PATCH" >&2; exit 1; }
[ -f "$FILE" ] || { echo "FATAL: $FILE not found; $SRC is not a kernel source root" >&2; exit 1; }

if patch -p1 -d "$SRC" --dry-run -R -s < "$PATCH" >/dev/null 2>&1; then
    echo "already patched, skipping"
    exit 0
fi

patch -p1 -d "$SRC" < "$PATCH"

# The exemption has to sit in the GFX7/8 branch of kfd_device_info_init(),
# ahead of the assignment it guards. A hunk that landed elsewhere would
# compile and change nothing.
if ! grep -q "asic_type != CHIP_POLARIS10" "$FILE"; then
    echo "FATAL: Polaris10 exemption not found in $FILE after patch reported success" >&2
    exit 1
fi
if ! grep -A3 "asic_type != CHIP_POLARIS10" "$FILE" | grep -q "needs_pci_atomics = true"; then
    echo "FATAL: Polaris10 exemption in $FILE does not guard needs_pci_atomics" >&2
    exit 1
fi
echo "amdkfd-polaris10-no-pci-atomics patch applied and verified in $FILE"
