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

CURRENT_STAGE="startup"

stage_start() {
    CURRENT_STAGE="$1"
    log "START: $CURRENT_STAGE"
}

stage_done() {
    log "DONE: $CURRENT_STAGE"
}

trap 'rc=$?; if [ "$rc" -ne 0 ]; then printf "FATAL: stage=%s exit=%s line=%s\n" "$CURRENT_STAGE" "$rc" "${BASH_LINENO[0]:-unknown}" >&2; fi; exit "$rc"' ERR

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

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    return 0
}
trap cleanup EXIT

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
            --workdir)
                WORK="${2:?--workdir needs a directory}"
                shift
                ;;
            --jobs)
                JOBS="${2:?--jobs needs a number}"
                shift
                ;;
            -h|--help)
                sed -n '2,/^set -euo/p' "$0" |
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

# Return the source version recorded by the installed kernel package.
# The source package name is discovered separately because Ubuntu HWE kernels
# may come from source packages such as linux-hwe-7.0 rather than `linux`.
running_source_version() {
    dpkg-query -W -f='${Version}' "linux-modules-${KVER}" 2>/dev/null \
        || dpkg-query -W -f='${Version}' "linux-image-${KVER}" 2>/dev/null \
        || dpkg-query -W -f='${Version}' "linux-image-unsigned-${KVER}" 2>/dev/null \
        || true
}

validate_source_dir() {
    [ -f "$SRC_DIR/drivers/gpu/drm/amd/amdkfd/kfd_device.c" ] ||
        die "$SRC_DIR is not a kernel source root"

    [ -f "$SRC_DIR/debian.master/changelog" ] ||
        die "$SRC_DIR does not contain debian.master/changelog"

    local want have want_base

    want="$(running_source_version)"

    [ -n "$want" ] ||
        die "cannot tell which source version kernel $KVER was built from"

    have="$(
        dpkg-parsechangelog \
            -l "$SRC_DIR/debian.master/changelog" \
            -S Version 2>/dev/null || true
    )"

    want_base="${want%%~*}"

    if [ -n "$have" ] &&
       [ "$have" != "$want" ] &&
       [ "$have" != "$want_base" ] &&
       [ "$ALLOW_MISMATCH" = 0 ]; then
        die "unpacked source is $have but the running kernel is $want"
    fi

    if [ -n "$have" ] &&
       [ "$have" != "$want" ] &&
       [ "$have" != "$want_base" ]; then
        warn "source version $have differs from running kernel package $want"
    fi
}

