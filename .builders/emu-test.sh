#!/usr/bin/env bash
# emu-test.sh - exercise the LLM-Emu serving lane and prove it emulated.
#
# WHY THIS IS NOT JUST A CURL. Every other serving check in this repo
# has a GPU underneath it, so "it answered" means something ran. Here
# nothing runs: weights are never materialised, no kernel is launched,
# and the per-step latency is drawn from a profile pack. That makes the
# healthy-looking failure the one to guard against. If llm-emu's
# platform plugin does not activate, or the shim's executor wiring does
# not attach, or the profile pack fails to load, the server still
# starts, still answers /health, still lists /v1/models and - because
# vLLM falls back to real execution paths - can still return something
# shaped like a completion. Checks 1, 5 and 6 are the ones that can
# tell those apart; 2 to 4 only prove the HTTP stack is alive.
#
# Checks, in order:
#   selftest    the wiring attached and vLLM still matches its premises
#   health      /health answers
#   models      /v1/models lists the model we asked for
#   completion  /v1/completions returns non-empty text
#   no-weights  the log shows load_model was SKIPPED - nothing was loaded
#   oracle      the executor hook drove the steps, and wall-clock
#               tracks the latency it predicted rather than running free
#
# Usage:
#   ./emu-test.sh                      start a container, test it, remove it
#   ./emu-test.sh --keep               leave the container running
#   ./emu-test.sh --endpoint URL       test something already serving
#   IMAGE=... PORT=... MODEL=... ./emu-test.sh
set -uo pipefail

IMAGE="${IMAGE:-snoc-strix.fold-leaffish.ts.net:8080/rocm-pytorch/vllm-emu:latest}"
PORT="${PORT:-8011}"
# Qwen3-8B is the model the bundled pack was captured against, whatever
# device the pack is now labelled for. Only config.json and the
# tokenizer are fetched - a few MB - because load_model never runs.
MODEL="${MODEL:-Qwen/Qwen3-8B}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-2048}"
# The emulator sizes its KV pool from the pack's gpu_memory_bytes, not
# from this host's RAM, so a long startup here is HF metadata and
# vLLM's own init rather than anything being allocated.
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-600}"
NAME="${NAME:-vllm-emu-test}"

ENDPOINT=""
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --keep)     KEEP=1; shift ;;
        --endpoint) ENDPOINT="$2"; shift 2 ;;
        -h|--help)  sed -n '2,28p' "$0"; exit 0 ;;
        *)          echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

PASS=0
FAIL=0
SKIP=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$*"; SKIP=$((SKIP + 1)); }
info() { printf '        %s\n' "$*"; }

