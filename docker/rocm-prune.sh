#!/usr/bin/env bash
# Cut a full ROCm SDK installation down to what one GPU architecture
# needs, inside a build stage whose filesystem is about to be flattened.
#
# `rocm/dev-ubuntu-26.04:10.1.0-full` unpacks to 20.5 GB and compresses
# to the 8.67 GB layer that is 71-95% of every image this repo
# publishes. AMD ships no -runtime variant of that tag, so the trimming
# is ours to do.
#
# It is done with dpkg rather than with `rm`, because ROCm 10.1 already
# splits its per-architecture content into packages named
# <component>10.1-<gfx>: amdrocm-blas10.1-gfx942, amdrocm-dnn10.1-gfx90a
# and 258 more. Purging the ones for architectures we do not build for
# is 10.77 GB of the 20.53, and dpkg knows what belongs to each, which a
# filename pattern does not. The `rm` passes below are for what
# packaging cannot express: static archives that nothing links, docs,
# and — under `minimal` only — the headers and the HIP cmake package.
#
# Three of those passes have been wrong, each caught by a wheel build
# hours downstream rather than here, so each now has an assertion in
# Dockerfile.rocm-runtime: the clang builtins runtime, the HIP cmake
# package, and the archives a cmake config imports. The shape of the
# mistake was the same every time — a removal justified by reasoning
# about the *runtime* images, applied in a profile whose name promises
# a toolchain that builds.
#
#   keep-toolchain  hipcc, the headers, LLVM and /opt/rocm/lib/cmake
#                   stay. For images where something compiles, whether
#                   at build time (pytorch-wheel runs cmake against
#                   ROCm) or at run time (AITER JITs kernels, Triton
#                   shells out to ld.lld).
#   minimal         those go too. For the plain PyTorch runtime image,
#                   which compiles nothing.
#
# Usage:  rocm-prune.sh <gfx-arch>[;<gfx-arch>...] <profile>
set -euo pipefail

ARCHES_RAW="${1:?usage: rocm-prune.sh <arch[;arch]> <keep-toolchain|minimal>}"
PROFILE="${2:?usage: rocm-prune.sh <arch[;arch]> <keep-toolchain|minimal>}"

case "${PROFILE}" in
    keep-toolchain|minimal) ;;
    *) echo "rocm-prune: unknown profile '${PROFILE}'" >&2; exit 2 ;;
esac

# PYTORCH_ROCM_ARCH is ";"-separated when it names several targets, the
# same convention the rest of this repo uses.
IFS=';' read -r -a ARCHES <<< "${ARCHES_RAW}"
[ "${#ARCHES[@]}" -ge 1 ] || { echo "rocm-prune: no architecture given" >&2; exit 2; }

size_gb() {
    dpkg-query -W -f='${Installed-Size}\n' 2>/dev/null \
        | awk '{s+=$1} END {printf "%.2f", s/1048576}'
}

# The real installation root, resolved BEFORE anything is purged.
#
# /opt/rocm is a farm of symlinks into /etc/alternatives, which point in
# turn at /opt/rocm/core-<ver>. Those alternatives are registered by the
# per-architecture core packages — so purging them takes the whole farm
# with it, and /opt/rocm/lib stops resolving while every file it named
# is still on disk. That is not hypothetical: the first version of this
# script left a correct 4.4 GB tree that nothing could find.
ROCM_REAL=$(dirname "$(readlink -f /opt/rocm/lib)")
[ -d "${ROCM_REAL}/lib" ] || {
    echo "rocm-prune: cannot resolve the ROCm root from /opt/rocm/lib" >&2
    exit 1
}

before=$(size_gb)
echo "rocm-prune: profile=${PROFILE} keep=${ARCHES_RAW} installed=${before}GB"

