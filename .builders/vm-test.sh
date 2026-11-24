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

# LMCache stores whole chunks and never a partial one, so the shared
# prefix below has to span several. The serving stack uses 256 tokens;
# 64 here, because every token of that prefix is prefilled twice on a
# GPU that interprets its own instructions, and three 64-token chunks
# prove the same thing as three 256-token ones.
CHUNK_SIZE="${CHUNK_SIZE:-64}"
L1_SIZE_GB="${L1_SIZE_GB:-1}"
LMCACHE_PORT="${LMCACHE_PORT:-5555}"
LMCACHE_API_PORT="${LMCACHE_API_PORT:-8080}"
# Words, not tokens, and deliberately more than CHUNK_SIZE tokens'
# worth: a prefix shorter than one chunk is never stored, and the
# stage would then fail against a working cache.
PREFIX_WORDS="${PREFIX_WORDS:-200}"
GPU_UTIL="${GPU_UTIL:-0.8}"
# Per ATTEMPT, not for the stage. An engine that is going to come up
# does so in 47-97s in a guest on snoc-strix and in 300-350s on a
# hosted runner, which has fewer and slower cores; one that is stuck
# sits past 1500s. 600 is above every start that has worked and well
# below every stall, so it separates the two rather than timing a
# slow one out.
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-600}"
# A stuck start is not retried in hope: it has a signature, and
# restarting the engine clears it. Measured 2026-11-24, sampling a
# start every 20s from the host:
#
#   ELAPSED   QEMU%   ROCJITSU%   DIAGS  HEALTH
#        2s  104.72%    100.27%     781       -
#       25s  107.92%      0.01%     781       -   <- stuck
#       47s   15.06%    100.37%    7077      UP
#
# The guest spins a core while the emulator is idle and the
# translator's diagnostic count is frozen at 781; a start that clears
# it walks that count to 7077. The state lasted 20s here and has
# lasted past 1500s elsewhere, on roughly 1 start in 8 on this node
# and 1 hosted run in 5. Nothing we pass changes its odds, so the
# stage takes another engine instead of failing the run.
SERVE_ATTEMPTS="${SERVE_ATTEMPTS:-2}"
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

# Put the NIXL runtime where lmcache_nixl can find it.
#
# WORKAROUND, and the bug is ours. The published lmcache wheel's
# lmcache_nixl extension is linked with an absolute RPATH from the
# container that built it:
#
#   RPATH:  /opt/venv/lib/python3.14/site-packages/.nixl_rocm.mesonpy.libs
#   NEEDED: libnixl.so
#
# The image's venv is at /opt/venv, so it resolves there and every
# image-based test passes. Installed into a venv anywhere else, which
# is how a user installs it, the import fails with "libnixl.so: cannot
# open shared object file". The library is present, under the nixl
# package's own directory; only the path is wrong. Measured against
# lmcache 0.5.8+rocm10.2.0 on 2026-11-24.
#
# The fix belongs in docker/Dockerfile.lmcache, making that RPATH
# $ORIGIN-relative. Until then this makes the NIXL tiers reachable
# here. Harmless when the directory is absent.
add_nixl_libs() {
    local d
    for d in "${VENV}"/lib/python*/site-packages/.nixl_rocm.mesonpy.libs; do
        [ -d "${d}" ] || continue
        case ":${LD_LIBRARY_PATH}:" in
            *":${d}:"*) ;;
            *) export LD_LIBRARY_PATH="${d}:${LD_LIBRARY_PATH}" ;;
        esac
    done
}

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

# ─── the server, shared by the stages that need one ──────────────
#
# Each stage starts its own and stops it again, rather than one server
# for the run: a stage that cannot start the engine then fails alone
# instead of taking every stage after it, and the page says which.
SERVE_PID=""

# serve_up <log> [extra vllm args...] -> 0 once /health answers.
#
# Up to SERVE_ATTEMPTS engines, each given STARTUP_TIMEOUT. A stuck
# one is killed and the next tried; a crashed one is not, because an
# engine that exits has said why and retrying would only bury it.
# Each failed attempt's log is kept beside the live one as
# <log>.attempt<n>, so a run that needed a retry can still be read.
SERVE_ATTEMPT=0
# Why the last attempt failed: stuck (no /health, still running) or
# exited. Read by the stages, because serve_down has cleared SERVE_PID
# by the time they look and a dead pid reads as "exited" either way.
SERVE_FAIL=""
serve_up() {
    local log="$1" n
    shift
    SERVE_FAIL=""
    for n in $(seq 1 "${SERVE_ATTEMPTS}"); do
        SERVE_ATTEMPT="${n}"
        if [ "${n}" -gt 1 ]; then
            mv -f "${log}" "${log}.attempt$(( n - 1 ))" 2> /dev/null || true
            echo "  engine did not answer in ${STARTUP_TIMEOUT}s; attempt ${n} of ${SERVE_ATTEMPTS}"
        fi
        serve_once "${log}" "$@"
        case $? in
            0) SERVE_FAIL=""; return 0 ;;
            # Exited on its own: errors_in has the reason, so stop.
            2) SERVE_FAIL="exited"; return 1 ;;
            *) SERVE_FAIL="stuck" ;;
        esac
        serve_down
    done
    return 1
}

