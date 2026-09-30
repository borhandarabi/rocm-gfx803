#!/usr/bin/env bash
# Build and install an amdgpu.ko whose amdkfd registers a Polaris10 card
# (RX 470/480/570/580) sitting on a PCIe link without AtomicOps. The reasoning
# and the diff are in patches/kernel/amdkfd-polaris10-no-pci-atomics.patch. It
# has to be done on the host: a container shares the host's kernel, so nothing
# in the Docker image can change what amdkfd does at probe time.
#
# Runs straight from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/borhandarabi/rocm-gfx803/main/tools/host-setup/host-amdgpu-kfd-polaris10.sh | sudo bash
# Options follow `bash -s --`:
#   ... | sudo bash -s -- --build-only
#
# Ubuntu/Debian only. The kernel source comes from apt and must be the exact
# source package the running kernel was built from: the module is linked
# against the running kernel's symbol CRCs, and a source tree that differs
# from it can build a module that loads and misbehaves.
#
# Usage: host-amdgpu-kfd-polaris10.sh [options]
#   --build-only        build and verify, install nothing
#   --uninstall         remove the installed module and rebuild the initramfs
#   --source-dir DIR    use an already unpacked kernel source tree
#   --patch-only        apply the patch to --source-dir and stop
#   --sign-key FILE     module signing key (PEM), for Secure Boot hosts
#   --sign-cert FILE    matching certificate (DER)
#   --allow-source-mismatch
#                       accept a source package whose version differs from the
#                       running kernel's
#   --no-initramfs      skip update-initramfs
#   --workdir DIR       scratch directory (default /var/tmp/gfx803-amdgpu)
#   --jobs N            parallel make jobs (default: nproc)
# Environment: GFX803_REF (git ref of this repo, default main),
#              GFX803_RAW_BASE (override the raw file base URL).
set -euo pipefail

PATCH_NAME="amdkfd-polaris10-no-pci-atomics"
RAW_BASE="${GFX803_RAW_BASE:-https://raw.githubusercontent.com/borhandarabi/rocm-gfx803/${GFX803_REF:-main}}"
KVER="$(uname -r)"
WORK="${GFX803_WORKDIR:-/var/tmp/gfx803-amdgpu}"
JOBS="$(nproc)"
BUILD_ONLY=0
UNINSTALL=0
PATCH_ONLY=0
SRC_DIR=""
SIGN_KEY=""
SIGN_CERT=""
ALLOW_MISMATCH=0
DO_INITRAMFS=1
DEB_SRC_LIST=""

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    [ -n "$DEB_SRC_LIST" ] && rm -f "$DEB_SRC_LIST"
    return 0
}
trap cleanup EXIT

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --build-only) BUILD_ONLY=1 ;;
            --uninstall) UNINSTALL=1 ;;
            --patch-only) PATCH_ONLY=1 ;;
            --source-dir) SRC_DIR="${2:?--source-dir needs a directory}"; shift ;;
            --sign-key) SIGN_KEY="${2:?--sign-key needs a file}"; shift ;;
            --sign-cert) SIGN_CERT="${2:?--sign-cert needs a file}"; shift ;;
            --allow-source-mismatch) ALLOW_MISMATCH=1 ;;
            --no-initramfs) DO_INITRAMFS=0 ;;
            --workdir) WORK="${2:?--workdir needs a directory}"; shift ;;
            --jobs) JOBS="${2:?--jobs needs a number}"; shift ;;
            -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done
    if [ "$PATCH_ONLY" = 1 ] && [ -z "$SRC_DIR" ]; then
        die "--patch-only needs --source-dir"
    fi
}