# ─── 1. Per-architecture packages ────────────────────────────────
# Every package whose name ends in -gfxNNNN, less the ones we keep.
#
# The keep list is matched on the whole suffix, not as a substring:
# "-gfx1201" must not also match "-gfx120140", and gfx1250 has a
# gfx1250v0 sibling that is a different target.
keep_re=""
for a in "${ARCHES[@]}"; do
    [ -n "${a}" ] || continue
    keep_re="${keep_re}${keep_re:+|}${a}"
done

mapfile -t doomed < <(
    dpkg-query -W -f='${Package}\n' 2>/dev/null \
    | grep -E -- '-gfx[0-9a-z]+$' \
    | grep -Ev -- "-(${keep_re})\$" || true
)

# A full SDK that matched nothing is not a clean no-op, it is a changed
# naming scheme — and the failure mode of carrying on is an image that
# silently keeps all 10.77 GB. Fail here instead.
if [ "${#doomed[@]}" -eq 0 ]; then
    echo "rocm-prune: no per-arch packages matched -gfxNNNN." >&2
    echo "  ROCm's packaging has changed; re-check this script against" >&2
    echo "  'dpkg-query -W' before trusting the image it produces." >&2
    exit 1
fi

echo "rocm-prune: purging ${#doomed[@]} packages for other architectures"
# --force-depends, because the arch packages are pulled in by a
# full-SDK metapackage that Depends on all of them. Without it apt
# declines the whole operation; with it, dpkg removes the files and
# leaves the metapackage unsatisfied, which is correct — this image is
# a build output, not a system anyone will apt-upgrade.
dpkg --purge --force-depends "${doomed[@]}" > /dev/null

# ─── 1b. The metapackages left pointing at nothing ───────────────
# --force-depends removes the files but leaves every package that
# Depends on one of them unsatisfiable, and apt then refuses to do
# anything at all — including in a *downstream* image, where it
# surfaces as a bare "E: Unmet dependencies" from an apt-get install
# that has nothing to do with ROCm. Dockerfile.base hit exactly that.
#
# What is left broken is only ever the full-SDK metapackages
# (amdrocm-core-sdk10.1 and friends): containers of Depends lines
# carrying no files of their own, whose entire purpose was to pull in
# every architecture. Purging them is what we meant by purging the
# architectures.
#
# Iterated, because removing one tier exposes the next: the per-arch
# sdk packages depend on the per-arch dev packages, and the top-level
# metapackage depends on all of those.
for _ in 1 2 3 4 5; do
    mapfile -t broken < <(
        apt-get check 2>&1 \
        | sed -nE 's/^ ([a-zA-Z0-9.+-]+) : Depends:.*/\1/p' | sort -u
    )
    [ "${#broken[@]}" -gt 0 ] || break
    dpkg --purge --force-depends "${broken[@]}" > /dev/null 2>&1 || break
done

# apt has to be usable afterwards — every downstream Dockerfile starts
# with an apt-get install, and a broken database there is a confusing
# failure a long way from its cause.
apt-get check > /dev/null 2>&1 || {
    echo "rocm-prune: the package database is still inconsistent:" >&2
    apt-get check >&2 || true
    exit 1
}

# ─── 2. Rebuild the /opt/rocm symlinks ───────────────────────────
# Straight at ${ROCM_REAL}, not back through /etc/alternatives. The
# alternatives indirection exists so several ROCm versions can coexist
# and be switched between; a built image has exactly one and is never
# switched, so the indirection buys nothing here and is the single
# thing the purge above breaks.
#
# Done before the rm passes below, which address /opt/rocm/lib and
# would otherwise silently delete nothing.
for d in bin lib include libexec share amdgcn llvm; do
    if [ -e "${ROCM_REAL}/${d}" ] || [ -L "${ROCM_REAL}/${d}" ]; then
        rm -rf "/opt/rocm/${d}"
        ln -s "${ROCM_REAL}/${d}" "/opt/rocm/${d}"
    fi
done
test -e /opt/rocm/lib/libamdhip64.so || {
    echo "rocm-prune: /opt/rocm/lib does not resolve to the HIP runtime" >&2
    exit 1
}