# serve_once <log> [args...] -> 0 healthy, 1 stuck, 2 exited
serve_once() {
    local log="$1" deadline
    shift
    local extra=()
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
    # VLLM_SERVER_DEV_MODE: exposes /reset_prefix_cache, which the
    #   lmcache stage needs to empty VRAM between its two requests.
    #   Without it vLLM answers the second from its own prefix cache
    #   and LMCache is never asked -- which reads as "stored but
    #   served none". See the same note in serving/docker-compose.yml.
    #
    # setsid, so the engine process vLLM starts can be stopped with it.
    ATOM_DISABLE_VLLM_PLUGIN=1 ROCM_BAKE_VM_PLATFORM=1 \
    VLLM_SERVER_DEV_MODE=1 \
    PYTHONFAULTHANDLER=1 HF_HOME="${HOME}/hf" \
        setsid nohup "${VENV}/bin/vllm" serve "${MODEL}" \
            --host 127.0.0.1 --port "${PORT}" \
            --max-model-len "${CTX}" --max-num-batched-tokens "${CTX}" \
            --max-num-seqs 1 --enforce-eager --dtype float16 \
            --disable-extensible-kv-cache \
            --gpu-memory-utilization "${GPU_UTIL}" \
            "$@" "${extra[@]}" > "${log}" 2>&1 &
    SERVE_PID=$!

    deadline=$((SECONDS + STARTUP_TIMEOUT))
    while :; do
        curl -fsS -m 5 "http://127.0.0.1:${PORT}/health" > /dev/null 2>&1 \
            && return 0
        kill -0 "${SERVE_PID}" 2> /dev/null || return 2
        [ "${SECONDS}" -lt "${deadline}" ] || return 1
        sleep 10
    done
}

# The whole session, then without asking: a server that would not
# start is often one that will not stop either.
serve_down() {
    [ -n "${SERVE_PID}" ] || return 0
    kill -TERM -- "-${SERVE_PID}" 2> /dev/null \
        || kill -TERM "${SERVE_PID}" 2> /dev/null || true
    for _ in $(seq 1 30); do
        kill -0 "${SERVE_PID}" 2> /dev/null || break
        sleep 1
    done
    kill -KILL -- "-${SERVE_PID}" 2> /dev/null || true
    # Reaped here rather than asynchronously, or bash announces the
    # kill by printing the whole `vllm serve` command line into the
    # middle of the stage output.
    wait "${SERVE_PID}" 2> /dev/null || true
    SERVE_PID=""
}

stage_vllm() {
    begin vllm
    local t0 t1 up="" body n dt
    t0=$(now)

    if serve_up "${OUT}/vllm.log"; then
        up=1
    fi

    if [ -n "${up}" ]; then
        local note=""
        [ "${SERVE_ATTEMPT}" -gt 1 ] \
            && note=", on engine ${SERVE_ATTEMPT} of ${SERVE_ATTEMPTS}"
        metric startup_s "$(since "${t0}")"
        metric serve_attempts "${SERVE_ATTEMPT}"
        check pass "/health" "after $(since "${t0}")s${note}"

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
    elif [ "${SERVE_FAIL}" = stuck ]; then
        body=$(errors_in "${OUT}/vllm.log" | head -n 1)
        check fail "/health" "${SERVE_ATTEMPTS} engine(s), each stuck past ${STARTUP_TIMEOUT}s: ${body:-no error logged, so the guest-side translator hang}"
    else
        check fail "/health" "server exited after $(since "${t0}")s: $(errors_in "${OUT}/vllm.log" | head -n 1)"
    fi

    serve_down
    metric seconds "$(since "${t0}")"

    quiet_log "${OUT}/vllm.log"
    # The cause of a failed start is in the server's log and nowhere
    # else, and the step log is the first place anyone looks.
    if failed vllm; then
        echo "  --- errors in vllm.log, first raised first ---"
        errors_in "${OUT}/vllm.log" | sed 's/^/  /'
    fi
}