fetch_source() {
    stage_start "fetch_source"
    if [ -n "$SRC_DIR" ]; then
        validate_source_dir
        return 0
    fi

    local want source_pkg source_ver src_list lists_dir list out have

    want="$(running_source_version)"
    [ -n "$want" ] ||
        die "cannot tell which source version kernel $KVER was built from; pass --source-dir"

    source_pkg="$(
        dpkg-query -W -f='${source:Package}\n' "linux-modules-${KVER}" 2>/dev/null |
        head -1
    )"

    if [ -z "$source_pkg" ]; then
        source_pkg="$(
            dpkg-query -W -f='${source:Package}\n' "linux-image-${KVER}" 2>/dev/null |
            head -1
        )"
    fi

    if [ -z "$source_pkg" ]; then
        source_pkg="$(
            dpkg-query -W -f='${source:Package}\n' "linux-image-unsigned-${KVER}" 2>/dev/null |
            head -1
        )"
    fi

    [ -n "$source_pkg" ] ||
        die "cannot determine the source package for kernel $KVER; pass --source-dir"

    src_list="$WORK/gfx803-deb-src.sources"
    lists_dir="$WORK/apt-lists"

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
                sed \
                    -e '/^[[:space:]]*deb[[:space:]]/s/^[[:space:]]*deb[[:space:]]/deb-src /' \
                    "$list" > "$src_list"
                ;;
        esac

        break
    done

    [ -s "$src_list" ] ||
        die "no Ubuntu apt source configuration available for deb-src"

    log "Updating only the kernel deb-src indexes"

    apt-get update \
        -o Dir::Etc::sourcelist="$src_list" \
        -o Dir::Etc::sourceparts="-" \
        -o Dir::State::lists="$lists_dir" \
        -o APT::Get::List-Cleanup="0" \
        </dev/null ||
        die "failed to update the kernel deb-src indexes"

    source_ver="$want"

    if ! apt-cache \
        -o Dir::Etc::sourcelist="$src_list" \
        -o Dir::Etc::sourceparts="-" \
        -o Dir::State::lists="$lists_dir" \
        showsrc "${source_pkg}=${source_ver}" >/dev/null 2>&1
    then
        if [ "$ALLOW_MISMATCH" = 1 ]; then
            source_ver="$(
                apt-cache \
                    -o Dir::Etc::sourcelist="$src_list" \
                    -o Dir::Etc::sourceparts="-" \
                    -o Dir::State::lists="$lists_dir" \
                    showsrc "$source_pkg" 2>/dev/null |
                awk -v pkg="$source_pkg" '
                    $1 == "Package:" {
                        found = ($2 == pkg)
                        next
                    }
                    found && $1 == "Version:" {
                        print $2
                        exit
                    }
                '
            )"

            [ -n "$source_ver" ] ||
                die "no source version is available for $source_pkg"

            warn "exact source version $want is not available; using $source_pkg=$source_ver because --allow-source-mismatch was specified"
        else
            die "$source_pkg=$want is not available from the configured deb-src archives; pass --source-dir or --allow-source-mismatch"
        fi
    fi

    mkdir -p "$WORK/src"
    cd "$WORK/src"

    log "Kernel source package: $source_pkg"
    log "Kernel source version: $source_ver"
    log "Fetching kernel source package ${source_pkg}=${source_ver} (about 250 MB download)"

    if ! apt-get \
        -o Dir::Etc::sourcelist="$src_list" \
        -o Dir::Etc::sourceparts="-" \
        -o Dir::State::lists="$lists_dir" \
        source "${source_pkg}=${source_ver}" </dev/null
    then
        if [ "$ALLOW_MISMATCH" = 1 ]; then
            warn "${source_pkg}=${source_ver} is no longer in the archive; using the newest source"

            apt-get \
                -o Dir::Etc::sourcelist="$src_list" \
                -o Dir::Etc::sourceparts="-" \
                -o Dir::State::lists="$lists_dir" \
                source "$source_pkg" </dev/null ||
                die "failed to fetch the newest source package $source_pkg"
        else
            die "${source_pkg}=${source_ver} is not available from the archive. Pass --source-dir with the exact source, or --allow-source-mismatch to accept the newest one"
        fi
    fi

    out="$(
        find "$WORK/src" \
            -maxdepth 1 \
            -mindepth 1 \
            -type d \
            -name 'linux*' |
        head -1
    )"

    [ -n "$out" ] ||
        die "apt-get source produced no source directory"

    SRC_DIR="$out"

    have="$(
        dpkg-parsechangelog \
            -l "$SRC_DIR/debian.master/changelog" \
            -S Version 2>/dev/null || true
    )"

    want_base="${want%%~*}"

    if [ -n "$have" ] &&
       [ "$have" != "$want" ] &&
       [ "$have" != "$want_base" ] &&
       [ "$ALLOW_MISMATCH" = 0 ]; then
        die "unpacked source is $have but the running kernel is $want"
    fi
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
# 1. /boot/config-$KVER must be used unchanged. In particular,
#    CONFIG_DEBUG_INFO_BTF_MODULES and the other module-related options affect
#    the kernel's struct module layout. Using a generic/source-tree .config
#    produced a cleanup_module relocation at 0x490, while the running kernel
#    expects 0x4a8.
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

    # IMPORTANT:
    # modules_prepare is allowed to rewrite .config.
    # Therefore DO NOT compare .config after modules_prepare.
    make -C "$SRC_DIR" \
        KERNELRELEASE="$KVER" \
        modules_prepare \
        >"$WORK/modules-prepare.log" 2>&1 || {
            tail -100 "$WORK/modules-prepare.log" >&2
            die "modules_prepare failed"
        }

    # Restore the exact running configuration AFTER modules_prepare.
    # Do NOT run modules_prepare again.
    cp -f "$running_config" .config

    # Restore the exact Module.symvers as well.
    cp -f "$headers/Module.symvers" Module.symvers

    # Verify required configuration symbols.
    grep -qx 'CONFIG_DRM_AMDGPU=m' .config ||
        die "CONFIG_DRM_AMDGPU is not=m"

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
    log "  CONFIG_DRM_AMDGPU = $(grep '^CONFIG_DRM_AMDGPU=' .config)"
    log "  CONFIG_HSA_AMD = $(grep '^CONFIG_HSA_AMD=' .config)"
    log "  CONFIG_MODVERSIONS = $(grep '^CONFIG_MODVERSIONS=' .config)"
    log "  CONFIG_LTO_NONE = $(grep '^CONFIG_LTO_NONE=' .config)"
    log "  CONFIG_MODULES_USE_ELF_RELA = $(grep '^CONFIG_MODULES_USE_ELF_RELA=' .config)"
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
        >"$WORK/clean.log" 2>&1 ||
        {
            tail -30 "$WORK/clean.log" >&2
            die "amdgpu clean failed; full log: $WORK/clean.log"
        }

    log "DONE: amdgpu clean"

    log "BUILD 2/2: Building amdgpu.ko with $JOBS parallel job(s)"

    make \
        KERNELRELEASE="$KVER" \
        -j"$JOBS" \
        M=drivers/gpu/drm/amd/amdgpu \
        modules \
        >"$WORK/build.log" 2>&1 ||
        {
            tail -50 "$WORK/build.log" >&2
            die "module build failed; full log: $WORK/build.log"
        }

    [ -f "$SRC_DIR/drivers/gpu/drm/amd/amdgpu/amdgpu.ko" ] ||
        die "make returned successfully but amdgpu.ko is missing"

    log "PASS: amdgpu.ko was produced"
    log "Build log: $WORK/build.log"

    stage_done
}

