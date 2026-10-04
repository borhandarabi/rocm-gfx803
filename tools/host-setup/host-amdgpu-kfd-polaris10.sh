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
# The module is stripped of debug info and compressed like the stock one, so it
# stays small (tens of MB instead of hundreds) and fits in the initramfs. A
# modules-load.d entry makes amdgpu load on every boot without a manual modprobe.
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
#   --keep-workdir      keep the kernel source/build tree after installing
#   --workdir DIR       scratch directory (default /var/tmp/gfx803-amdgpu)
#   --jobs N            parallel make jobs (default: nproc)
# Environment: GFX803_REF (git ref of this repo, default main),
#              GFX803_RAW_BASE (override the raw file base URL).
set -Eeuo pipefail

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

CURRENT_STAGE="startup"

stage_start() {
    CURRENT_STAGE="$1"
    log "START: $CURRENT_STAGE"
}

stage_done() {
    log "DONE: $CURRENT_STAGE"
}

trap 'rc=$?; printf "FATAL: stage=%s exit=%s line=%s\n" "$CURRENT_STAGE" "$rc" "${BASH_LINENO[0]:-unknown}" >&2; exit "$rc"' ERR

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
KEEP_WORKDIR=0
APT_SRC_OPTS=()

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --build-only)
                BUILD_ONLY=1
                ;;
            --uninstall)
                UNINSTALL=1
                ;;
            --patch-only)
                PATCH_ONLY=1
                ;;
            --source-dir)
                SRC_DIR="${2:?--source-dir needs a directory}"
                shift
                ;;
            --sign-key)
                SIGN_KEY="${2:?--sign-key needs a file}"
                shift
                ;;
            --sign-cert)
                SIGN_CERT="${2:?--sign-cert needs a file}"
                shift
                ;;
            --allow-source-mismatch)
                ALLOW_MISMATCH=1
                ;;
            --no-initramfs)
                DO_INITRAMFS=0
                ;;
            --keep-workdir)
                KEEP_WORKDIR=1
                ;;
            --workdir)
                WORK="${2:?--workdir needs a directory}"
                shift
                ;;
            --jobs)
                JOBS="${2:?--jobs needs a number}"
                shift
                ;;
            -h|--help)
                sed -n '2,/^set -/p' "$0" |
                    sed '$d' |
                    sed 's/^# \{0,1\}//'
                exit 0
                ;;
            *)
                die "unknown option: $1"
                ;;
        esac
        shift
    done

    case "$JOBS" in
        ''|*[!0-9]*|0)
            die "--jobs must be a positive integer"
            ;;
    esac

    if [ "$PATCH_ONLY" = 1 ] && [ -z "$SRC_DIR" ]; then
        die "--patch-only needs --source-dir"
    fi
}

require_host() {
    [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
    [ "$(uname -m)" = "x86_64" ] || die "x86_64 only"
    command -v apt-get >/dev/null ||
        die "this script needs an apt-based host (Ubuntu/Debian)"
}

install_deps() {
    stage_start "install_deps"
    log "Installing build dependencies"

    local pkgs="
        build-essential
        binutils
        bc
        bison
        flex
        libelf-dev
        libdw-dev
        libssl-dev
        libncurses-dev
        dwarves
        rsync
        kmod
        cpio
        zstd
        xz-utils
        patch
        curl
        file
        ca-certificates
        dpkg-dev
        initramfs-tools
    "

    if [ "$PATCH_ONLY" = 0 ]; then
        pkgs="$pkgs linux-headers-${KVER}"
    fi

    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends $pkgs </dev/null
    log "Build dependencies are ready"
    stage_done
}

# The .sh driver is the one place that applies the patch and proves the hunk
# landed, so it is fetched together with the patch instead of duplicated here.
fetch_patch() {
    stage_start "fetch_patch"
    local dest="$WORK/patch" local_dir="" f

    mkdir -p "$dest"

    if [ -f "${BASH_SOURCE[0]:-}" ]; then
        local_dir="$(
            CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
            pwd
        )/../../patches/kernel"
    fi

    for f in "$PATCH_NAME.patch" "$PATCH_NAME.sh"; do
        if [ -n "$local_dir" ] && [ -f "$local_dir/$f" ]; then
            cp "$local_dir/$f" "$dest/$f"
        else
            log "Downloading $f"
            curl -fsSL \
                "$RAW_BASE/patches/kernel/$f" \
                -o "$dest/$f" ||
                die "could not download $RAW_BASE/patches/kernel/$f (is the patch pushed to that ref?)"
        fi
    done

    head -1 "$dest/$PATCH_NAME.patch" |
        grep -q "HOST KERNEL PATCH" ||
        die "$dest/$PATCH_NAME.patch is not the expected patch file"
    log "Patch files are ready"
    stage_done
}