# A prefix no previous run has seen. A fixed one would already be in
# the store from the run before, so the "cold" request would be warm
# and the comparison would show nothing. Prose-shaped, because a
# tokenizer turns random characters into far more tokens than words
# and the prompt length would stop being predictable.
new_prefix() {
    "${VENV}/bin/python" - "${PREFIX_WORDS}" << 'EOF'
import random
import string
import sys

words = ["cache", "tensor", "kernel", "stream", "block", "offload",
         "prefix", "token", "layer", "device", "memory", "engine"]
tag = "".join(random.choices(string.ascii_lowercase, k=8))
print(f"Document {tag}. " + " ".join(random.choices(words, k=int(sys.argv[1]))))
EOF
}

# One completion, max_tokens=1, timed. Decode then rounds to nothing
# and what is measured is almost entirely prefill -- the only part a
# KV cache can make cheaper.
#
# Results come back in globals rather than on stdout. A $(timed_prefill)
# would run the whole thing in a subshell, where the HTTP status it
# records is set and then thrown away with that subshell -- which it
# did, until `set -u` caught the empty variable in the caller.
PREFILL_CODE=""
PREFILL_SECONDS=""
timed_prefill() {
    local t0
    t0=$(now)
    PREFILL_CODE=$(curl -s -o "${OUT}/lmcache-reply.json" -w '%{http_code}' \
        -m "${REQUEST_TIMEOUT}" "http://127.0.0.1:${PORT}/v1/completions" \
        -H 'Content-Type: application/json' \
        --data-binary @- << EOF
{"model": "${MODEL}", "prompt": $(printf '%s' "$1" | "${VENV}/bin/python" -c 'import json,sys; print(json.dumps(sys.stdin.read()))'), "max_tokens": 1, "temperature": 0}
EOF
    )
    PREFILL_SECONDS=$(since "${t0}")
}