STARTED=0
cleanup() {
    [ "$STARTED" = 1 ] || return 0
    if [ "$KEEP" = 1 ]; then
        info "container ${NAME} left running (--keep); docker logs -f ${NAME}"
        return 0
    fi
    docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

logs() { docker logs "$NAME" 2>&1; }

# vLLM runs its engine in a child process and re-raises in the parent
# as "Engine core initialization failed. See root cause above" — so the
# useful part of the log is the FIRST traceback, hundreds of lines
# above the one that kills the server. A plain tail shows the re-raise
# and nothing that caused it, which is exactly what the first failing
# run here produced.
#
# The container is also kept, not removed: a dead container still has
# its logs, and the trap would otherwise take the only copy of them
# away at the moment they became interesting.
startup_failure() {
    KEEP=1
    echo
    info "--- first traceback in the log ---"
    logs | awk '/Traceback|^ERROR|Error:/{found=1} found' | head -60
    info "--- last 40 lines ---"
    logs | tail -40
    echo
    info "container ${NAME} kept — full log: docker logs ${NAME}"
    rerun_in_process
    exit 1
}

# vLLM's engine core is a child process. When it dies during the
# handshake the parent reports
#
#   RuntimeError: Engine core initialization failed. See root cause
#   above. Failed core proc(s): {}
#
# and there is frequently no root cause above it at all — the child's
# exception went down with the child. Measured here twice: the first
# failure showed forty lines of re-raise, and the second showed that
# the log contains no earlier traceback to find.
#
# VLLM_ENABLE_V1_MULTIPROCESSING=0 runs the engine core in the API
# server process, so the same failure raises in a process whose output
# we are reading. That is a diagnostic setting and not how the lane
# serves — multiproc is the real path and the one worth testing — so it
# is used only to ask the question after a failure, with a short
# timeout, and its answer is printed rather than acted on.
rerun_in_process() {
    [ "${VLLM_ENABLE_V1_MULTIPROCESSING:-1}" = "0" ] && return 0
    info "--- retrying in-process for a legible traceback ---"
    timeout "${INPROC_TIMEOUT:-240}" docker run --rm \
        --name "${NAME}-inproc" \
        ${HF_TOKEN:+-e HF_TOKEN="${HF_TOKEN}"} \
        ${HF_HOME:+-v "${HF_HOME}:/root/.cache/huggingface"} \
        -e VLLM_ENABLE_V1_MULTIPROCESSING=0 \
        "$IMAGE" serve "$MODEL" \
            --host 127.0.0.1 --port 8000 \
            --max-model-len "$MAX_MODEL_LEN" \
        2>&1 | awk '/Traceback|^ERROR|Error:/{found=1} found' | head -60
    docker rm -f "${NAME}-inproc" >/dev/null 2>&1 || true
}

if [ -n "$ENDPOINT" ]; then
    BASE="$ENDPOINT"
    echo "== ${BASE} (already running)"
else
    BASE="http://127.0.0.1:${PORT}"
    echo "== ${IMAGE}"
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    # No --gpus, no /dev/kfd, no /dev/dri, and that is the claim: this
    # lane serves on a machine with no AMD GPU and no ROCm installed.
    # HF_TOKEN is passed through when set - Qwen3 needs none, but a
    # gated model would.
    # No proxy passthrough. Weights are never fetched (load_model is
    # stubbed) but the config and tokenizer are, so the container does
    # need huggingface.co — and on a node with direct egress that is
    # all it needs. A proxy that a container should use belongs in the
    # docker daemon's own config, where every container on the node
    # gets it, rather than re-derived from whatever happens to be
    # exported in the shell that ran this script.
    docker run -d --name "$NAME" -p "${PORT}:8000" \
        ${HF_TOKEN:+-e HF_TOKEN="${HF_TOKEN}"} \
        ${HF_HOME:+-v "${HF_HOME}:/root/.cache/huggingface"} \
        "$IMAGE" serve "$MODEL" \
            --host 0.0.0.0 --port 8000 \
            --max-model-len "$MAX_MODEL_LEN" \
        >/dev/null || { echo "could not start ${IMAGE}" >&2; exit 1; }
    STARTED=1

    printf '        waiting for the endpoint'
    waited=0
    until curl -fsS --max-time 5 "${BASE}/health" >/dev/null 2>&1; do
        if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
            echo
            bad "container exited during startup"
            startup_failure
        fi
        if [ "$waited" -ge "$STARTUP_TIMEOUT" ]; then
            echo
            bad "no /health after ${STARTUP_TIMEOUT}s"
            startup_failure
        fi
        sleep 3; waited=$((waited + 3)); printf '.'
    done
    echo " (${waited}s)"
fi

# ─── selftest ────────────────────────────────────────────────────
# First, because everything after it is meaningless if the wiring is
# not attached. Skipped against a foreign endpoint, where there is no
# container to exec into.
if [ "$STARTED" = 1 ]; then
    if OUT=$(docker exec "$NAME" vllm-emu-selftest --require-platform 2>&1); then
        ok "vllm-emu-selftest"
    else
        bad "vllm-emu-selftest"
        printf '%s\n' "$OUT" | sed 's/^/        /'
    fi
else
    skip "vllm-emu-selftest (--endpoint: no container to exec)"
fi

# ─── health ──────────────────────────────────────────────────────
if curl -fsS --max-time 10 "${BASE}/health" >/dev/null 2>&1; then
    ok "/health"
else
    bad "/health did not answer"
    exit 1
fi

# ─── models ──────────────────────────────────────────────────────
SERVED=$(curl -fsS --max-time 10 "${BASE}/v1/models" 2>/dev/null | python3 -I -c '
import json, sys
try:
    print(json.load(sys.stdin)["data"][0]["id"])
except Exception:
    pass
' 2>/dev/null)
if [ -n "$SERVED" ]; then
    ok "/v1/models — serving ${SERVED}"
else
    bad "/v1/models returned nothing usable"
fi

# ─── completion ──────────────────────────────────────────────────
# /v1/completions, not /v1/chat/completions: the emulator emits a fixed
# filler token rather than model output, so there is nothing for a chat
# template to be right about, and the completions route is the shorter
# path through the same scheduler.
#
# The content is deliberately not inspected beyond "non-empty". Asking
# the emulator for a correct answer would be asking the profile pack a
# question it cannot answer - no weights were ever loaded. What is
# being tested is that a request traversed the scheduler, the executor
# hook and the output pipeline.
N_TOKENS="${N_TOKENS:-32}"
start=$(date +%s.%N)
RESP=$(python3 -I -c '
import json, sys
print(json.dumps({"model": sys.argv[1], "prompt": "The quick brown fox",
                  "max_tokens": int(sys.argv[2]), "temperature": 0}))
' "${SERVED:-$MODEL}" "$N_TOKENS" \
    | curl -fsS --max-time 180 -H 'Content-Type: application/json' \
           -d @- "${BASE}/v1/completions" 2>/dev/null)
end=$(date +%s.%N)
ELAPSED=$(python3 -I -c "print(f'{float('$end') - float('$start'):.3f}')")

NTOK=$(printf '%s' "$RESP" | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d["usage"]["completion_tokens"])
except Exception:
    print(0)
' 2>/dev/null)

if [ "${NTOK:-0}" -gt 0 ]; then
    ok "/v1/completions — ${NTOK} tokens in ${ELAPSED}s"
else
    bad "/v1/completions returned no tokens"
    [ "$STARTED" = 1 ] && logs | tail -30
fi

# ─── no weights were loaded ──────────────────────────────────────
# cuda_mock prints this when it stubs GPUModelRunner.load_model. Its
# absence means weights were materialised, which means this was not an
# emulation - on a CPU-only box that is a very slow real run, and on a
# GPU box it is a real one wearing the emulator's name.
if [ "$STARTED" = 1 ]; then
    # Asserted as the ABSENCE of a real load, not the presence of a
    # particular stub's log line.
    #
    # The first version of this looked for cuda_mock's "load_model
    # SKIPPED" and failed a run that was entirely correct: once
    # init_device stopped raising, model setup took a path that prints
    # a different message, and the check concluded weights had been
    # loaded on a server that had started in 21 seconds. A Qwen3-8B
    # load is minutes and gigabytes, so its own absence is the better
    # evidence, and vLLM says so itself — both model runners log
    # "Model loading took %s GiB memory and %.6f seconds" when they
    # really load (gpu/model_runner.py:429, gpu_model_runner.py:5089).
    if logs | grep -q 'Model loading took'; then
        bad "vLLM logged a real model load — this was not an emulation"
        logs | grep -m1 'Model loading took' | sed 's/^/        /'
    else
        ok "no weights materialised (vLLM never logged a model load)"
    fi
    # Positive evidence that the stubs are in the process at all, kept
    # separate so "which stub fired" never again decides a pass.
    MARKS=$(logs | grep -c 'EmulatorCudaMock\|EmulatorModelStubs')
    info "${MARKS} emulator stub markers in the log"
else
    skip "no-weights check (--endpoint: no log access)"
fi

# ─── the oracle actually drove the steps ─────────────────────────
# ExecutorEmulatorHook._handle_async prints one of these per step for
# the first ten steps and every hundredth after:
#
#   [ExecutorHook] step=7 tt=1 reqs=1 new=0 latency=23.4ms
#
# Two things are asserted. That the lines exist at all - without them
# the executor hook never fired and vLLM executed through its own path.
# And that wall-clock tracks the predicted timeline: in realtime mode
# each step sleeps for its predicted latency, so a run that returned
# faster than the predictions it printed is not replaying the pack.
#
# Half the predicted sum is the floor, not the sum itself: only the
# first ten steps are printed, so the comparison is deliberately
# one-sided and loose. It catches "resolved instantly", which is the
# failure mode, not a timing regression.
if [ "$STARTED" = 1 ]; then
    HOOK_LINES=$(logs | grep -c '\[ExecutorHook\] step=')
    if [ "${HOOK_LINES:-0}" -gt 0 ]; then
        ok "executor hook drove ${HOOK_LINES}+ steps from the profile pack"
        PREDICTED=$(logs | grep -o 'latency=[0-9.]*ms' | sed 's/latency=//; s/ms//' \
            | python3 -I -c '
import sys
vals = [float(x) for x in sys.stdin.read().split() if x]
print(f"{sum(vals)/1000.0:.3f}")' 2>/dev/null)
        FLOOR=$(python3 -I -c "print(f'{float('${PREDICTED:-0}') * 0.5:.3f}')")
        if python3 -I -c "import sys; sys.exit(0 if float('$ELAPSED') >= float('$FLOOR') else 1)"; then
            ok "wall-clock tracks the pack (${ELAPSED}s against ${PREDICTED}s predicted over the logged steps)"
        else
            bad "returned in ${ELAPSED}s against ${PREDICTED}s of predicted latency — the timeline was not replayed"
        fi
    else
        bad "no [ExecutorHook] lines — the executor hook never fired"
        info "vLLM executed through its own path; the emulator was not in it"
    fi
else
    skip "oracle check (--endpoint: no log access)"
fi

echo
printf '  %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
