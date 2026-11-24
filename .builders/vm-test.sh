#!/bin/bash
# vm-test.sh - serve a model through the published wheels, in a guest.
#
# Runs IN THE GUEST, not on the runner. .github/workflows/vm.yml boots
# a QEMU guest whose GPU is rocjitsu emulating a gfx1250
# (serving/vm-fleet.xml), copies this file and serving/vm-platform
# into it, and runs it there. Nothing is built: the wheels come from
# the public index with pip, which is the point. This is the only
# place the gfx1250 wheels are executed at all, because no machine we
# have carries that card.
#
# Five stages, named as .builders/vmsite.py names them. Two run:
#
#   install      the runtime package, the wheels, and torch computing
#                on the card
#   vllm         vLLM alone: /health, then one completion
#
# and three are recorded as skipped: lmcache, nixl-nvme, nixl-nvmeof.
# They are the plan, and the fleet already carries the NVMe and the
# NVMe-oF target they need, but each stands on vLLM serving and that
# has not been seen to happen on this card yet. Writing them first
# would be three stages nobody has run on top of one nobody has passed.
#
# A summary is written whatever happens, to ${OUT}/summary.json, and
# the exit status is 1 if any stage failed. A check that fails stops
# its own stage, not the script: the stage after a failed one is
# recorded as not run, so the page shows where it stopped.
#
# Usage, in the guest:  ./vm-test.sh
#
# Env:
#   ARCH             gfx1250. The emulator models no other generation.
#   INDEX_URL        the pip index the wheels are installed from
#   MODEL            a model small enough for 1 GiB of emulated VRAM
#   STAGES           which of the stages to run (default: install vllm)
#   STARTUP_TIMEOUT  seconds vLLM may take to answer /health
#   GPU_UTIL         vLLM's --gpu-memory-utilization (default 0.8)
#   VLLM_EXTRA_ARGS  further flags for `vllm serve`, space separated
#   OUT              where logs and summary.json go (default: ./out)
#   RUN_URL, RUN_SHA, QEMU_TOOL   recorded in the summary, not used

set -uo pipefail

ARCH="${ARCH:-gfx1250}"
ROCM_SERIES="${ROCM_SERIES:-10.2}"
INDEX_URL="${INDEX_URL:-https://sbates130272.github.io/rocm-bake/data/wheels/rocm${ROCM_SERIES}/${ARCH}/}"
MODEL="${MODEL:-nickypro/tinyllama-15M}"
CTX="${CTX:-256}"
STAGES="${STAGES:-install vllm}"
GPU_UTIL="${GPU_UTIL:-0.8}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-1500}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-900}"
PORT="${PORT:-8000}"
VENV="${VENV:-${HOME}/venv}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-${HERE}/out}"

ALL_STAGES="install vllm lmcache nixl-nvme nixl-nvmeof"

# The runtime's libraries are not on the loader's path in the guest
# image, and torch's own are linked against them: without this the
# import dies on libroctx64.so.4.
export LD_LIBRARY_PATH="/opt/rocm/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
# hipBLASLt's gfx1250 kernels give wrong results on the A0 stepping the
# emulator presents, and the library it wants for that stepping
# (gfx1250v0) is not in the runtime package. With this set, a GEMM on
# the card matches the CPU's.
export TORCH_BLAS_PREFER_HIPBLASLT=0

mkdir -p "${OUT}/stages"

say() { printf '\n== %s\n' "$*"; }
now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }'; }
# One line, no tabs: these go into a tab-separated file.
flat() { printf '%s' "$*" | tr '\t\n' '  ' | cut -c1-300; }