require_host() {
    [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
    [ "$(uname -m)" = "x86_64" ] || die "x86_64 only"
    command -v apt-get >/dev/null || die "this script needs an apt-based host (Ubuntu/Debian)"
}

install_deps() {
    log "Installing build dependencies"
    local pkgs="build-essential bc bison flex libelf-dev libssl-dev libncurses-dev dwarves rsync kmod cpio zstd xz-utils patch curl ca-certificates dpkg-dev initramfs-tools"
    if [ "$PATCH_ONLY" = 0 ]; then
        pkgs="$pkgs linux-headers-${KVER}"
    fi
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $pkgs </dev/null
}

# The .sh driver is the one place that applies the patch and proves the hunk
# landed, so it is fetched together with the patch instead of duplicated here.
fetch_patch() {
    local dest="$WORK/patch" local_dir="" f
    mkdir -p "$dest"
    if [ -f "${BASH_SOURCE[0]:-}" ]; then
        local_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../../patches/kernel"
    fi
    for f in "$PATCH_NAME.patch" "$PATCH_NAME.sh"; do
        if [ -n "$local_dir" ] && [ -f "$local_dir/$f" ]; then
            cp "$local_dir/$f" "$dest/$f"
        else
            log "Downloading $f"
            curl -fsSL "$RAW_BASE/patches/kernel/$f" -o "$dest/$f" \
                || die "could not download $RAW_BASE/patches/kernel/$f (is the patch pushed to that ref?)"
        fi
    done
    head -1 "$dest/$PATCH_NAME.patch" | grep -q "HOST KERNEL PATCH" \
        || die "$dest/$PATCH_NAME.patch is not the expected patch file"
}

# Ubuntu ships its kernel source as the `linux` source package, at the same
# version as linux-modules-<abi>-<flavour>. Only the exact version is accepted.
running_source_version() {
    dpkg-query -W -f='${Version}' "linux-modules-${KVER}" 2>/dev/null \
        || dpkg-query -W -f='${Version}' "linux-image-${KVER}" 2>/dev/null \
        || dpkg-query -W -f='${Version}' "linux-image-unsigned-${KVER}" 2>/dev/null \
        || true
}

enable_deb_src() {
    if apt-cache showsrc linux 2>/dev/null | grep -q '^Version:'; then
        return 0
    fi

    local list

    for list in \
        /etc/apt/sources.list.d/ubuntu.sources \
        /etc/apt/sources.list.d/debian.sources
    do
        [ -f "$list" ] || continue

        DEB_SRC_LIST="$WORK/gfx803-deb-src.sources"

        sed 's/^Types:.*/Types: deb-src/' "$list" > "$DEB_SRC_LIST"

        log "Updating only the kernel deb-src indexes"

        apt-get update \
            -o Dir::Etc::sourcelist="$DEB_SRC_LIST" \
            -o Dir::Etc::sourceparts="-" \
            -o APT::Get::List-Cleanup="0" \
            </dev/null

        return 0
    done

    die "no deb-src apt source available; unpack the matching kernel source yourself and pass --source-dir"
}

fetch_source() {
    if [ -n "$SRC_DIR" ]; then
        [ -f "$SRC_DIR/drivers/gpu/drm/amd/amdkfd/kfd_device.c" ] || die "$SRC_DIR is not a kernel source root"
        return 0
    fi
    local want have out
    want="$(running_source_version)"
    [ -n "$want" ] || die "cannot tell which source version kernel $KVER was built from; pass --source-dir"
    enable_deb_src
    mkdir -p "$WORK/src"
    cd "$WORK/src"
    log "Fetching kernel source package linux=$want (about 250 MB download)"
    if ! apt-get source "linux=$want" </dev/null; then
        if [ "$ALLOW_MISMATCH" = 1 ]; then
            warn "linux=$want is no longer in the archive; using the newest source"
            apt-get source linux </dev/null
        else
            die "linux=$want is not available from the archive. Pass --source-dir with the exact source, or --allow-source-mismatch to accept the newest one"
        fi
    fi
    out="$(find "$WORK/src" -maxdepth 1 -mindepth 1 -type d -name 'linux*' | head -1)"
    [ -n "$out" ] || die "apt-get source produced no source directory"
    SRC_DIR="$out"
    have="$(dpkg-parsechangelog -l "$SRC_DIR/debian.master/changelog" -S Version 2>/dev/null || true)"
    if [ -n "$have" ] && [ "$have" != "$want" ] && [ "$ALLOW_MISMATCH" = 0 ]; then
        die "unpacked source is $have but the running kernel is $want"
    fi
}

apply_patch() {
    log "Applying $PATCH_NAME to $SRC_DIR"
    sh "$WORK/patch/$PATCH_NAME.sh" "$SRC_DIR"
}

# vermagic and symbol CRCs must equal the running kernel's, so the tree is
# configured from the running kernel's own config and Module.symvers, and
# KERNELRELEASE is forced to `uname -r` (the packaging derives it outside the
# source tree). BTF and module signing are switched off: they add nothing to
# a module built for this one machine, and their inputs (vmlinux, the
# distribution signing certificates) are not in a source-only tree.
configure_tree() {
    local headers="/usr/src/linux-headers-${KVER}"
    [ -f "/boot/config-${KVER}" ] || die "/boot/config-${KVER} not found"
    [ -f "$headers/Module.symvers" ] || die "$headers/Module.symvers not found (install linux-headers-${KVER})"
    cd "$SRC_DIR"
    cp "/boot/config-${KVER}" .config
    cp "$headers/Module.symvers" Module.symvers
    scripts/config --file .config \
        -d DEBUG_INFO_BTF -d DEBUG_INFO_BTF_MODULES \
        -d MODULE_SIG_ALL -d MODULE_SIG_FORCE \
        --set-str SYSTEM_TRUSTED_KEYS "" \
        --set-str SYSTEM_REVOCATION_KEYS ""
    make KERNELRELEASE="$KVER" olddefconfig >"$WORK/olddefconfig.log" 2>&1 \
        || { tail -20 "$WORK/olddefconfig.log" >&2; die "make olddefconfig failed"; }
    grep -q '^CONFIG_DRM_AMDGPU=m' .config || die "the running kernel does not build amdgpu as a module"
    grep -q '^CONFIG_HSA_AMD=y' .config || die "the running kernel is built without CONFIG_HSA_AMD"
}

build_module() {
    log "Preparing the tree (modules_prepare)"
    make KERNELRELEASE="$KVER" -j"$JOBS" modules_prepare >"$WORK/prepare.log" 2>&1 \
        || { tail -30 "$WORK/prepare.log" >&2; die "modules_prepare failed, full log: $WORK/prepare.log"; }
    log "Building amdgpu.ko (this takes a while)"
    make KERNELRELEASE="$KVER" -j"$JOBS" M=drivers/gpu/drm/amd/amdgpu modules >"$WORK/build.log" 2>&1 \
        || { tail -40 "$WORK/build.log" >&2; die "module build failed, full log: $WORK/build.log"; }
}

verify_module() {
    local ko="$SRC_DIR/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
    [ -f "$ko" ] || die "amdgpu.ko was not produced"
    modinfo -F vermagic "$ko" | grep -q "^${KVER} " \
        || die "vermagic '$(modinfo -F vermagic "$ko")' does not start with '$KVER'"
    strings "$ko" | grep -q "PCI rejects atomics" \
        || die "amdgpu.ko has no amdkfd atomics gate; it was built from the wrong tree"
    log "Built $ko (vermagic: $(modinfo -F vermagic "$ko"))"
}

secure_boot_enabled() {
    command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'
}

sign_module() {
    local ko="$SRC_DIR/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
    secure_boot_enabled || return 0
    if [ -z "$SIGN_KEY" ] && [ -f /var/lib/shim-signed/mok/MOK.priv ] && [ -f /var/lib/shim-signed/mok/MOK.der ]; then
        SIGN_KEY=/var/lib/shim-signed/mok/MOK.priv
        SIGN_CERT=/var/lib/shim-signed/mok/MOK.der
    fi
    if [ -z "$SIGN_KEY" ] || [ -z "$SIGN_CERT" ]; then
        [ "$BUILD_ONLY" = 1 ] && { warn "Secure Boot is on and no signing key was given; the module would not load"; return 0; }
        die "Secure Boot is enabled, so the module must be signed with an enrolled key. Pass --sign-key and --sign-cert, or use --build-only"
    fi
    mokutil --test-key "$SIGN_CERT" 2>&1 | grep -qi 'already enrolled' \
        || die "$SIGN_CERT is not enrolled in the MOK list; the firmware would reject the module"
    log "Signing amdgpu.ko"
    "/usr/src/linux-headers-${KVER}/scripts/sign-file" sha512 "$SIGN_KEY" "$SIGN_CERT" "$ko"
}

# `updates/` outranks `kernel/` in depmod's search order, which leaves the stock
# module on disk as the fallback and touches nothing the package manager owns.
install_module() {
    local ko="$SRC_DIR/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
    local dest="/lib/modules/${KVER}/updates/amdgpu.ko"
    log "Installing $dest"
    install -D -m 0644 "$ko" "$dest"
    depmod -a "$KVER"
    [ "$(modinfo -k "$KVER" -n amdgpu)" = "$dest" ] \
        || die "depmod still resolves amdgpu to $(modinfo -k "$KVER" -n amdgpu), not $dest"
    if [ "$DO_INITRAMFS" = 1 ]; then
        log "Rebuilding the initramfs"
        update-initramfs -u -k "$KVER"
    fi
}

uninstall_module() {
    local dest="/lib/modules/${KVER}/updates/amdgpu.ko"
    if [ -f "$dest" ]; then
        rm -f "$dest"
        rmdir --ignore-fail-on-non-empty "/lib/modules/${KVER}/updates" 2>/dev/null || true
        depmod -a "$KVER"
        [ "$DO_INITRAMFS" = 1 ] && update-initramfs -u -k "$KVER"
        log "Removed $dest; the stock amdgpu loads again after a reboot"
    else
        log "Nothing to remove: $dest does not exist"
    fi
}

print_next_steps() {
    cat <<EOF

Done. The running amdgpu drives the display and cannot be swapped live, so
reboot to load the new module. Afterwards:

    sudo dmesg | grep -i -E 'kfd|atomic'
    ls /sys/class/kfd/kfd/topology/nodes

A KFD node for the RX 580 (device_id 26591 in its 'properties' file) means the
gate is gone. Kernel updates install a fresh stock module under kernel/, and
the one from this script only covers ${KVER}: run the script again after each
kernel update. To go back to the stock module:

    sudo bash host-amdgpu-kfd-polaris10.sh --uninstall

The patch removes the requirement for PCIe atomics on Polaris10 without proof
that queues and signals work correctly without them. Run tools/correctness-suite
and verify.py before trusting results from this card.
EOF
}

main() {
    parse_args "$@"
    require_host
    mkdir -p "$WORK"

    if [ "$UNINSTALL" = 1 ]; then
        uninstall_module
        return 0
    fi

    install_deps
    fetch_patch
    fetch_source
    apply_patch
    [ "$PATCH_ONLY" = 1 ] && { log "Patch applied to $SRC_DIR"; return 0; }

    configure_tree
    build_module
    verify_module
    sign_module

    if [ "$BUILD_ONLY" = 1 ]; then
        log "Build only: module left at $SRC_DIR/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
        return 0
    fi
    install_module
    print_next_steps
}

main "$@"
