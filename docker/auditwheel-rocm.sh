#!/usr/bin/env bash
# Retag a freshly built wheel to the manylinux policy its own symbols
# allow, excluding everything the consuming image already provides.
#
# Usage:  auditwheel-rocm.sh RAW_DIR OUT_DIR [--allow-unrepaired]
#                            [-- EXTRA_AUDITWHEEL_ARGS...]
#
# WHY A SHARED SCRIPT. Five Dockerfiles need the same exclude list, and
# hand-maintaining it in five places is how it goes wrong: the first
# attempt at this listed a dozen ROCm libraries by name in
# Dockerfile.cupy and still missed librccl, libroctx64, libamd_smi,
# librocm-core, librocprofiler-register, libLLVM, libclang-cpp and the
# whole librocm_sysdeps_* family. auditwheel then tried to vendor and
# patch them, and patchelf died on librccl with
#
#     patchelf: section content is not naturally aligned
#
# The list should not be typed at all. Everything ROCm ships lives in
# the ROCm tree, so that is where the list comes from.
#
# WHY EXCLUDE AT ALL. A ROCm wheel is built against the ROCm in its
# base image and installed into an image that has the same ROCm. If
# auditwheel vendored those libraries, each wheel would carry its own
# copy of hipBLAS, RCCL and friends -- hundreds of MB apiece -- and at
# import time the vendored copy would shadow the runtime everything
# else in the image is using. Excluding them is not a shortcut around
# the manylinux rules; it is the same judgement download.pytorch.org
# makes for its own ROCm wheels.
#
# WHAT IS STILL CHECKED. Everything not excluded. auditwheel still
# refuses a wheel that depends on a too-new glibc, still vendors genuine
# third-party dependencies (libjpeg, libwebp, libz ...), and still picks
# the policy from the symbols rather than from a tag we assert. No
# --plat is passed anywhere, for that reason.
set -euo pipefail

RAW="${1:?usage: auditwheel-rocm.sh RAW_DIR OUT_DIR [--allow-unrepaired]}"
OUT="${2:?usage: auditwheel-rocm.sh RAW_DIR OUT_DIR [--allow-unrepaired]}"
shift 2

ALLOW_UNREPAIRED=0
EXTRA=()
while [ $# -gt 0 ]; do
    case "$1" in
        --allow-unrepaired) ALLOW_UNREPAIRED=1; shift ;;
        --) shift; EXTRA=("$@"); break ;;
        *) EXTRA=("$@"); break ;;
    esac
done

ROCM="${ROCM_PATH:-/opt/rocm}"
LOG=/wheels-auditwheel.txt