# ─── 3. Static archives ──────────────────────────────────────────
# 4.7 GB across 835 files, the largest being Composable Kernel's
# libdevice_*_operations.a at 1.8 GB. A .a is linked into something at
# build time and never opened at run time, so it has no business in an
# image at all — but it ships inside packages whose shared libraries we
# need, so dpkg cannot express this and rm has to.
#
# Except the compiler's own runtime, which is the one .a that IS opened
# by something we keep. clang links libclang_rt.builtins.a into every
# HIP compilation; without it ld.lld fails with
#
#   cannot open .../lib/clang/24/lib/x86_64-unknown-linux-gnu/\
#   libclang_rt.builtins.a: No such file or directory
#
# and the toolchain is present but cannot produce an executable. That
# took out cupy-wheel, whose configure step compiles a probe program —
# but the real cost is the one that would not have surfaced until a GPU
# host: `keep-toolchain` exists precisely because AITER JIT-compiles
# kernels on first use and Triton shells out to ld.lld, and both would
# have failed the same way at run time.
#
# -prune, not a -path exclusion on the delete: the directory is skipped
# before descent, so a future clang release that adds more archives
# beside the builtins keeps them too.
#
# And not the archives a cmake package config imports, which is the
# other half of the same lesson. Keeping /opt/rocm/lib/cmake (above)
# put those configs back in front of `find_package`, and a config whose
# IMPORTED_LOCATION points at a file this sweep deleted is a hard
# configure error in anything that finds it:
#
#   rocshmem-targets.cmake:87: The imported target "roc::rocshmem"
#   references the file "/opt/rocm/.../librocshmem.a" but this file
#   does not exist.
#
# PyTorch's LoadHIP.cmake find_package()s its way across ROCm, so every
# dangling config is a build stopper and fixing them one at a time is
# a queue, not a fix. Ask the configs what they need instead: anything
# a .cmake file names is kept, everything else goes.
#
# rocshmem is the case that found this. The script keeps that package
# deliberately — see the note at the end about its hard Depends — so
# its config was always going to be there, and its archive always had
# to be there with it.
# Matched on the basename, deliberately. A config spells its archive
# as ${PACKAGE_PREFIX_DIR}/lib/librocshmem.a, so the literal text in
# the file is a fragment with a variable in front of it and never a
# path that exists — comparing resolved paths keeps nothing at all,
# silently, which is exactly the failure this is here to prevent.
# Basenames over-keep only if two components ship archives of the same
# name, and a few duplicated megabytes is the right side to err on.
keep_list=$(mktemp)
grep -rhoE '[A-Za-z0-9_.+-]+\.a\b' "${ROCM_REAL}/lib/cmake" 2>/dev/null \
    | sort -u > "${keep_list}" || true
echo "rocm-prune: $(wc -l < "${keep_list}") archive name(s) referenced by cmake"

find /opt/rocm/ \
    -type d -path '*/llvm/lib/clang/*/lib' -prune -o \
    -name '*.a' -type f -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        grep -qxF "$(basename "$f")" "${keep_list}" || rm -f "$f"
      done
rm -f "${keep_list}"

# ─── 4. Things only a build needs ────────────────────────────────
# Docs go in both profiles. `make docs` is not this.
rm -rf /opt/rocm/share/doc /opt/rocm/share/man \
       /opt/rocm/share/info 2>/dev/null || true

# The cmake package files stay under keep-toolchain, and the claim they
# were removed on — "nothing in either image runs cmake against ROCm" —
# was simply false. pytorch-wheel compiles PyTorch from source inside
# this image, and cmake's own HIP language detection reads
# lib/cmake/hip-lang/hip-lang-config.cmake to do it:
#
#   CMake Error at CMakeDetermineHIPCompiler.cmake:257
#     The ROCm root directory ... does not contain the HIP runtime
#     CMake package, expected at one of: .../hip-lang-config.cmake
#
# It cost a 12-minute build to find, immediately after the clang
# builtins cost one. Both are the same mistake: keep-toolchain means a
# toolchain that can actually build something, and these sweeps kept
# removing pieces of it on reasoning about the *runtime* images.
#
# They are a few MB, and `minimal` still drops them — that profile
# compiles nothing, which is what it is for.
if [ "${PROFILE}" = "minimal" ]; then
    rm -rf /opt/rocm/lib/cmake 2>/dev/null || true
