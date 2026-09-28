#!/bin/sh
# Add Tensile Logic YAML files for navi10 (gfx1010, RX 5700 XT / RDNA1).
#
# WHY: rocBLAS ships Tensile GEMM logic for navi21/22/23/24/31/32/33 but
# never shipped any for navi10 (gfx1010) -- AMD dropped RDNA1 from the
# officially-tuned target list. Without a Logic/asm_full/navi10/ directory,
# TensileCreateLibrary generates no gfx1010 kernels and rocBLAS aborts on
# the first gfx1010 GEMM call. gfx1010 itself is NOT missing from rocBLAS's
# C++ dispatch layer -- library/src/tensile_host.cpp and handle.cpp already
# match "gfx1010" and return Tensile::LazyLoadingInit::gfx1010, and that
# enum value is hand-written into
# shared/tensile/Tensile/Source/lib/include/Tensile/PlaceholderLibrary.hpp
# in this exact source tree (verified against the ROCM_LIBRARIES_REF this
# repo pins). So, unlike a standalone rocBLAS+Tensile checkout where the two
# can be pinned to mismatched versions, nothing here needs to be patched or
# commented out in tensile_host.cpp -- the monorepo checkout guarantees
# rocBLAS and Tensile are the one pinned revision, so the enum is always
# present when the "gfx1010" string match compiles.
#
# WHAT: generate the navi10 logic files by taking this tree's own current
# navi21 (gfx1030) logic files -- already in the Tensile schema this exact
# Tensile version reads -- and substituting:
#   gfx1030 -> gfx1010, navi21 -> navi10, device ID 73a2 -> 731f,
#   and, in every per-solution "ISA: [10, 3, 0]" field, 10,3,0 -> 10,1,0
# then dropping the I8II (int8) files: gfx1010 has no assembly int8 path and
# those kernels fail to build. The 24 navi10_*.yaml files independently
# published at https://github.com/jc1122/rocblas-gfx1010 only rewrite the
# 4-line file header (device/gfx/arch name) the same way the first three
# substitutions above do -- every one of their ~4,100 per-solution ISA
# fields (one per solution, hundreds per file) is left as "[10, 3, 0]",
# i.e. gfx1030/RDNA2, never "[10, 1, 0]"/gfx1010. TensileCreateLibrary uses
# that field, not the logic file's own name or header, to decide which
# gfx target a kernel's object file is compiled and packaged under
# (Tensile/TensileCreateLibrary.py: getAssemblyCodeObjectFiles buckets
# kernels via archs[tuple(k['ISA'])], and buildObjectFileNames names the
# resulting .co via gfxName(kernel['ISA'])). Left as gfx1030, these
# kernels build and package as gfx1030, not gfx1010 -- silently giving
# rocBLAS zero registered Tensile solutions for gfx1010, i.e. exactly the
# "no gfx1010 kernels, aborts on first GEMM call" failure this script
# exists to fix, just deferred past a successful-looking build. This
# script derives the files from source already in this checkout instead
# of vendoring jc1122's third-party copy (no stated license, and it would
# carry the same latent bug), fixes the ISA field the substitution above
# missed, and self-updates if AMD ever re-tunes navi21.
#
# NOT YET RE-VERIFIED ON REAL HARDWARE: this only makes the generated
# solutions self-consistently declare gfx1010. It does not confirm that
# every navi21-derived tuning parameter (tile sizes, occupancy, VGPR/LDS
# budgets) fits gfx1010's actual register file and LDS allocation
# granularity -- RDNA2 doubled both over RDNA1. TensileCreateLibrary may
# still reject individual solutions that overshoot gfx1010's real limits;
# that would surface as a build-time failure, not a silent one, but the
# resulting library's coverage and performance have not been checked
# against a gfx1010 card.
set -eu

ROOT="${1:-/rocblas-src-root}"
SRC="$ROOT/projects/rocblas"
NAVI21_DIR="$SRC/library/src/blas3/Tensile/Logic/asm_full/navi21"
NAVI10_DIR="$SRC/library/src/blas3/Tensile/Logic/asm_full/navi10"

[ -d "$NAVI21_DIR" ] || {
    echo "FATAL: $NAVI21_DIR does not exist -- upstream moved or renamed the" >&2
    echo "       navi21 Tensile logic directory, so navi10 cannot be derived" >&2
    echo "       from it the way this script assumes. Re-check the path before" >&2
    echo "       re-running." >&2
    exit 1
}

if [ -d "$NAVI10_DIR" ] && [ -n "$(find "$NAVI10_DIR" -name '*.yaml' -print -quit)" ]; then
    echo "navi10 Tensile logic already present, skipping"
    exit 0
fi

mkdir -p "$NAVI10_DIR"

count=0
for f in "$NAVI21_DIR"/navi21_*.yaml; do
    base="$(basename "$f")"
    case "$base" in
        *_I8II_BH.yaml|*_I8II_BH_GB.yaml)
            # gfx1010 has no assembly int8 support; these fail to build.
            continue
            ;;
    esac
    out="$NAVI10_DIR/$(echo "$base" | sed 's/^navi21_/navi10_/')"
    sed -e 's/gfx1030/gfx1010/g' -e 's/navi21/navi10/g' -e 's/73a2/731f/g' \
        -e 's/ISA: \[10, 3, 0\]/ISA: [10, 1, 0]/g' \
        "$f" > "$out"
    count=$((count + 1))
done

echo "Generated $count navi10 Tensile logic YAML files in $NAVI10_DIR"
if [ "$count" -ne 24 ]; then
    echo "WARNING: expected 24 files (32 navi21 files minus 8 I8II variants);" >&2
    echo "         got $count. Upstream's navi21 file set changed shape --" >&2
    echo "         re-check which files exist before trusting this output." >&2
fi

# Fail loudly rather than silently shipping a gfx1030-tagged solution under
# the navi10 directory -- see WHY above for what that costs.
if grep -rl 'ISA: \[10, 3, 0\]' "$NAVI10_DIR" >/dev/null 2>&1; then
    echo "FATAL: some generated navi10 solutions still declare ISA: [10, 3, 0]" >&2
    echo "       (gfx1030/RDNA2). The sed substitution above did not catch" >&2
    echo "       every occurrence -- check for a formatting variant (extra" >&2
    echo "       whitespace, no space after the commas, etc.) in:" >&2
    grep -rl 'ISA: \[10, 3, 0\]' "$NAVI10_DIR" >&2
    exit 1
fi
if ! grep -rq 'ISA: \[10, 1, 0\]' "$NAVI10_DIR"; then
    echo "FATAL: no solution in $NAVI10_DIR declares ISA: [10, 1, 0]" >&2
    echo "       (gfx1010/RDNA1) after substitution -- something upstream" >&2
    echo "       changed the ISA field's format or the navi21 source had" >&2
    echo "       none to begin with. Re-check before trusting this output." >&2
    exit 1
fi