STAGE=""
begin() {
    STAGE="$1"
    mkdir -p "${OUT}/stages/${STAGE}"
    : > "${OUT}/stages/${STAGE}/checks.tsv"
    : > "${OUT}/stages/${STAGE}/metrics.tsv"
    say "stage ${STAGE}"
}
# check <pass|fail|skip> <name> [detail]
check() {
    printf '%s\t%s\t%s\n' "$1" "$(flat "$2")" "$(flat "${3:-}")" \
        >> "${OUT}/stages/${STAGE}/checks.tsv"
    printf '  %-4s %s%s\n' "$1" "$2" "${3:+: $3}"
}
metric() { printf '%s\t%s\n' "$1" "$2" >> "${OUT}/stages/${STAGE}/metrics.tsv"; }
failed() { grep -q '^fail' "${OUT}/stages/$1/checks.tsv" 2>/dev/null; }
wanted() { case " ${STAGES} " in *" $1 "*) return 0 ;; esac; return 1; }
skip_stage() { begin "$1"; check skip "$2" "${3:-}"; }
# The log it is redirected into belongs to this user, not to root.
apt() { sudo DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

# Take the translator's diagnostics out of a server log.
#
# Every code object the runtime loads goes through the guest's gfx1250
# B0-to-A0 translator, which prints one line per block it had to
# legalize. The first run on a hosted runner wrote 7,077 of them into a
# 7,436-line vllm.log, and the one line that said why the engine had
# stopped was in the other 359.
#
# Not thrown away: they are counted here, and a digest of the distinct
# ones is kept beside the log, because a count that moves between two
# builds is a statement about the kernels in our wheels.
# The exceptions a server log names, each once, in the order raised.
#
# In that order because the last one is vLLM's wrapper -- "Engine core
# initialization failed. See root cause above" -- and the first is the
# root cause it means. import_utils.py is left out: vLLM probes for a
# CUDA nixl_ep on every start, fails, warns and carries on.
errors_in() {
    grep -aE '(Error|Exception): ' "$1" 2> /dev/null \
        | grep -av 'import_utils.py' \
        | sed -E 's/^\([A-Za-z]+ pid=[0-9]+\) [A-Z]+ [0-9-]+ [0-9:]+ \[[^]]+\] //' \
        | awk '!seen[$0]++' | cut -c1-400
}

TRANSLATOR_RE='^\[hsa-hotswap-rj\] warning: translation diagnostic'
quiet_log() {
    local log="$1" digest="${1%.log}.translator.txt" n
    [ -s "${log}" ] || return 0
    n=$(grep -acE "${TRANSLATOR_RE}" "${log}" || true)
    metric translator_warnings "${n:-0}"
    [ "${n:-0}" -gt 0 ] || return 0
    grep -aE "${TRANSLATOR_RE}" "${log}" \
        | sed -E 's/ source_id=[^ ]+//; s/ guest_offset=[^ ]+//' \
        | sort | uniq -c | sort -rn > "${digest}"
    grep -avE "${TRANSLATOR_RE}" "${log}" > "${log}.tmp"
    mv "${log}.tmp" "${log}"
    echo "  ${n} translator diagnostics moved to $(basename "${digest}")"
}

stage_install() {
    begin install
    local t0 t1 log purelib
    t0=$(now)
    log="${OUT}/install.log"
    : > "${log}"

    # The guest image has the ROCm runtime but not the per-architecture
    # half of it, which is where the libraries torch links against
    # live. A stale package list is not worth failing on: the install
    # below says so if the package cannot be found.
    apt update -q >> "${log}" 2>&1 || true
    if apt install -y -q --no-install-recommends \
            "amdrocm-core${ROCM_SERIES}-${ARCH}" >> "${log}" 2>&1; then
        check pass "ROCm runtime" "amdrocm-core${ROCM_SERIES}-${ARCH}"
    else
        check fail "ROCm runtime" "$(tail -n 1 "${log}")"
        metric seconds "$(since "${t0}")"
        return
    fi

    # uv, for the interpreter as much as the install: the wheels are
    # cp314, and uv fetches a 3.14 when the guest has none.
    if ! command -v uv > /dev/null 2>&1; then
        pipx install uv >> "${log}" 2>&1 || true
        export PATH="${HOME}/.local/bin:${PATH}"
    fi
    if ! command -v uv > /dev/null 2>&1; then
        check fail "uv" "not in the guest image, and pipx could not install it"
        metric seconds "$(since "${t0}")"
        return
    fi

    # --index-strategy: uv takes each name from the first index that
    # lists it and looks no further, and torch, vllm and nixl are names
    # PyPI lists too. The metapackage pins each of ours exactly, with a
    # local version PyPI cannot match, so considering every index can
    # only ever satisfy those pins from ours.
    t1=$(now)
    if uv venv -q --python 3.14 "${VENV}" >> "${log}" 2>&1 \
        && uv pip install --python "${VENV}/bin/python" \
            --index-url "${INDEX_URL}" \
            --extra-index-url https://pypi.org/simple \
            --index-strategy unsafe-best-match \
            "rocm-torch[device-${ARCH}]" >> "${log}" 2>&1; then
        check pass "pip install rocm-torch[device-${ARCH}]" \
            "$(grep -c '^ + ' "${log}") packages in $(since "${t1}")s"
    else
        check fail "pip install rocm-torch[device-${ARCH}]" \
            "$(grep -m1 -i 'error' "${log}" || tail -n 1 "${log}")"
        metric seconds "$(since "${t0}")"
        return
    fi

    # vLLM's ROCm platform layer imports amdsmi to enumerate devices.
    # The runtime ships it as a bare directory with no packaging,
    # outside any site-packages, so it is put on the path here, as
    # docker/Dockerfile.vllm does for the serving image.
    purelib=$("${VENV}/bin/python" -c \
        'import sysconfig; print(sysconfig.get_paths()["purelib"])')
    if [ -d /opt/rocm/share/amd_smi ]; then
        printf '/opt/rocm/share/amd_smi\n' > "${purelib}/rocm-amdsmi.pth"
    fi

    # The platform shim; see serving/vm-platform/rocm_bake_vm/__init__.py.
    if uv pip install --python "${VENV}/bin/python" --no-deps \
            "${HERE}/vm-platform" >> "${log}" 2>&1; then
        check pass "platform shim" "rocm-bake-vm-platform"
    else
        check fail "platform shim" "$(tail -n 1 "${log}")"
    fi

    "${VENV}/bin/python" - > "${OUT}/versions.json" 2> /dev/null << 'EOF'
import json
from importlib import metadata

out = {}
for name in ("rocm-torch", "torch", "torchvision", "triton", "amd-aiter",
             "nixl", "lmcache", "vllm"):
    try:
        out[name] = metadata.version(name)
    except metadata.PackageNotFoundError:
        pass
print(json.dumps(out))
EOF

    # Arithmetic, not is_available(): the card answering and the card
    # computing are different claims, and on an emulator the second is
    # the one that fails.
    if "${VENV}/bin/python" - > "${OUT}/guest.json" 2> "${OUT}/torch.err" << 'EOF'
import json

import torch

assert torch.cuda.is_available(), "torch sees no GPU"
a = torch.randn(64, 64)
on_card = (a.cuda() @ a.cuda()).cpu()
err = float((on_card - a @ a).abs().max())
assert err < 1e-2, f"a 64x64 GEMM on the card is {err} from the CPU's"
_, total = torch.cuda.mem_get_info()
print(json.dumps({"gpu": torch.cuda.get_device_name(0),
                  "vram_mb": total // 2 ** 20}))
EOF
    then
        check pass "torch computes on the card" "$(flat "$(cat "${OUT}/guest.json")")"
    else
        check fail "torch computes on the card" \
            "$(tail -n 1 "${OUT}/torch.err")"
        rm -f "${OUT}/guest.json"
    fi
    metric seconds "$(since "${t0}")"
}

stage_vllm() {
    begin vllm
    local t0 t1 pid deadline up="" body n dt extra=()
    t0=$(now)
    read -r -a extra <<< "${VLLM_EXTRA_ARGS:-}"

    # ATOM_DISABLE_VLLM_PLUGIN: the metapackage installs ATOM, whose
    #   vLLM plugin ships disabled in our own image for the reasons in
    #   docs/architecture/atom-vllm-skew.md. A pip install has no ENV.
    # ROCM_BAKE_VM_PLATFORM: arms the shim installed above.
    # One sequence, a short context and eager mode: the card has 1 GiB
    #   and every kernel it runs is interpreted, so graph capture and a
    #   second sequence are minutes this cannot spend.
    # --disable-extensible-kv-cache: vLLM 0.34 turns that cache on by
    #   default, and it cannot work on this card at any setting. (The
    #   release notes spell the flag --no-enable-...; `vllm serve
    #   --help=all` in the installed 0.34.0 lists this one.) It
    #   keeps a margin free whose floor on ROCm is 3 GiB
    #   (KV_CACHE_MARGIN_FLOOR_BYTES in v1/worker/extensible_kv_cache.py)
    #   and the card has 1, so the cache is given nothing: two hosted
    #   runs loaded the model, warmed up and then stopped on "No
    #   available memory for the cache blocks", at utilisation 1.0 and
    #   at 0.8 alike.
    # --gpu-memory-utilization: needed once that cache is off. The
    #   default is then 0.92, and 0.12 GiB of the card is taken before
    #   vLLM starts, so the engine refuses at startup with "free memory
    #   (0.88/1.0 GiB) is less than desired".
    #
    # setsid, so the engine process vLLM starts can be stopped with it.
    ATOM_DISABLE_VLLM_PLUGIN=1 ROCM_BAKE_VM_PLATFORM=1 \
    PYTHONFAULTHANDLER=1 HF_HOME="${HOME}/hf" \
        setsid nohup "${VENV}/bin/vllm" serve "${MODEL}" \
            --host 127.0.0.1 --port "${PORT}" \
            --max-model-len "${CTX}" --max-num-batched-tokens "${CTX}" \
            --max-num-seqs 1 --enforce-eager --dtype float16 \
            --disable-extensible-kv-cache \
            --gpu-memory-utilization "${GPU_UTIL}" \
            "${extra[@]}" > "${OUT}/vllm.log" 2>&1 &
    pid=$!

    deadline=$((SECONDS + STARTUP_TIMEOUT))
    while :; do
        if curl -fsS -m 5 "http://127.0.0.1:${PORT}/health" > /dev/null 2>&1; then
            up=1
            break
        fi
        kill -0 "${pid}" 2> /dev/null || break
        [ "${SECONDS}" -lt "${deadline}" ] || break
        sleep 10
    done

    if [ -n "${up}" ]; then
        metric startup_s "$(since "${t0}")"
        check pass "/health" "after $(since "${t0}")s"

        t1=$(now)
        body=$(curl -fsS -m "${REQUEST_TIMEOUT}" \
            "http://127.0.0.1:${PORT}/v1/completions" \
            -H 'Content-Type: application/json' \
            -d "{\"model\": \"${MODEL}\", \"prompt\": \"Once upon a time\", \"max_tokens\": 16, \"temperature\": 0}" \
            2> "${OUT}/completion.err")
        dt=$(since "${t1}")
        printf '%s\n' "${body}" > "${OUT}/completion.json"
        n=$(python3 -c \
            'import json, sys; print(json.load(sys.stdin)["usage"]["completion_tokens"])' \
            < "${OUT}/completion.json" 2> /dev/null || echo 0)
        if [ "${n:-0}" -gt 0 ]; then
            check pass "completion" "${n} tokens in ${dt}s"
            # End to end, so the short prompt's prefill is in it.
            metric decode_tps "$(awk -v n="${n}" -v s="${dt}" \
                'BEGIN { printf "%.3f", (s > 0) ? n / s : 0 }')"
        else
            check fail "completion" \
                "$(cat "${OUT}/completion.err" "${OUT}/completion.json" 2> /dev/null)"
        fi
    elif kill -0 "${pid}" 2> /dev/null; then
        body=$(errors_in "${OUT}/vllm.log" | head -n 1)
        check fail "/health" "no answer in ${STARTUP_TIMEOUT}s, server still running: ${body:-no error in its log}"
    else
        check fail "/health" "server exited after $(since "${t0}")s: $(errors_in "${OUT}/vllm.log" | head -n 1)"
    fi

    # The whole session, then without asking: a server that would not
    # start is often one that will not stop either.
    kill -TERM -- "-${pid}" 2> /dev/null || kill -TERM "${pid}" 2> /dev/null || true
    for _ in $(seq 1 30); do
        kill -0 "${pid}" 2> /dev/null || break
        sleep 1
    done
    kill -KILL -- "-${pid}" 2> /dev/null || true
    metric seconds "$(since "${t0}")"

    quiet_log "${OUT}/vllm.log"
    # The cause of a failed start is in the server's log and nowhere
    # else, and the step log is the first place anyone looks.
    if failed vllm; then
        echo "  --- errors in vllm.log, first raised first ---"
        errors_in "${OUT}/vllm.log" | sed 's/^/  /'
    fi
}

if wanted install; then
    stage_install
else
    skip_stage install "not selected"
fi

if ! wanted vllm; then
    skip_stage vllm "not selected"
elif failed install || [ ! -x "${VENV}/bin/vllm" ]; then
    skip_stage vllm "not run" "the install stage left no vllm to start"
else
    stage_vllm
fi

for s in lmcache nixl-nvme nixl-nvmeof; do
    skip_stage "${s}" "not written yet" \
        "follows vLLM alone, which has not yet served on this card"
done

say "summary"
ALL_STAGES="${ALL_STAGES}" ARCH="${ARCH}" INDEX_URL="${INDEX_URL}" \
MODEL="${MODEL}" KERNEL="$(uname -r)" VCPUS="$(nproc)" \
MEM_MB="$(free -m | awk '/^Mem:/ { print $2 }')" \
RUN_URL="${RUN_URL:-}" RUN_SHA="${RUN_SHA:-}" QEMU_TOOL="${QEMU_TOOL:-}" \
    python3 - "${OUT}" << 'EOF'
import json
import os
import sys

out = sys.argv[1]
env = os.environ


def load(name):
    try:
        with open(os.path.join(out, name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def number(text):
    for kind in (int, float):
        try:
            return kind(text)
        except ValueError:
            pass
    return text


def rows(stage, name):
    try:
        with open(os.path.join(out, "stages", stage, name)) as f:
            return [line.rstrip("\n").split("\t") for line in f if line.strip()]
    except OSError:
        return []


stages = []
for stage in env["ALL_STAGES"].split():
    checks = [{"result": r[0], "name": r[1], "detail": r[2] if len(r) > 2 else ""}
              for r in rows(stage, "checks.tsv")]
    seen = {c["result"] for c in checks}
    result = "fail" if "fail" in seen else "pass" if "pass" in seen else "skip"
    stages.append({
        "name": stage,
        "result": result,
        "metrics": {r[0]: number(r[1]) for r in rows(stage, "metrics.tsv")
                    if len(r) == 2},
        "checks": checks,
    })
    print(f"  {result:4} {stage}")

versions = load("versions.json")
guest = load("guest.json")
guest.update(kernel=env["KERNEL"], vcpus=number(env["VCPUS"]),
             mem_mb=number(env["MEM_MB"]))

summary = {
    "schema": 1,
    "arch": env["ARCH"],
    "rocm_torch": versions.pop("rocm-torch", None),
    "index": env["INDEX_URL"],
    "model": env["MODEL"],
    "guest": guest,
    "versions": versions,
    "qemu_tool": env["QEMU_TOOL"] or None,
    "run": {"url": env["RUN_URL"] or None, "sha": env["RUN_SHA"] or None},
    "stages": stages,
}
with open(os.path.join(out, "summary.json"), "w") as f:
    json.dump(summary, f, indent=2)
    f.write("\n")

sys.exit(1 if any(s["result"] == "fail" for s in stages) else 0)
EOF