# Print a dpkg-query field (source:Package or source:Version) of the package
# the running kernel came from. Ubuntu HWE kernels come from source packages
# such as linux-hwe-7.0 rather than `linux`, so the name is discovered here.
running_source_field() {
    local field="$1" pkg value
    for pkg in \
        "linux-modules-${KVER}" \
        "linux-image-${KVER}" \
        "linux-image-unsigned-${KVER}"
    do
        value="$(
            dpkg-query -W -f="\${${field}}\n" "$pkg" 2>/dev/null |
            head -1 || true
        )"
        if [ -n "$value" ]; then
            printf '%s\n' "$value"
            return 0
        fi
    done
    return 0
}

# Versions of a source package visible to the temporary deb-src indexes,
# newest first.
source_versions() {
    apt-cache "${APT_SRC_OPTS[@]}" showsrc "$1" 2>/dev/null |
        awk -v pkg="$1" '
            $1 == "Package:" { found = ($2 == pkg); next }
            found && $1 == "Version:" { print $2 }
        ' || true
}

# Compare the changelog version of an unpacked tree with the running kernel's
# source version. debian.master carries the base version without the
# "~24.04.1" style suffix that HWE packages add.
check_source_version() {
    local want have want_base
    want="$(running_source_field 'source:Version')"
    [ -n "$want" ] || return 0
    [ -f "$SRC_DIR/debian.master/changelog" ] || return 0

    have="$(
        dpkg-parsechangelog \
            -l "$SRC_DIR/debian.master/changelog" \
            -S Version 2>/dev/null || true
    )"
    [ -n "$have" ] || return 0

    want_base="${want%%~*}"

    if [ "$have" != "$want" ] && [ "$have" != "$want_base" ]; then
        if [ "$ALLOW_MISMATCH" = 0 ]; then
            die "unpacked source is $have but the running kernel is $want"
        fi
        warn "source version $have differs from running kernel package $want"
    fi
}

validate_source_dir() {
    [ -f "$SRC_DIR/drivers/gpu/drm/amd/amdkfd/kfd_device.c" ] ||
        die "$SRC_DIR is not a kernel source root"
    check_source_version
}

