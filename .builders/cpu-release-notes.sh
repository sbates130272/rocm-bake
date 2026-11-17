#!/usr/bin/env bash
# Render the GitHub release notes for the cpu index.
#
# Usage: cpu-release-notes.sh [wheels-dir]      (default dist/wheels/cpu)
#
# Its own notes for the reason emu-release-notes.sh exists: the ones
# wheelpublish.sh generates describe a per-card ROCm build, and their
# one-line install cannot resolve this index. The vLLM wheel pins
# torch==X+cpu, which only PyTorch's CPU index carries.
#
# Every version below is read out of the wheels being published, the
# torch pin from the vLLM wheel's own metadata, so the install lines
# cannot disagree with the assets they sit beside.
set -euo pipefail

WHEELS="${1:-dist/wheels/cpu}"
SITE="${SITE:-https://sbates130272.github.io/rocm-bake}"
TORCH_INDEX="${CPU_TORCH_INDEX:-https://download.pytorch.org/whl/cpu}"

INFO=$(python3 -I -c '
import glob, os, re, sys, zipfile

def one(name):
    hits = sorted(glob.glob(os.path.join(sys.argv[1], name + "-*.whl")))
    if len(hits) != 1:
        sys.exit("cpu-release-notes: expected one %s wheel in %s, found %d"
                 % (name, sys.argv[1], len(hits)))
    return hits[0]

vllm, lmcache = one("vllm"), one("lmcache")
with zipfile.ZipFile(vllm) as z:
    meta = next(n for n in z.namelist() if n.endswith(".dist-info/METADATA"))
    text = z.read(meta).decode()
pins = re.findall(r"^Requires-Dist: torch==([^;\s]+)", text, re.M)
cpu = [p for p in pins if p.endswith("+cpu")]
if not cpu:
    sys.exit("cpu-release-notes: %s pins no torch==X+cpu (found %r)"
             % (os.path.basename(vllm), pins))
ver = lambda path: os.path.basename(path).split("-")[1]
print(ver(vllm), ver(lmcache), cpu[0], os.path.basename(vllm).split("-")[2])
' "${WHEELS}")
read -r VLLM LMCACHE TORCH PYTAG <<<"${INFO}"

cat <<NOTES
vLLM and LMCache built for CPU: real inference, with weights loaded and a
real forward pass, and no GPU or GPU runtime anywhere. vLLM ${VLLM} is built
with \`VLLM_TARGET_DEVICE=cpu\` and LMCache ${LMCACHE} without its GPU
extension, both against the CPU build of PyTorch. Linux x86_64, ${PYTAG}.

PEP 503 index: ${SITE}/data/wheels/cpu/

Install is two steps, with pip. torch comes first and from PyTorch's CPU
index, because PyPI's torch for Linux is the CUDA build:

    pip install --index-url ${TORCH_INDEX} "torch==${TORCH}"

    pip install --index-url ${SITE}/data/wheels/cpu/ \\
        --extra-index-url https://pypi.org/simple \\
        --extra-index-url ${TORCH_INDEX} \\
        "rocm-torch[device-cpu]"

The CPU index appears in the second step too, and it is not optional there:
the vLLM wheel requires \`torch==${TORCH}\` along with torchvision, torchaudio
and torchcodec, and their CPU builds are published nowhere else.

\`rocm-torch[device-cpu]\` pins \`vllm==${VLLM}\` and \`lmcache==${LMCACHE}\`.
Install through it or pin those two yourself: an unpinned \`vllm\` resolves
to PyPI's newer CUDA build instead.

## What these wheels are not

- **Not ROCm builds.** The \`rocm-torch\` metapackage name and the ROCm
  version in the release tag are here only because this release shares its
  publishing machinery with the per-card ones. Nothing in these wheels
  contains or needs ROCm.
- **Not a performance statement.** A small model on a CPU says nothing
  about how this repo's stack runs on a GPU.
- **Not installable with uv.** vLLM's CPU requirements name triton-cpu by
  direct URL. pip accepts that and fetches the wheel from github.com; uv
  rejects a URL dependency it was not given directly.

Details: ${SITE}/architecture/cpu/
NOTES