stage_lmcache() {
    begin lmcache
    local t0 lm_pid prefix cold warm hits_before hits_after reset stored got nokey body
    t0=$(now)
    add_nixl_libs

    # The MP server first: vLLM's connector dials it at engine start
    # and the engine does not come up without it.
    #
    # L1 only here (no --l2-adapter), which is the serving stack's
    # KV_TIER=cpu. The L2 tiers are the nixl-* stages below.
    HSA_ENABLE_IPC_MODE_LEGACY=1 \
        setsid nohup "${VENV}/bin/lmcache" server \
            --host 127.0.0.1 --port "${LMCACHE_PORT}" \
            --l1-size-gb "${L1_SIZE_GB}" \
            --chunk-size "${CHUNK_SIZE}" \
            --transport zmq \
            --supported-transfer-mode lmcache_driven \
            --eviction-policy LRU > "${OUT}/lmcache.log" 2>&1 &
    lm_pid=$!

    for _ in $(seq 1 30); do
        curl -fsS -m 5 "http://127.0.0.1:${LMCACHE_API_PORT}/healthcheck" \
            > /dev/null 2>&1 && break
        sleep 5
    done
    if curl -fsS -m 5 "http://127.0.0.1:${LMCACHE_API_PORT}/healthcheck" \
            > /dev/null 2>&1; then
        check pass "lmcache server" "zmq :${LMCACHE_PORT}, chunk ${CHUNK_SIZE}, L1 ${L1_SIZE_GB}GB"
    else
        check fail "lmcache server" \
            "no healthcheck in 150s: $(errors_in "${OUT}/lmcache.log" | head -n 1)"
        kill -KILL -- "-${lm_pid}" 2> /dev/null || true
        metric seconds "$(since "${t0}")"
        return
    fi

    # lmcache.mp.use_vmm_api=false is required from LMCache v0.5.8rc1
    # on vLLM v0.34.0: LMCache #6499 made fd-exported KV memory the
    # default, and v0.34.0 refuses that on ROCm, raising on VllmConfig
    # before it serves anything. False makes the connector answer
    # LEGACY_IPC instead, which is also why HSA_ENABLE_IPC_MODE_LEGACY
    # is set. The whole reasoning is in serving/docker-compose.yml.
    if HSA_ENABLE_IPC_MODE_LEGACY=1 serve_up "${OUT}/vllm-lmcache.log" \
            --disable-hybrid-kv-cache-manager \
            --kv-transfer-config \
            "{\"kv_connector\":\"LMCacheMPConnector\",\"kv_role\":\"kv_both\",\"kv_connector_extra_config\":{\"lmcache.mp.host\":\"tcp://127.0.0.1\",\"lmcache.mp.port\":${LMCACHE_PORT},\"lmcache.mp.use_vmm_api\":false}}"
    then
        metric startup_s "$(since "${t0}")"
        check pass "vLLM with the MP connector" "/health after $(since "${t0}")s"
    else
        body=$(errors_in "${OUT}/vllm-lmcache.log" | head -n 1)
        check fail "vLLM with the MP connector" \
            "${body:-${SERVE_ATTEMPTS} engine(s), each stuck past ${STARTUP_TIMEOUT}s}"
        serve_down
        kill -KILL -- "-${lm_pid}" 2> /dev/null || true
        quiet_log "${OUT}/vllm-lmcache.log"
        metric seconds "$(since "${t0}")"
        return
    fi

    prefix=$(new_prefix)
    timed_prefill "${prefix}"
    cold="${PREFILL_SECONDS}"
    if [ "${PREFILL_CODE}" = 200 ]; then
        check pass "first prefill" "${cold}s (stores the prefix)"
        metric computed_s "${cold}"
    else
        check fail "first prefill" \
            "HTTP ${PREFILL_CODE}: $(head -c 200 "${OUT}/lmcache-reply.json")"
    fi

    # Empty vLLM's own GPU prefix cache, or the second request is
    # served from VRAM and proves nothing about LMCache.
    hits_before=$(curl -fsS -m 10 "http://127.0.0.1:${PORT}/metrics" 2>/dev/null \
        | awk '/^vllm:prefix_cache_hits_total/ { print $2; exit }')
    if curl -fsS -m 30 -X POST "http://127.0.0.1:${PORT}/reset_prefix_cache" \
            -o /dev/null 2>/dev/null; then
        reset=yes
    else
        reset=no
    fi

    # Same prefix, different tail: the shared prefix is what should
    # come from the cache, and changing the tail proves the hit is a
    # real prefix match rather than a whole-response cache.
    timed_prefill "${prefix} Answer briefly."
    warm="${PREFILL_SECONDS}"
    hits_after=$(curl -fsS -m 10 "http://127.0.0.1:${PORT}/metrics" 2>/dev/null \
        | awk '/^vllm:prefix_cache_hits_total/ { print $2; exit }')
    [ "${PREFILL_CODE}" = 200 ] && metric cached_s "${warm}"

    if [ "${reset}" = yes ]; then
        check pass "/reset_prefix_cache" \
            "vLLM prefix hits ${hits_before:-?} -> ${hits_after:-?}"
    else
        check skip "/reset_prefix_cache" \
            "absent, so the timing below cannot be attributed to LMCache"
    fi

    serve_down
    sleep 5

    # Ask LMCache, not the clock. The timing above can be moved by
    # vLLM's own caching; these lines are LMCache saying it stored the
    # blocks and gave them back. Both spellings of the store line,
    # because v0.5.8rc1 reworded v0.5.7's and matching only one is not
    # a missed line but a wrong answer -- see .builders/serve-test.sh.
    stored=$(grep -acE 'Stored [0-9]+ (of [0-9]+ requested )?tokens' \
        "${OUT}/lmcache.log" 2>/dev/null || true)
    got=$(grep -acE 'retained keys|Retrieved [0-9]+' \
        "${OUT}/lmcache.log" 2>/dev/null || true)
    nokey=$(grep -aci 'no lookup ipc key' "${OUT}/lmcache.log" 2>/dev/null || true)

    if [ "${stored:-0}" -gt 0 ] && [ "${got:-0}" -gt 0 ]; then
        check pass "LMCache stored and served" \
            "${stored} store(s), ${got} retrieve(s); prefill ${cold}s -> ${warm}s"
    elif [ "${stored:-0}" -gt 0 ]; then
        check fail "LMCache served nothing" \
            "${stored} store(s) and no retrieve: blocks went in and never came back"
    elif [ "${nokey:-0}" -gt 0 ]; then
        check fail "LMCache cached nothing" \
            "only 'no lookup ipc key' (${nokey}x) -- the LMCache#4419 signature"
    else
        check fail "LMCache cached nothing" \
            "no store line in its log; prefix may be shorter than one ${CHUNK_SIZE}-token chunk"
    fi

    kill -TERM -- "-${lm_pid}" 2> /dev/null || true
    sleep 2
    kill -KILL -- "-${lm_pid}" 2> /dev/null || true
    quiet_log "${OUT}/vllm-lmcache.log"
    metric seconds "$(since "${t0}")"
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

if ! wanted lmcache; then
    skip_stage lmcache "not selected"
elif failed install || [ ! -x "${VENV}/bin/lmcache" ]; then
    skip_stage lmcache "not run" "the install stage left no lmcache to start"
else
    stage_lmcache
fi

# The NIXL L2 tiers. Both need lmcache.lmcache_nixl, which the
# published wheel ships but cannot load outside the image: its RPATH
# is the build container's /opt/venv path, so libnixl.so is not found
# in a venv anywhere else. Measured on 2026-11-24 against
# lmcache 0.5.8+rocm10.2.0 from the public index.
for s in nixl-nvme nixl-nvmeof; do
    skip_stage "${s}" "not written yet" \
        "needs lmcache_nixl, whose RPATH points at the build container"
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