fetch_source() {
    stage_start "fetch_source"
    if [ -n "$SRC_DIR" ]; then
        validate_source_dir
        log "Kernel source ready: $SRC_DIR"
        stage_done
        return 0
    fi

    local want source_pkg source_ver avail src_list lists_dir list out

    want="$(running_source_field 'source:Version')"
    [ -n "$want" ] ||
        die "cannot tell which source version kernel $KVER was built from; pass --source-dir"

    source_pkg="$(running_source_field 'source:Package')"
    [ -n "$source_pkg" ] ||
        die "cannot determine the source package for kernel $KVER; pass --source-dir"

    src_list="$WORK/gfx803-deb-src.sources"
    lists_dir="$WORK/apt-lists"
    rm -f "$src_list"
    mkdir -p "$lists_dir/partial"

    for list in \
        /etc/apt/sources.list.d/ubuntu.sources \
        /etc/apt/sources.list.d/debian.sources \
        /etc/apt/sources.list
    do
        [ -f "$list" ] || continue

        case "$list" in
            *.sources)
                sed 's/^Types:.*/Types: deb-src/' "$list" > "$src_list"
                ;;
            *)
                sed -e '/^[[:space:]]*deb[[:space:]]/s/^[[:space:]]*deb[[:space:]]/deb-src /' \
                    "$list" > "$src_list"
                ;;
        esac

        break
    done

    [ -s "$src_list" ] ||
        die "no apt source configuration available for deb-src"

    # Only the kernel deb-src indexes are fetched, into a private lists dir;
    # the system's apt configuration is left untouched.
    APT_SRC_OPTS=(
        -o "Dir::Etc::sourcelist=$src_list"
        -o "Dir::Etc::sourceparts=-"
        -o "Dir::State::lists=$lists_dir"
    )

    log "Updating only the kernel deb-src indexes"
    apt-get "${APT_SRC_OPTS[@]}" -o APT::Get::List-Cleanup=0 update </dev/null ||
        die "failed to update the kernel deb-src indexes"

    avail="$(source_versions "$source_pkg")"
    [ -n "$avail" ] || die "no source versions found for $source_pkg"

    source_ver="$want"
    case $'\n'"$avail"$'\n' in
        *$'\n'"$want"$'\n'*)
            ;;
        *)
            if [ "$ALLOW_MISMATCH" = 1 ]; then
                source_ver="${avail%%$'\n'*}"
                warn "exact source version $want is not available; using $source_pkg=$source_ver because --allow-source-mismatch was specified"
            else
                die "$source_pkg=$want is not available from the configured deb-src archives; pass --source-dir or --allow-source-mismatch"
            fi
            ;;
    esac

    rm -rf "$WORK/src"
    mkdir -p "$WORK/src"
    cd "$WORK/src"

    log "Fetching kernel source package ${source_pkg}=${source_ver} (about 250 MB download)"
    apt-get "${APT_SRC_OPTS[@]}" source "${source_pkg}=${source_ver}" </dev/null ||
        die "failed to fetch ${source_pkg}=${source_ver}"

    out="$(
        find "$WORK/src" -maxdepth 1 -mindepth 1 -type d -name 'linux*' |
        head -1 || true
    )"
    [ -n "$out" ] || die "apt-get source produced no source directory"

    SRC_DIR="$out"
    check_source_version

    log "Kernel source ready: $SRC_DIR"
    stage_done
}

apply_patch() {
    stage_start "apply_patch"

    log "Applying $PATCH_NAME to $SRC_DIR"
    sh "$WORK/patch/$PATCH_NAME.sh" "$SRC_DIR"

    log "Patch application completed"
    stage_done
}