fi

if [ "${PROFILE}" = "minimal" ]; then
    # Headers and the compiler front end, for an image that compiles
    # nothing. AITER JIT-compiles kernels on first use and Triton
    # shells out to the ROCm toolchain, so this is for `pytorch-run`
    # and not for the serving images.
    #
    # rm, deliberately, rather than purging amdrocm-llvm-dev. Removing
    # it with dpkg leaves amdrocm-core-dev10.1-<arch> — which we keep —
    # depending on something that is gone, and apt then refuses every
    # later operation, including in a downstream image where the error
    # mentions neither ROCm nor this script. Deleting the files does
    # not touch the package database at all.
    #
    # llvm/lib and llvm/amdgcn stay. The device bitcode libraries there
    # are what comgr and hipRTC load to finalise kernels at run time:
    # removing them produces an image that imports torch and then fails
    # at the first kernel launch.
    rm -rf /opt/rocm/include /opt/rocm/llvm/include \
           /opt/rocm/bin/hipcc /opt/rocm/bin/hipcc.pl \
           /opt/rocm/bin/hipify-perl /opt/rocm/bin/hipify-clang \
           2>/dev/null || true
else
    # keep-toolchain promises a toolchain that can actually link, and
    # the .a sweep above is one careless pattern away from breaking
    # that while leaving every binary in place. Assert it here rather
    # than discovering it from a downstream build: cupy-wheel compiles
    # a probe program during configure and died on exactly this, and
    # AITER's first-use JIT and Triton's ld.lld would have failed the
    # same way on a GPU host, hours later and further from the cause.
    if ! find "${ROCM_REAL}/lib/llvm/lib/clang" -name 'libclang_rt.builtins*.a' \
            -type f 2>/dev/null | grep -q .; then
        echo "rocm-prune: the clang builtins runtime is gone." >&2
        echo "  keep-toolchain cannot link without it; check the .a sweep." >&2
        exit 1
    fi
fi

# Deliberately NOT removed: amdrocm-rpp (image-processing primitives),
# amdrocm-rdc (the datacenter telemetry daemon) and amdrocm-rocshmem
# (a PGAS communication library). Nothing in this repo imports any of
# them and together they are about 1.1 GB — but each is a hard Depends
# of amdrocm-core10.1-<arch>, which we keep, so purging them leaves
# apt unusable in every downstream image. The consistency loop above
# cannot rescue that: the only way to satisfy it is to purge the arch
# core package itself, which is the one thing this script exists to
# preserve.
#
# Deleting their files while leaving the packages registered would
# work and is deliberately not done — a dpkg database that disagrees
# with the filesystem is a worse thing to hand downstream than 1.1 GB.
# Revisit if AMD ever makes these Recommends rather than Depends.

rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb 2>/dev/null || true

# ─── 5. Assert the architecture we kept is still there ───────────
# The failure this guards against is the expensive one: an image that
# builds, imports torch, and then has no kernels for the card it lands
# on — which surfaces hours later on a GPU host rather than here. Same
# reasoning as the offload-bundle check in Dockerfile.vllm.
for a in "${ARCHES[@]}"; do
    [ -n "${a}" ] || continue
    n=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -c -- "-${a}\$" || true)
    if [ "${n}" -eq 0 ]; then
        echo "rocm-prune: nothing left for ${a} — the keep list did not match" >&2
        exit 1
    fi
    echo "rocm-prune: kept ${n} package(s) for ${a}"
done

after=$(size_gb)
echo "rocm-prune: ${before}GB -> ${after}GB installed"