shopt -s nullglob
WHLS=("${RAW}"/*.whl)
shopt -u nullglob
[ "${#WHLS[@]}" -eq 1 ] || {
    echo "auditwheel-rocm: expected exactly one wheel in ${RAW}," \
         "found ${#WHLS[@]}" >&2
    exit 1
}
WHL="${WHLS[0]}"

# Every soname ROCm ships, reduced to its base name so one pattern
# covers libfoo.so, libfoo.so.1 and libfoo.so.1.2.3. `sort -u` because
# the same library appears under several version suffixes.
#
# The whole tree, not ${ROCM}/lib: ROCm 10.1 moved the runtime into a
# versioned subtree, so /opt/rocm/lib holds only per-component
# directories and the libraries themselves are at
# /opt/rocm/core-10.1/lib/libamdhip64.so.7 and similar. Globbing one
# fixed directory found nothing and the build failed here, which is the
# behaviour wanted -- but the fix is to stop assuming the layout.
mapfile -t ROCM_ALL < <(
    find "${ROCM}/" -name '*.so*' -printf '%f\n' 2>/dev/null | sort -u
)
[ "${#ROCM_ALL[@]}" -gt 0 ] || {
    echo "auditwheel-rocm: no shared libraries anywhere under ${ROCM} --" \
         "ROCM_PATH is wrong, or this is not a ROCm image" >&2
    exit 1
}

# ...but the ROCm tree is not only ROCm's own libraries, and excluding
# the rest would be a quiet lie. ROCm bundles ordinary third-party
# libraries under core-*/lib/rocm_sysdeps/lib (libzstd, libelf, libnuma,
# libbz2, libdw, libexpat, libgmp, libdrm ...) and core-*/lib/llvm/lib
# (libgomp, libomp, libiomp5). Sweeping those into --exclude tells
# auditwheel both "do not vendor this" AND "do not count it against the
# policy" -- so the wheel gets a manylinux tag while still needing a
# library no manylinux host is required to have. Measured: the first
# version of this script excluded libzstd.so.1, and the ATOM wheel came
# out tagged manylinux_2_38 while libmesh.so still needed libzstd from
# the host.
#
# The split is decided empirically rather than by another hand-written
# list, because a hand-written list is what produced the bug. If the
# system's own library path also provides the soname, it is a generic
# library that happens to be bundled, so auditwheel should vendor it
# normally. If only ROCm has it, it is ROCm's -- the consuming image is
# built FROM the same base and already provides it.
#
# Full sonames, NOT names with the version stripped. Stripping is what
# made the first attempt at this split wrong: the system ships
# libLLVM.so.21.1 and ROCm ships libLLVM.so.24.0git, which both reduce
# to "libLLVM", so ROCm's LLVM looked like a generic system library and
# would have been vendored -- a 100MB+ copy of the compiler inside the
# CuPy wheel. At full-soname granularity the two are correctly distinct,
# while libgomp.so.1 and libzstd.so.1 still match and stay vendorable.
SYSDIRS=(/usr/lib/x86_64-linux-gnu /usr/lib64 /lib/x86_64-linux-gnu /usr/lib)
mapfile -t SYS_LIBS < <(
    find "${SYSDIRS[@]}" -maxdepth 1 -name '*.so*' -printf '%f\n' \
        2>/dev/null | sort -u
)

declare -A IS_SYS=()
for lib in ${SYS_LIBS[@]+"${SYS_LIBS[@]}"}; do IS_SYS["${lib}"]=1; done

ROCM_LIBS=()
SHARED=()
for lib in "${ROCM_ALL[@]}"; do
    if [ -n "${IS_SYS[${lib}]:-}" ]; then SHARED+=("${lib}"); else ROCM_LIBS+=("${lib}"); fi
done

# torch's libraries are in site-packages, not the ROCm tree, and the
# same reasoning applies: the consuming image installs torch, and a
# second libtorch inside another wheel is a 300MB way to get two
# incompatible copies of the same ATen.
TORCH_LIBS=()
if torch_dir=$(python -c 'import torch,os;print(os.path.dirname(torch.__file__))' \
                   2>/dev/null); then
    mapfile -t TORCH_LIBS < <(
        find "${torch_dir}/lib" -maxdepth 1 -name '*.so*' -printf '%f\n' \
            2>/dev/null | sort -u
    )
fi

# Exact sonames. A trailing glob would reintroduce the libLLVM problem
# from the other direction: `--exclude libLLVM.so*` matches the system's
# libLLVM.so.21.1 as readily as ROCm's libLLVM.so.24.0git.
EXCLUDES=()
for lib in ${ROCM_LIBS[@]+"${ROCM_LIBS[@]}"} ${TORCH_LIBS[@]+"${TORCH_LIBS[@]}"}; do
    EXCLUDES+=(--exclude "${lib}")
done

{
    echo "=== auditwheel-rocm $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    echo "wheel:    $(basename "${WHL}")"
    echo "rocm:     ${ROCM} (${#ROCM_LIBS[@]} ROCm-only libraries excluded)"
    echo "shared:   ${#SHARED[@]} bundled libraries left for auditwheel to vendor"
    echo "torch:    ${#TORCH_LIBS[@]} libraries excluded"
    [ "${#EXTRA[@]}" -gt 0 ] && echo "extra:    ${EXTRA[*]}"
    echo "not excluded (vendored normally): ${SHARED[*]:-none}"
    echo
} | tee "${LOG}"

# `show` is diagnostic and is allowed to fail without taking the build
# with it; `repair` is not. Both are redirected rather than piped into
# tee, because a pipeline reports the exit status of its LAST command:
# `auditwheel repair ... | tee log` returns tee's 0 even when auditwheel
# died, which is how the first version of this silently shipped an
# unrepaired wheel.
auditwheel show "${WHL}" >>"${LOG}" 2>&1 || \
    echo "auditwheel show failed (diagnostic only)" >>"${LOG}"

mkdir -p "${OUT}"
if auditwheel repair "${EXCLUDES[@]}" ${EXTRA[@]+"${EXTRA[@]}"} \
        --wheel-dir "${OUT}" "${WHL}" >>"${LOG}" 2>&1; then
    cat "${LOG}"
    echo "auditwheel-rocm: repaired -> $(basename "$(echo "${OUT}"/*.whl)")"
    rm -rf "${RAW}"
    exit 0
fi

cat "${LOG}"
if [ "${ALLOW_UNREPAIRED}" = 1 ]; then
    # Deliberate fallback, and loud. The raw wheel keeps its honest
    # linux_x86_64 tag: shipping it is a smaller problem than shipping a
    # manylinux claim nothing verified. A Dockerfile only reaches here
    # by passing --allow-unrepaired, so this is a decision someone made
    # and wrote down, not a default.
    echo "auditwheel-rocm: repair FAILED; keeping the unrepaired wheel" >&2
    echo "auditwheel-rocm: it stays linux_x86_64 -- see ${LOG}" >&2
    mv "${WHL}" "${OUT}/"
    rm -rf "${RAW}"
    exit 0
fi

echo "auditwheel-rocm: repair failed for $(basename "${WHL}")" >&2
exit 1