# Configure the source tree exactly like the running Ubuntu kernel.
#
# Two details are essential:
#
# 1. /boot/config-$KVER must be used unchanged. The effective kernel
#    configuration must match the running kernel when building an external
#    module whose relocations depend on the kernel's struct module layout.
#    The cleanup_module relocation is verified below against the actual
#    struct module.exit offset extracted from the running kernel's BTF.
#
# 2. Ubuntu's packaged kernel has a distro-specific KERNELRELEASE such as
#    7.0.0-34-generic even though the source Makefile is based on upstream
#    7.0.14. KERNELRELEASE must therefore be forced to uname -r.
configure_tree() {
    stage_start "configure_tree"
    local headers="/usr/src/linux-headers-${KVER}"
    local running_config="/boot/config-${KVER}"

    log "Synchronizing exact running-kernel config"

    [ -f "$running_config" ] ||
        die "missing running kernel config: $running_config"

    [ -d "$headers" ] ||
        die "missing kernel headers: $headers"

    [ -f "$headers/Module.symvers" ] ||
        die "missing Module.symvers: $headers/Module.symvers"

    cd "$SRC_DIR"

    # Start from the EXACT running kernel configuration.
    cp -f "$running_config" .config

    log "Copying Module.symvers from running kernel headers"
    cp -f "$headers/Module.symvers" Module.symvers

    # Verify the copy BEFORE any Kconfig operation.
    cmp -s .config "$running_config" ||
        die "failed to copy exact running-kernel config"

    log "Preparing kernel metadata for $KVER"

    # modules_prepare is allowed to rewrite .config, so .config is not
    # compared afterwards.
    make -C "$SRC_DIR" \
        KERNELRELEASE="$KVER" \
        modules_prepare \
        >"$WORK/modules-prepare.log" 2>&1 || {
            tail -100 "$WORK/modules-prepare.log" >&2
            die "modules_prepare failed; full log: $WORK/modules-prepare.log"
        }

    # Restore the exact running configuration AFTER modules_prepare.
    # Do NOT run modules_prepare again.
    cp -f "$running_config" .config
    cp -f "$headers/Module.symvers" Module.symvers

    grep -qx 'CONFIG_DRM_AMDGPU=m' .config ||
        die "CONFIG_DRM_AMDGPU is not =m"

    grep -qx 'CONFIG_HSA_AMD=y' .config ||
        die "CONFIG_HSA_AMD is not enabled"

    grep -qx 'CONFIG_MODULES=y' .config ||
        die "CONFIG_MODULES is not enabled"

    grep -qx 'CONFIG_MODVERSIONS=y' .config ||
        die "CONFIG_MODVERSIONS is not enabled"

    grep -qx 'CONFIG_MODULES_USE_ELF_RELA=y' .config ||
        die "CONFIG_MODULES_USE_ELF_RELA is not enabled"

    grep -qx 'CONFIG_LTO_NONE=y' .config ||
        die "CONFIG_LTO_NONE is not enabled"

    log "Kernel configuration verified"
    log "  KERNELRELEASE = $KVER"
    log "  $(grep '^CONFIG_DRM_AMDGPU=' .config)"
    log "  $(grep '^CONFIG_HSA_AMD=' .config)"
    log "  $(grep '^CONFIG_MODVERSIONS=' .config)"
    log "  $(grep '^CONFIG_LTO_NONE=' .config)"
    log "  $(grep '^CONFIG_MODULES_USE_ELF_RELA=' .config)"
    stage_done
}

build_module() {
    stage_start "build_module"

    cd "$SRC_DIR"

    log "BUILD 1/2: Cleaning previous amdgpu module build"

    make \
        KERNELRELEASE="$KVER" \
        M=drivers/gpu/drm/amd/amdgpu \
        clean \
        >"$WORK/clean.log" 2>&1 || {
            tail -30 "$WORK/clean.log" >&2
            die "amdgpu clean failed; full log: $WORK/clean.log"
        }

    log "BUILD 2/2: Building amdgpu.ko with $JOBS parallel job(s)"

    make \
        KERNELRELEASE="$KVER" \
        -j"$JOBS" \
        M=drivers/gpu/drm/amd/amdgpu \
        modules \
        >"$WORK/build.log" 2>&1 || {
            tail -50 "$WORK/build.log" >&2
            die "module build failed; full log: $WORK/build.log"
        }

    [ -f "$SRC_DIR/drivers/gpu/drm/amd/amdgpu/amdgpu.ko" ] ||
        die "make returned successfully but amdgpu.ko is missing"

    log "PASS: amdgpu.ko was produced (build log: $WORK/build.log)"
    stage_done
}

