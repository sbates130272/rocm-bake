#!/usr/bin/env bash
# Render the GitHub release notes for one emulator index.
#
# Usage: emu-release-notes.sh emu-gfx1151
#
# WHY GENERATED. There was one notes file shared by every emulator
# release, and the moment a second index appeared it started lying.
# It said "every latency in the profile pack was measured on an NVIDIA
# A40 ... placeholders until a capture on AMD hardware replaces them",
# which is true of the relabelled gfx1250 pack and false of the
# measured gfx1151 one -- so publishing it would have told readers the
# only real measurements in the lane were fake.
#
# So the claim is not written here at all. It is read out of the pack
# the release actually ships, from the rocm_bake_provenance block that
# exists to answer exactly this question. A pack that changes what it
# is changes its release notes with it, and nobody has to remember.
set -euo pipefail

ARCH="${1:?usage: emu-release-notes.sh emu-<gfx>}"
GFX="${ARCH#emu-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE="${SITE:-https://sbates130272.github.io/rocm-bake}"

shopt -s nullglob
PACKS=("${ROOT}"/docker/packs/"${GFX}"-*.json)
shopt -u nullglob
[ "${#PACKS[@]}" -eq 1 ] || {
    echo "emu-release-notes: expected one pack for ${GFX}, found ${#PACKS[@]}" >&2
    exit 1
}

read -r MEASURED DEVICE MODEL < <(python3 -I -c '
import json, sys
p = json.load(open(sys.argv[1]))
print(p["rocm_bake_provenance"].get("measured", False),
      p["model_config"]["gpu"]["gpu_name"].replace(" ", "_"),
      p.get("model_name", "?"))' "${PACKS[0]}")
DEVICE="${DEVICE//_/ }"

WARNING=$(python3 -I -c '
import json, sys, textwrap
p = json.load(open(sys.argv[1]))
print(textwrap.fill(p["rocm_bake_provenance"]["warning"], 76))' "${PACKS[0]}")

cat <<NOTES
An arch-free vLLM that serves without a GPU: vLLM built with no device
backend, plus [LLM-Emu](https://github.com/AKafakA/llm-emu), which replaces
the GPU forward pass with a latency draw from a captured profile pack. The
scheduler, batching, admission and HTTP stack are vLLM's own code.

This release emulates **${DEVICE}** (\`${GFX}\`) running \`${MODEL}\`.

PEP 503 index: ${SITE}/data/wheels/${ARCH}/

Install is two steps. The index pins no torch on purpose, because PyPI's
torch for Linux is the CUDA build:

    pip install --index-url https://download.pytorch.org/whl/cpu torch

    pip install --index-url ${SITE}/data/wheels/${ARCH}/ \\
        --extra-index-url https://pypi.org/simple \\
        "rocm-torch[device-${ARCH}]"

Then serve:

    VLLM_EMULATOR_ENABLE_ORACLE=1 VLLM_EMULATOR_MOCK_CUDA=1 \\
        vllm serve ${MODEL} --max-model-len 2048

## About the timings

$([ "${MEASURED}" = "True" ] \
    && echo "Measured on the device named above." \
    || echo "**Borrowed, not measured.**")

${WARNING}

## What these wheels are not

- **Not ROCm builds.** The release tag carries a ROCm version only because
  it shares publishing machinery with the per-card releases. Every wheel
  here is \`py3-none-any\` and contains no device code.
- **Not inference.** No weights are loaded and the output tokens are filler;
  there is no accuracy signal here, only timing and scheduling behaviour.
- **Not a benchmark of this repo's stack.** No kernel runs, so nothing here
  moves if AITER or Triton get faster.

Details: ${SITE}/architecture/emulation/
NOTES