verify_module() {
    stage_start "verify_module"

    local ko="$SRC_DIR/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
    local kfd_src="$SRC_DIR/drivers/gpu/drm/amd/amdkfd/kfd_device.c"
    local vermagic
    local generated_release
    local relocation
    local expected_relocation="00000000000004a8"

    log "VERIFY 1/8: amdgpu.ko exists"
    [ -f "$ko" ] ||
        die "amdgpu.ko was not produced: $ko"
    log "PASS: amdgpu.ko exists"

    log "VERIFY 2/8: KFD source exists"
    [ -f "$kfd_src" ] ||
        die "KFD source is missing: $kfd_src"
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

    printf '%s\n' "$vermagic" |
        grep -q "^${KVER} " ||
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

    relocation="$(
        awk '
            /\.rela\.gnu\.linkonce\.this_module/ {
                in_section=1
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

    [ "$relocation" = "$expected_relocation" ] ||
        die \
            "unexpected cleanup_module relocation '$relocation'; expected $expected_relocation"

    log "PASS: cleanup_module relocation=0x4a8"

    log "VERIFY 8/8: module metadata"

    log "  file: $(file "$ko")"
    log "  size: $(du -h "$ko" | awk '{print $1}')"

    log "PASS: module metadata"

    log "Verified patched KFD source for Polaris10"
    log "Verified UTS_RELEASE: $generated_release"
    log "Verified vermagic: $vermagic"
    log "Verified struct module cleanup_module relocation: 0x4a8"
    log "Built: $ko"

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

        die "Secure Boot is enabled; signing key and certificate are required"
    fi

    mokutil --test-key "$SIGN_CERT" 2>&1 |
        grep -qi 'already enrolled' ||
        die "$SIGN_CERT is not enrolled in the MOK list"

    log "Signing amdgpu.ko"

    "/usr/src/linux-headers-${KVER}/scripts/sign-file" \
        sha512 \
        "$SIGN_KEY" \
        "$SIGN_CERT" \
        "$ko"

    log "PASS: module signed"

    stage_done
}

# `updates/` outranks `kernel/` in depmod's search order, which leaves the stock
# module on disk as the fallback and touches nothing the package manager owns.
install_module() {
    stage_start "install_module"

    local ko="$SRC_DIR/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
    local dest="/lib/modules/${KVER}/updates/amdgpu.ko"

    log "Installing: $dest"

    install -D -m 0644 "$ko" "$dest"

    log "Running depmod"
    depmod -a "$KVER"

    local resolved
    resolved="$(modinfo -k "$KVER" -n amdgpu)"

    log "depmod resolves amdgpu to: $resolved"

    [ "$resolved" = "$dest" ] ||
        die "depmod still resolves amdgpu to $resolved, not $dest"

    log "PASS: installed module is preferred by depmod"

    if [ "$DO_INITRAMFS" = 1 ]; then
        log "Rebuilding initramfs"
        update-initramfs -u -k "$KVER"
        log "PASS: initramfs rebuilt"
    else
        log "Initramfs rebuild skipped (--no-initramfs)"
    fi

    log "Installed module:"
    modinfo -k "$KVER" amdgpu |
        grep -E '^(filename|version|vermagic|srcversion):'

    stage_done
}

uninstall_module() {
    local dest="/lib/modules/${KVER}/updates/amdgpu.ko"

    if [ -f "$dest" ]; then
        rm -f "$dest"
        rmdir \
            --ignore-fail-on-non-empty \
            "/lib/modules/${KVER}/updates" \
            2>/dev/null || true

        depmod -a "$KVER"

        [ "$DO_INITRAMFS" = 1 ] &&
            update-initramfs -u -k "$KVER"

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

    log "============================================================"
    log "ROCm gfx803 native amdgpu/KFD host setup"
    log "Kernel: $KVER"
    log "Workdir: $WORK"
    log "Jobs: $JOBS"
    log "============================================================"

    if [ "$UNINSTALL" = 1 ]; then
        uninstall_module
        log "============================================================"
        log "ALL DONE: uninstall completed"
        log "============================================================"
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
    sign_module

    if [ "$BUILD_ONLY" = 1 ]; then
        log "Build-only mode: installation skipped"
        log "Module:"
        log "  $SRC_DIR/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
        log "============================================================"
        log "ALL DONE: BUILD + VERIFY completed successfully"
        log "============================================================"
        return 0
    fi

    install_module
    print_next_steps

    log "============================================================"
    log "ALL DONE: BUILD + VERIFY + INSTALL completed successfully"
    log "============================================================"
}

main "$@"