verify_module() {
    stage_start "verify_module"

    local ko="$SRC_DIR/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
    local kfd_src="$SRC_DIR/drivers/gpu/drm/amd/amdkfd/kfd_device.c"
    local vermagic generated_release relocation
    local expected_exit_offset expected_relocation

    log "VERIFY 1/8: amdgpu.ko exists"
    [ -f "$ko" ] || die "amdgpu.ko was not produced: $ko"
    log "PASS: amdgpu.ko exists"

    log "VERIFY 2/8: KFD source exists"
    [ -f "$kfd_src" ] || die "KFD source is missing: $kfd_src"
    log "PASS: KFD source exists"

    log "VERIFY 3/8: UTS_RELEASE"
    generated_release="$(
        sed -n \
            's/^#define UTS_RELEASE "\(.*\)"/\1/p' \
            "$SRC_DIR/include/generated/utsrelease.h"
    )"
    [ "$generated_release" = "$KVER" ] ||
        die "module tree UTS_RELEASE '$generated_release' does not match '$KVER'"
    log "PASS: UTS_RELEASE=$generated_release"

    log "VERIFY 4/8: module vermagic"
    vermagic="$(modinfo -F vermagic "$ko")"
    printf '%s\n' "$vermagic" | grep -q "^${KVER} " ||
        die "vermagic '$vermagic' does not start with '$KVER'"
    log "PASS: vermagic=$vermagic"

    log "VERIFY 5/8: Polaris10 KFD PCI-atomics exemption"
    grep -q 'asic_type != CHIP_POLARIS10' "$kfd_src" ||
        die "KFD source does not contain the Polaris10 PCI-atomics exemption"
    grep -q 'asic_type != CHIP_HAWAII &&' "$kfd_src" ||
        die "KFD source does not contain the expected atomics gate"
    grep -q 'kfd->device_info.needs_pci_atomics = true' "$kfd_src" ||
        die "KFD source has no PCI-atomics gate; wrong kernel tree"
    log "PASS: Polaris10 PCI-atomics exemption is present"

    log "VERIFY 6/8: readelf relocation table"
    if ! readelf -rW "$ko" >"$WORK/amdgpu-relocations.txt" 2>"$WORK/readelf.err"; then
        cat "$WORK/readelf.err" >&2
        die "readelf failed for $ko"
    fi
    log "PASS: relocation table readable"

    log "VERIFY 7/8: cleanup_module relocation"
    expected_exit_offset="$(
        pahole -C module /sys/kernel/btf/vmlinux 2>/dev/null |
            sed -n 's/.*void[[:space:]]\+(\*exit)(void);[[:space:]]*\/\*[[:space:]]*\([0-9]\+\).*/\1/p' |
            head -1 || true
    )"
    [ -n "$expected_exit_offset" ] ||
        die "unable to determine struct module.exit offset from running kernel BTF"

    expected_relocation="$(printf '%x' "$expected_exit_offset")"

    relocation="$(
        awk '
            /\.rela\.gnu\.linkonce\.this_module/ {
                in_section = 1
                next
            }
            in_section && /cleanup_module/ {
                print $1
                exit
            }
            in_section &&
            /^Relocation section / &&
            !/\.rela\.gnu\.linkonce\.this_module/ {
                exit
            }
        ' "$WORK/amdgpu-relocations.txt"
    )"
    [ -n "$relocation" ] || die "unable to determine cleanup_module relocation"

    relocation="$(printf '%x' "$((16#$relocation))")"

    [ "$relocation" = "$expected_relocation" ] ||
        die "unexpected cleanup_module relocation '0x$relocation'; expected '0x$expected_relocation' from running kernel BTF"
    log "PASS: cleanup_module relocation=0x$relocation matches running kernel struct module.exit"

    log "VERIFY 8/8: module metadata"
    log "  file: $(file "$ko")"
    log "  size: $(du -h "$ko" | awk '{print $1}') (before strip)"
    log "PASS: module metadata"

    log "Built: $ko"
    stage_done
}

# The build keeps full debug info (hundreds of MB). The stock module is
# stripped, so do the same. This MUST run before signing: stripping a signed
# module would invalidate the signature.
strip_module() {
    stage_start "strip_module"
    local ko="$SRC_DIR/drivers/gpu/drm/amd/amdgpu/amdgpu.ko" before after

    before="$(stat -c %s "$ko")"
    strip --strip-debug "$ko"
    after="$(stat -c %s "$ko")"
    log "Stripped debug info: $((before / 1048576)) MB -> $((after / 1048576)) MB"

    modinfo -F vermagic "$ko" | grep -q "^${KVER} " ||
        die "vermagic broke after strip"

    if ! grep -aq "PCI rejects atomics" "$ko"; then
        warn "the 'PCI rejects atomics' string is not in the stripped module (message text may differ in this kernel); the source-level checks passed"
    fi
    stage_done
}

secure_boot_enabled() {
    command -v mokutil >/dev/null &&
        mokutil --sb-state 2>/dev/null |
        grep -qi 'enabled'
}

sign_module() {
    stage_start "sign_module"

    local ko="$SRC_DIR/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"

    if ! secure_boot_enabled; then
        log "Secure Boot is disabled; signing not required"
        stage_done
        return 0
    fi

    log "Secure Boot is enabled"

    if [ -z "$SIGN_KEY" ] &&
       [ -f /var/lib/shim-signed/mok/MOK.priv ] &&
       [ -f /var/lib/shim-signed/mok/MOK.der ]; then
        SIGN_KEY=/var/lib/shim-signed/mok/MOK.priv
        SIGN_CERT=/var/lib/shim-signed/mok/MOK.der
    fi

    if [ -z "$SIGN_KEY" ] || [ -z "$SIGN_CERT" ]; then
        if [ "$BUILD_ONLY" = 1 ]; then
            warn "Secure Boot is on and no signing key was given; build completed but module is unsigned"
            stage_done
            return 0
        fi
        die "Secure Boot is enabled; signing key and certificate are required (--sign-key / --sign-cert)"
    fi

    mokutil --test-key "$SIGN_CERT" 2>&1 |
        grep -qi 'already enrolled' ||
        die "$SIGN_CERT is not enrolled in the MOK list"

    log "Signing amdgpu.ko"
    "/usr/src/linux-headers-${KVER}/scripts/sign-file" \
        sha512 "$SIGN_KEY" "$SIGN_CERT" "$ko"

    log "PASS: module signed"
    stage_done
}

# Use the same compression as the stock module so the host's kmod and the
# initramfs can read it. Signing happens before compression, as Ubuntu does.
stock_compression() {
    local stock
    stock="$(
        find "/lib/modules/${KVER}/kernel/drivers/gpu/drm/amd/amdgpu" \
            -maxdepth 1 -name 'amdgpu.ko*' 2>/dev/null |
        head -1 || true
    )"
    case "$stock" in
        *.zst) echo zst ;;
        *.xz)  echo xz ;;
        *.gz)  echo gz ;;
        *)     echo none ;;
    esac
}

# `updates/` outranks `kernel/` in depmod's search order, which leaves the stock
# module on disk as the fallback and touches nothing the package manager owns.
install_module() {
    stage_start "install_module"

    local ko="$SRC_DIR/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
    local dir="/lib/modules/${KVER}/updates"
    local dest img n resolved

    mkdir -p "$dir"
    rm -f "$dir"/amdgpu.ko "$dir"/amdgpu.ko.*

    case "$(stock_compression)" in
        zst)
            dest="$dir/amdgpu.ko.zst"
            zstd -q -19 -T0 -f "$ko" -o "$dest"
            ;;
        xz)
            dest="$dir/amdgpu.ko.xz"
            xz -c --check=crc32 -6 "$ko" > "$dest"
            ;;
        gz)
            dest="$dir/amdgpu.ko.gz"
            gzip -9 -c "$ko" > "$dest"
            ;;
        *)
            dest="$dir/amdgpu.ko"
            install -D -m 0644 "$ko" "$dest"
            ;;
    esac
    chmod 0644 "$dest"
    log "Installed $dest ($(( $(stat -c %s "$dest") / 1048576 )) MB)"

    log "Running depmod"
    depmod -a "$KVER"

    resolved="$(modinfo -k "$KVER" -n amdgpu)"
    log "depmod resolves amdgpu to: $resolved"
    [ "$resolved" = "$dest" ] ||
        die "depmod resolves amdgpu to $resolved, not $dest"
    log "PASS: installed module is preferred by depmod"

    # Safety net: load amdgpu on every boot even if udev autoload misses it.
    printf 'amdgpu\n' > /etc/modules-load.d/gfx803-amdgpu.conf
    log "Wrote /etc/modules-load.d/gfx803-amdgpu.conf"

    if [ "$DO_INITRAMFS" = 1 ]; then
        log "Rebuilding initramfs"
        update-initramfs -u -k "$KVER"
        img="/boot/initrd.img-${KVER}"
        if [ -f "$img" ] && command -v lsinitramfs >/dev/null; then
            n="$(lsinitramfs "$img" | grep -c 'updates/amdgpu\.ko' || true)"
            if [ "${n:-0}" -ge 1 ]; then
                log "PASS: initramfs contains the patched amdgpu ($(( $(stat -c %s "$img") / 1048576 )) MB)"
            else
                warn "the patched amdgpu is NOT inside $img; the stock module may load first"
            fi
        fi
    else
        log "Initramfs rebuild skipped (--no-initramfs)"
    fi

    log "Installed module:"
    modinfo -k "$KVER" amdgpu |
        grep -E '^(filename|version|vermagic|srcversion):' || true

    stage_done
}

uninstall_module() {
    local dir="/lib/modules/${KVER}/updates" found=0 f

    for f in "$dir"/amdgpu.ko "$dir"/amdgpu.ko.*; do
        if [ -f "$f" ]; then
            rm -f "$f"
            found=1
        fi
    done
    rm -f /etc/modules-load.d/gfx803-amdgpu.conf
    rmdir --ignore-fail-on-non-empty "$dir" 2>/dev/null || true

    if [ "$found" = 1 ]; then
        depmod -a "$KVER"
        if [ "$DO_INITRAMFS" = 1 ]; then
            update-initramfs -u -k "$KVER"
        fi
        log "Removed the patched amdgpu; the stock one loads again after a reboot"
    else
        log "Nothing to remove under $dir"
    fi
}

# The kernel source and build objects take several GB. Only a tree this script
# downloaded itself is removed, never a --source-dir the user supplied.
cleanup_build_tree() {
    if [ "$KEEP_WORKDIR" = 1 ]; then
        log "Keeping build tree under $WORK (--keep-workdir)"
        return 0
    fi
    case "$SRC_DIR" in
        "$WORK"/src/*)
            log "Removing build tree $WORK/src (use --keep-workdir to keep it)"
            cd /
            rm -rf "$WORK/src" "$WORK/apt-lists"
            ;;
        *)
            log "Not removing $SRC_DIR (not downloaded by this script)"
            ;;
    esac
}

print_next_steps() {
    cat <<EOF

Done. The running amdgpu drives the display and cannot be swapped live, so
reboot to load the new module. Afterwards:

    lsmod | grep amdgpu
    modinfo -n amdgpu
    sudo dmesg | grep -i -E 'kfd|atomic'
    ls /sys/class/kfd/kfd/topology/nodes

amdgpu should be loaded without a manual modprobe. A KFD node for the RX 580
(device_id 26591 in its 'properties' file) means the gate is gone. Kernel
updates install a fresh stock module under kernel/, and the one from this
script only covers ${KVER}: run the script again after each kernel update.
To go back to the stock module:

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

    log "============================================================"
    log "ROCm gfx803 native amdgpu/KFD host setup"
    log "Kernel: $KVER"
    log "Workdir: $WORK"
    log "Jobs: $JOBS"
    log "============================================================"

    if [ "$UNINSTALL" = 1 ]; then
        uninstall_module
        log "ALL DONE: uninstall completed"
        return 0
    fi

    install_deps
    fetch_patch
    fetch_source
    apply_patch

    if [ "$PATCH_ONLY" = 1 ]; then
        log "Patch applied to $SRC_DIR"
        log "ALL DONE: patch-only completed"
        return 0
    fi

    configure_tree
    build_module
    verify_module
    strip_module
    sign_module

    if [ "$BUILD_ONLY" = 1 ]; then
        log "Build-only mode: installation skipped"
        log "Module: $SRC_DIR/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
        log "ALL DONE: BUILD + VERIFY completed successfully"
        return 0
    fi

    install_module
    cleanup_build_tree
    print_next_steps

    log "============================================================"
    log "ALL DONE: BUILD + VERIFY + INSTALL completed successfully"
    log "============================================================"
}

main "$@"
