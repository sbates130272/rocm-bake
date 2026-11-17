#!/usr/bin/env bash
# cpu-test.sh - serve a real model on CPU through vLLM + LMCache and
# prove the answer and the cache are both real.
#
# The emu lane's complement: emu-test.sh proves nothing was loaded,
# this proves something was. Health and a non-empty completion say
# only that the HTTP stack is up, so the checks that matter are the
# ones a broken lane would still fail: a checkable answer, weights in
# the log, and KV blocks that went to LMCache and came back unchanged.
#
# Checks, in order:
#   cpu         this host's ISA flags, first, so a SIGILL is attributable
#   health      /health answers
#   models      /v1/models lists the model we asked for
#   completion  /v1/completions returns non-empty text
#   inference   a temperature-0 question is answered correctly, and the
#               log shows weights were loaded
#   same-server with --attach: the container found through docker is the
#               one that answered, by this run's tag in its access log
#   isa         which vllm._C variant the engine actually mapped
#   no-device   no CUDA or HIP in torch, no /dev/kfd, no /dev/dri
#   cache       a repeated long prefix is served from LMCache: vLLM's
#               external-prefix-cache hit counter moves with its own
#               prefix cache emptied, the answer matches the one from
#               that cache, and LMCache logs the store and the retrieve
#   l2          with --l2: the fs tier holds the blocks and serves them
#               with L1 emptied
#
# Usage:
#   ./cpu-test.sh                      start the stack, test it, remove it
#   ./cpu-test.sh --keep               leave the stack running
#   ./cpu-test.sh --l2                 file tier (same as KV_TIER=file,
#                                      except with --attach)
#   ./cpu-test.sh --baseline           no connector: cache checks skipped
#   ./cpu-test.sh --attach PROJECT     test the compose project already up
#                                      on DOCKER_HOST; start and stop nothing
#   ./cpu-test.sh --endpoint URL       HTTP checks only, or with --attach
#                                      the URL to use instead of the
#                                      published port (a tunnel)
#   REGISTRY=... MODEL=... PORT=... TRANSFER_MODE=... ./cpu-test.sh
#
# --attach is `make serve-test SERVE_DEVICE=cpu`: the stack is already
# serving, usually on another host, and every container check runs
# through docker there (DOCKER_HOST=ssh://host). Nothing is skipped for
# want of access: a docker host that does not answer, a project with
# no vllm container, or an endpoint that is not that container, is a
# failure. The one skip is the weights line once the host has rotated
# it out of the log. The cache check needs the stack started with
# VLLM_DEV_MODE=1 and fails, saying so, without it. --l2 empties
# LMCache's L1 on that stack; nothing else there is changed.
#
# Exit: 0 all passed, 1 a check failed or the stack did not start,
# 2 usage. Everything serving/docker-compose.cpu.yml reads from the
# environment (CPUSET, VLLM_MEM_LIMIT, HF_CACHE, ...) passes through.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
STACK="${STACK:-$(dirname "$HERE")/serving/docker-compose.cpu.yml}"
# Not the compose file's own project name, and not its port: `make
# cpu-serve` may be up on this machine, and the test must not take it
# down or collide with it.
PROJECT="${PROJECT:-rocm-serving-cpu-test}"
PORT="${PORT:-8012}"
# Covers a cold model download. Measured on four cores with the model
# cached: about 70 s.
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-900}"
# SmolLM2-135M answers this at temperature 0 with "The capital of
# France is Paris." Another MODEL may want another pair.
QUESTION="${QUESTION:-What is the capital of France? Answer with one word.}"
EXPECT="${EXPECT:-paris}"
PREFIX_WORDS="${PREFIX_WORDS:-1200}"

ENDPOINT=""
ATTACH=""
BASELINE=0
KEEP=0
L2=0
L2_ASKED=0
[ "${KV_TIER:-cpu}" = "file" ] && L2=1
while [ $# -gt 0 ]; do
    case "$1" in
        --keep)     KEEP=1; shift ;;
        --l2)       L2=1; L2_ASKED=1; shift ;;
        --baseline) BASELINE=1; shift ;;
        # An empty name would read as "not attached" below, and the
        # run would start a stack of its own on DOCKER_HOST.
        --attach)   [ -n "${2:-}" ] || { echo "--attach needs a compose project name" >&2; exit 2; }
                    ATTACH="$2"; shift 2 ;;
        --endpoint) [ $# -ge 2 ] || { echo "--endpoint needs a URL" >&2; exit 2; }
                    ENDPOINT="$2"; shift 2 ;;
        -h|--help)  sed -n '2,54p' "$0"; exit 0 ;;
        *)          echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [ "$BASELINE" = 1 ]; then
    [ "$L2_ASKED" = 0 ] || { echo "--baseline has no cache, so no --l2" >&2; exit 2; }
    # KV_TIER=file in the environment is the stack's setting, not a
    # request to test a tier the baseline does not have.
    L2=0
fi
# Attached, KV_TIER here is whatever the caller's shell or make line
# carried; the stack's own tier is read from the container. Only --l2
# asks for the L2 test.
[ -z "$ATTACH" ] || L2=$L2_ASKED

PASS=0
FAIL=0
SKIP=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$*"; SKIP=$((SKIP + 1)); }
info() { printf '        %s\n' "$*"; }

T0=$(date +%s)
COMPOSE=(docker compose -p "$PROJECT" -f "$STACK")
STARTED=0
# 1 once there are containers to read: a stack this run started, or
# one it attached to. --endpoint alone has only HTTP.
HAVE_C=0
VLLM_C=""
LMCACHE_C=""

cleanup() {
    [ "$STARTED" = 1 ] || return 0
    if [ "$KEEP" = 1 ]; then
        info "stack ${PROJECT} kept; remove it with:"
        info "  docker compose -p ${PROJECT} -f ${STACK} down"
        return 0
    fi
    "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true
    # The L2 files are this run's and nothing else's. The model cache
    # is kept: it is what makes the second run a warm one.
    [ -n "${KV_STORE:-}" ] || docker volume rm "${PROJECT}_kv-store" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Colour codes stripped: LMCache's logger wraps the level in them.
logs() { docker logs "$1" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
running() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null; }
cname() { docker inspect -f '{{.Name}}' "$1" 2>/dev/null | sed 's|^/||'; }

# The exception line first. vLLM re-raises a worker's failure through
# two parent processes, so the first traceback is fifty lines of frames
# and the tail is "Engine core initialization failed" — the one line
# that names the cause is in between. The stack is kept, as in
# emu-test.sh: the trap would otherwise remove the only copy of the log.
startup_failure() {
    KEEP=1
    echo
    if [ -n "$VLLM_C" ]; then
        info "--- exceptions in the vllm log ---"
        logs "$VLLM_C" | grep -aoE '[A-Za-z_][A-Za-z_.]*(Error|Exception): .*' \
            | awk '!seen[$0]++' | head -5 | cut -c1-400
        info "--- last 15 lines ---"
        logs "$VLLM_C" | tail -15 | cut -c1-300
    fi
    # lmcache only when it has something to say: it outlives most vllm
    # failures and its healthy tail is noise.
    if [ -n "$LMCACHE_C" ]; then
        errs=$(logs "$LMCACHE_C" | grep -aE ' ERROR|Traceback|rror: ' | head -5 | cut -c1-400)
        if [ -n "$errs" ] || [ "$(running "$LMCACHE_C")" != "true" ]; then
            info "--- lmcache ---"
            [ -n "$errs" ] && printf '%s\n' "$errs"
            logs "$LMCACHE_C" | tail -10 | cut -c1-300
        fi
    fi
    echo
    exit 1
}

# ─── attach ──────────────────────────────────────────────────────
# Someone else's stack, usually on another host: DOCKER_HOST and the
# project name are all there is to go on. Anything here that cannot be
# established is a failure and ends the run. Skipping instead would
# let a host that never answered report nothing wrong.
SINCE=""
RUN_TAG=""
PUB=""
DHOST=""
OFFLOAD_C=""
DEV_C=""
TIER_C=""
WANT_C=""

# Fails when docker does: a host that stopped answering is not a host
# with no such container. `local` on its own line, or its status would
# replace docker's.
by_service() {
    local ids
    ids=$(docker ps -a -q --filter "label=com.docker.compose.project=${ATTACH}" \
        --filter "label=com.docker.compose.service=$1" 2>"$ERR") || return 1
    printf '%s\n' "$ids" | head -1
}

# started_with CONTAINER NAME... -> NAME=value lines from the
# container's environment. Picked out by the template, so HF_TOKEN,
# which sits in the same list, is never printed.
unreachable() {
    bad "cannot reach docker at ${WHERE}"
    grep -v '^$' "$ERR" | tail -2 | cut -c1-300 | sed 's/^/        /'
    rm -f "$ERR"
    exit 1
}

started_with() {
    local c="$1" names=""
    shift
    for n in "$@"; do names="${names} \"${n}\""; done
    docker inspect -f '{{range .Config.Env}}{{$kv := split . "="}}{{if eq (index $kv 0)'"${names}"'}}{{println .}}{{end}}{{end}}' \
        "$c" 2>/dev/null
}
value_of() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

if [ -n "$ATTACH" ]; then
    WHERE="${DOCKER_HOST:-the local docker daemon}"
    echo "== attach: compose project ${ATTACH} on ${WHERE}"
    # In every request's URL, so the vllm container's access log can be
    # asked whether this run's requests were the ones it answered.
    RUN_TAG="cpu-test=$$-$(date +%s%N)"
    # The daemon's clock, not this machine's — the two need not agree.
    # It bounds the log read for LMCache's own account below; asking
    # for it is also what finds out whether the host answers at all.
    ERR=$(mktemp)
    SINCE=$(docker info -f '{{.SystemTime}}' 2>"$ERR")
    case "$SINCE" in
        [0-9][0-9][0-9][0-9]-*) ;;
        *)  unreachable ;;
    esac
    VLLM_C=$(by_service vllm) || unreachable
    LMCACHE_C=$(by_service lmcache) || unreachable
    rm -f "$ERR"
    if [ -z "$VLLM_C" ]; then
        bad "no vllm container in compose project ${ATTACH} on ${WHERE}"
        info "projects there: $(docker ps -a --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null \
            | sort -u | grep -v '^$' | tr '\n' ' ')"
        info "start it with: make serve-stack SERVE_DEVICE=cpu VLLM_DEV_MODE=1"
        info "(plus the KV_TIER, KV_STORE and other settings you serve with)"
        exit 1
    fi
    if [ "$(running "$VLLM_C")" != "true" ]; then
        bad "$(cname "$VLLM_C") is not running"
        logs "$VLLM_C" | tail -15 | cut -c1-300
        exit 1
    fi
    HAVE_C=1
    if [ -n "$LMCACHE_C" ] && [ "$(running "$LMCACHE_C")" != "true" ]; then
        bad "$(cname "$LMCACHE_C") is not running"
        LMCACHE_C=""
    elif [ -z "$LMCACHE_C" ] && [ "$BASELINE" = 0 ]; then
        bad "no lmcache container in compose project ${ATTACH}"
    fi

    CONF=$(started_with "$VLLM_C" MODEL KV_OFFLOAD VLLM_SERVER_DEV_MODE LMCACHE_MP_TRANSFER_MODE)
    WANT_C=$(value_of "$CONF" MODEL)
    OFFLOAD_C=$(value_of "$CONF" KV_OFFLOAD)
    DEV_C=$(value_of "$CONF" VLLM_SERVER_DEV_MODE)
    [ -z "$LMCACHE_C" ] || TIER_C=$(value_of "$(started_with "$LMCACHE_C" KV_TIER)" KV_TIER)
    info "started with KV_OFFLOAD=${OFFLOAD_C:-?} KV_TIER=${TIER_C:-?}" \
         "TRANSFER_MODE=$(value_of "$CONF" LMCACHE_MP_TRANSFER_MODE) VLLM_DEV_MODE=${DEV_C:-?}"

    if [ -z "$ENDPOINT" ]; then
        # The port is bound on the docker host, so that is the name to
        # ask. IPv4 first: `docker port` lists [::] as well.
        PUB=$(docker port "$VLLM_C" 8000/tcp 2>/dev/null | grep -v '^\[' | head -1)
        if [ -z "$PUB" ]; then
            bad "$(cname "$VLLM_C") publishes no port for 8000/tcp — pass --endpoint URL"
            exit 1
        fi
        case "${DOCKER_HOST:-}" in
            ssh://*|tcp://*)
                DHOST=${DOCKER_HOST#*://}; DHOST=${DHOST%%/*}
                DHOST=${DHOST##*@}; DHOST=${DHOST%%:*} ;;
            *)  DHOST=127.0.0.1 ;;
        esac
        ENDPOINT="http://${DHOST}:${PUB##*:}"
    fi
fi

# ─── cpu ─────────────────────────────────────────────────────────
# The wheel carries three builds of its kernels and picks one from
# CPUID: _C (AVX-512 with BF16), _C_AVX512, _C_AVX2. Loading the wrong
# one is a SIGILL with no Python traceback, so say what this host has
# before anything can die of it.
if [ -n "$ATTACH" ]; then
    # The serving host's CPU, and as many of them as vllm was given.
    CPUINFO=$(docker exec "$VLLM_C" sh -c \
        'echo "$(uname -m), $(nproc) online"; grep -m1 "^flags" /proc/cpuinfo' 2>/dev/null)
    CPU="${CPUINFO%%$'\n'*}"
    FLAGS="${CPUINFO#*$'\n'}"
else
    CPU="$(uname -m), $(nproc) online"
    FLAGS=$(grep -m1 -E '^flags' /proc/cpuinfo 2>/dev/null || true)
fi
ISA=""
for f in avx2 avx512f avx512_bf16 amx_tile; do
    case " ${FLAGS} " in
        *" ${f} "*) ISA="${ISA} ${f}=yes" ;;
        *)          ISA="${ISA} ${f}=no" ;;
    esac
done
echo "== cpu: ${CPU:-unreadable},${ISA}"
if [ -z "$ENDPOINT" ]; then
    case "$ISA" in
        *avx2=yes*) ;;
        *) bad "this CPU has no AVX2 — the smallest kernel build needs it"
           exit 1 ;;
    esac
fi

if [ -n "$ENDPOINT" ]; then
    BASE="$ENDPOINT"
    WANT="${MODEL:-${WANT_C}}"
    echo "== ${BASE} (already running)"
else
    BASE="http://127.0.0.1:${PORT}"
    export VLLM_PORT="$PORT"
    # /reset_prefix_cache, without which the cache check cannot tell
    # LMCache's blocks from vLLM's own.
    export VLLM_DEV_MODE=1
    [ "$L2" = 1 ] && export KV_TIER='file'
    [ "$BASELINE" = 1 ] && export KV_OFFLOAD=0

    # --images lists services in no fixed order.
    IMAGES=$("${COMPOSE[@]}" config --images 2>/dev/null | sort) \
        || { echo "cannot read ${STACK}" >&2; exit 1; }
    for img in $IMAGES; do
        echo "== ${img}"
        # Checked here because compose would otherwise try to pull, and
        # the default registry is one a stock runner cannot reach.
        docker image inspect "$img" >/dev/null 2>&1 \
            || { echo "not in the local docker daemon — run: make cpu-load" >&2; exit 1; }
    done
    # The compose file owns the model default. Parsed, never printed
    # whole: the resolved config carries HF_TOKEN.
    WANT=$("${COMPOSE[@]}" config --format json 2>/dev/null | python3 -I -c '
import json, sys
print(json.load(sys.stdin)["services"]["vllm"]["environment"]["MODEL"])' 2>/dev/null)

    "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true
    STARTED=1
    T_UP=$(date +%s)
    if ! UP=$("${COMPOSE[@]}" up -d 2>&1); then
        LMCACHE_C=$("${COMPOSE[@]}" ps -a -q lmcache 2>/dev/null)
        bad "docker compose up failed"
        printf '%s\n' "$UP" | tail -5 | sed 's/^/        /'
        startup_failure
    fi
    VLLM_C=$("${COMPOSE[@]}" ps -a -q vllm)
    LMCACHE_C=$("${COMPOSE[@]}" ps -a -q lmcache)
    HAVE_C=1

    printf '        waiting for the endpoint'
    until curl -fsS --max-time 5 "${BASE}/health" >/dev/null 2>&1; do
        waited=$(( $(date +%s) - T_UP ))
        for c in "$VLLM_C" "$LMCACHE_C"; do
            if [ "$(running "$c")" != "true" ]; then
                echo
                bad "$(cname "$c") exited during startup"
                startup_failure
            fi
        done
        if [ "$waited" -ge "$STARTUP_TIMEOUT" ]; then
            echo
            bad "no /health after ${STARTUP_TIMEOUT}s"
            startup_failure
        fi
        sleep 3; printf '.'
    done
    STARTUP=$(( $(date +%s) - T_UP ))
    echo " (${STARTUP}s)"
fi

# ─── health ──────────────────────────────────────────────────────
if curl -fsS --max-time 10 "${BASE}/health" >/dev/null 2>&1; then
    ok "/health"
else
    bad "/health did not answer"
    case "${DHOST}/${PUB}" in
        127.0.0.1/*|localhost/*|/*) ;;
        */127.0.0.1:*)
            info "vllm is published on ${PUB}, loopback on ${DHOST}: serve it with"
            info "VLLM_BIND=0.0.0.0, or tunnel the port and pass --endpoint URL" ;;
    esac
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
if [ -z "$SERVED" ]; then
    bad "/v1/models returned nothing usable"
elif [ -n "${WANT:-}" ] && [ "$SERVED" != "$WANT" ]; then
    bad "/v1/models — serving ${SERVED}, asked for ${WANT}"
else
    ok "/v1/models — serving ${SERVED}"
fi

# request KIND TEXT MAX_TOKENS [logprobs] -> the generated text on one
# line, then with `logprobs` each token's logprob on a second. KIND is
# `chat` or `completions`; temperature 0 throughout.
request() {
    python3 -I -c '
import json, sys
kind, model, text, n = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
body = {"model": model, "max_tokens": n, "temperature": 0}
if kind == "chat":
    body["messages"] = [{"role": "user", "content": text}]
    body["logprobs"] = len(sys.argv) > 5
else:
    body["prompt"] = text
print(json.dumps(body))' "$1" "${SERVED:-${WANT:-}}" "$2" "$3" ${4:+"$4"} \
    | curl -fsS --max-time 300 -H 'Content-Type: application/json' -d @- \
           "${BASE}/v1/$( [ "$1" = chat ] && echo chat/completions || echo completions )${RUN_TAG:+?${RUN_TAG}}" \
           2>/dev/null \
    | python3 -I -c '
import json, sys
try:
    c = json.load(sys.stdin)["choices"][0]
    print(" ".join((c["message"]["content"] if "message" in c else c["text"]).split()))
    if c.get("logprobs"):
        print(" ".join(repr(t["logprob"]) for t in c["logprobs"]["content"]))
except Exception:
    pass' 2>/dev/null
}

elapsed() { python3 -I -c "print(f'{float('$2') - float('$1'):.2f}')"; }

# ─── completion ──────────────────────────────────────────────────
TEXT=$(request completions "The quick brown fox" 16)
if [ -n "$TEXT" ]; then
    ok "/v1/completions — $(printf '%.50s' "$TEXT" | tr '\n' ' ')"
else
    bad "/v1/completions returned no text"
    [ "$HAVE_C" = 1 ] && logs "$VLLM_C" | tail -30
fi

# ─── inference ───────────────────────────────────────────────────
# What the emu lane cannot do: the answer has to be right, which no
# filler token and no stubbed forward pass will manage.
ANSWER=$(request chat "$QUESTION" 16)
if printf '%s' "$ANSWER" | grep -qi -- "$EXPECT"; then
    ok "real inference — \"$(printf '%.60s' "$ANSWER" | tr '\n' ' ')\""
else
    bad "wrong answer — wanted '${EXPECT}' in \"$(printf '%.80s' "$ANSWER" | tr '\n' ' ')\""
fi

# ─── same server ─────────────────────────────────────────────────
# --endpoint, a tunnel or a docker context can point the HTTP checks
# at one server and the container checks at another, and two stacks
# serving one model look alike from /v1/models. uvicorn logs each
# request's URL; this run's carry RUN_TAG. Ends the run: every check
# below would be reported against the wrong server.
if [ -n "$ATTACH" ]; then
    SEEN=0
    n=0
    # The log line trails the response by a moment.
    while [ "$n" -lt 20 ]; do
        SEEN=$(docker logs --since "$SINCE" "$VLLM_C" 2>&1 | grep -acF "$RUN_TAG")
        [ "${SEEN:-0}" -gt 0 ] && break
        sleep 0.25; n=$((n + 1))
    done
    if [ "${SEEN:-0}" -gt 0 ]; then
        ok "${BASE} is $(cname "$VLLM_C") — it logged ${SEEN} of this run's requests"
    else
        bad "${BASE} is not $(cname "$VLLM_C") — it logged none of this run's requests"
        info "check --endpoint, the tunnel or the docker context; or the server"
        info "runs with --disable-uvicorn-access-log, and this cannot be told"
        exit 1
    fi
fi

# The inverse of emu-test.sh's no-weights check, on the same log line:
# both model runners print it when they really load.
if [ "$HAVE_C" = 1 ]; then
    LOADED=$(logs "$VLLM_C" | grep -ao -m1 'Model loading took .*')
    if [ -n "$LOADED" ]; then
        ok "weights loaded — ${LOADED}"
    # Attached, the stack may be old enough for the host's log driver
    # to have rotated its startup away; the entrypoint's first line
    # says whether this log still has it. Not `grep -q` in the
    # pipeline: under pipefail its early exit would read as rotated.
    elif [ -n "$ATTACH" ] && [ -z "$(logs "$VLLM_C" | grep -a -m1 '^vllm: model=')" ]; then
        skip "weights check (the log no longer reaches back to startup — rotated)"
    else
        bad "vLLM never logged a model load"
    fi
else
    skip "weights check (--endpoint: no log access)"
fi

# ─── isa ─────────────────────────────────────────────────────────
# Read from the engine's own address space: the log never names the
# variant, and a host with AVX-512 otherwise gives no sign of which
# build a host without it would have run.
if [ "$HAVE_C" = 1 ]; then
    MAPPED=$(docker exec "$VLLM_C" sh -c 'cat /proc/[0-9]*/maps 2>/dev/null' \
        | grep -ao 'vllm/_C[A-Z0-9_]*\.abi3\.so' | sort -u | tr '\n' ' ')
    case "$(printf '%s' "$MAPPED" | wc -w)" in
        1) ok "kernels from ${MAPPED% }" ;;
        0) bad "no vllm/_C*.abi3.so mapped in any process" ;;
        *) bad "processes mapped different kernel builds: ${MAPPED}" ;;
    esac
else
    skip "isa check (--endpoint: no container to read)"
fi

# ─── no device ───────────────────────────────────────────────────
# torch.version, not only is_available(): the image sets
# CUDA_VISIBLE_DEVICES="", which would make a CUDA torch say False too.
if [ "$HAVE_C" = 1 ]; then
    for c in "$VLLM_C" "$LMCACHE_C"; do
        # Attached with no lmcache: already reported, or a baseline.
        [ -n "$c" ] || continue
        name=$(cname "$c")
        if OUT=$(docker exec "$c" python -c '
import os, torch
assert not torch.cuda.is_available(), "torch.cuda.is_available() is True"
assert torch.version.cuda is None, "CUDA torch"
assert getattr(torch.version, "hip", None) is None, "HIP torch"
for dev in ("/dev/kfd", "/dev/dri"):
    assert not os.path.exists(dev), dev + " is in the container"
print("torch", torch.__version__)' 2>&1); then
            ok "no device in ${name} — ${OUT}, no /dev/kfd, no /dev/dri"
        else
            bad "${name} can see a GPU"
            printf '%s\n' "$OUT" | tail -3 | sed 's/^/        /'
        fi
    done
else
    skip "no-device check (--endpoint: no container to exec)"
fi

# ─── cache ───────────────────────────────────────────────────────
# Counters and logs, not timing. On a GPU a cached prefix is several
# times faster and serve-test.sh can threshold on it; here a 1350-token
# prefill is a few hundred ms either way and the inline transfer costs
# as much as it saves, so the times are printed and decide nothing.
#
# What decides: vllm:external_prefix_cache_hits counts the prompt
# tokens the KV connector supplied, and vLLM's own prefix cache is
# emptied first, so nothing else could have supplied them.
metric() {
    curl -fsS --max-time 10 "${BASE}/metrics" 2>/dev/null \
        | grep -aE "^vllm:$1(\{| )" | awk '{s += $NF} END {printf "%d", s}'
}

# metric() prints 0 for a counter that is not exported at all, so a
# renamed one reads as an idle one. This tells them apart.
has_metric() {
    curl -fsS --max-time 10 "${BASE}/metrics" 2>/dev/null \
        | grep -aqE "^vllm:$1(\{| )"
}

# 200 with {"success": false} while blocks are still referenced, which
# they are until the connector has finished storing them — so this is
# also the wait for the store. 404 without VLLM_SERVER_DEV_MODE=1, and
# only a 404 means that: no reply or a 5xx is a server that has died,
# which must not be reported as a route that is merely switched off.
# Returns 0 reset, 1 still held, 2 no such route, 3 anything else.
RESET_CODE=
reset_prefix_cache() {
    local n=0 out
    while [ "$n" -lt 80 ]; do
        out=$(curl -sS --max-time 20 -w '\n%{http_code}' \
                   -X POST "${BASE}/reset_prefix_cache" 2>/dev/null)
        RESET_CODE=${out##*$'\n'}
        case "$RESET_CODE" in
            200) ;;
            404) return 2 ;;
            *) return 3 ;;
        esac
        case "$out" in
            *'"success":true'*|*'"success": true'*) return 0 ;;
        esac
        sleep 0.25; n=$((n + 1))
    done
    return 1
}

lmcache_api() {  # METHOD PATH [JSON] — the image has no curl
    docker exec "$LMCACHE_C" python -c '
import sys, urllib.request as u
data = sys.argv[3].encode() if len(sys.argv) > 3 else None
req = u.Request("http://127.0.0.1:8080" + sys.argv[2], data=data, method=sys.argv[1],
                headers={"Content-Type": "application/json"})
print(u.urlopen(req, timeout=20).read().decode())' "$@" 2>/dev/null
}

l2_files() {
    docker exec "$LMCACHE_C" sh -c 'find /kv-store -type f -name "*.data" | wc -l' 2>/dev/null
}

# Unique per run, or the first request finds the last run's blocks.
# Words, not random characters, so the token count stays predictable.
PREFIX=$(python3 -I -c '
import random, string, sys
tag = "".join(random.choices(string.ascii_lowercase, k=8))
words = ["cache", "tensor", "kernel", "stream", "block", "offload",
         "prefix", "token", "layer", "device", "memory", "engine"]
print(f"Document {tag}. " + " ".join(random.choices(words, k=int(sys.argv[1]))))
' "$PREFIX_WORDS")
PROMPT="${PREFIX}"$'\n\nIn one word, what is the first word of this document?'

# Attached, the log is as old as the stack, and a store from last week
# would pass for this run's. SINCE is the daemon's clock at attach.
evidence_logs() {
    if [ -n "$SINCE" ]; then
        docker logs --since "$SINCE" "$1" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
    else
        logs "$1"
    fi
}

# Settled before anything is sent: a stack with no connector has no
# cache to find, and whether that is a skip or a failure depends on
# which of the two the caller said it was testing.
RESET=""
if [ "$BASELINE" = 1 ]; then
    RESET=baseline
elif [ -n "$ATTACH" ] && [ "$OFFLOAD_C" = 0 ]; then
    RESET=no-connector
elif [ -n "$ATTACH" ] && [ "$L2" = 1 ] && [ "$TIER_C" != file ]; then
    # Reported, then tested as the L1-only stack it is. L1 is not
    # emptied for a tier that is not there.
    bad "--l2 needs the stack started with KV_TIER=file — this one has KV_TIER=${TIER_C:-?}"
    L2=0
fi

if [ -z "$RESET" ]; then
    OWN0=$(metric prefix_cache_hits_total)
    [ "$L2" = 1 ] && [ "$HAVE_C" = 1 ] && FILES0=$(l2_files)

    # One prompt, three times: computed, then from vLLM's own prefix
    # cache, then - with that cache emptied - from LMCache.
    t0=$(date +%s.%N)
    request chat "$PROMPT" 12 >/dev/null
    t1=$(date +%s.%N)
    REF=$(request chat "$PROMPT" 12 logprobs)
    t2=$(date +%s.%N)
    EXT1=$(metric external_prefix_cache_hits_total)
    OWN1=$(metric prefix_cache_hits_total)

    # An engine that dies on the long prompt is reported here, at the
    # request that killed it, not as a missing route two steps later.
    if [ -z "$REF" ]; then
        RESET=none
    else
        reset_prefix_cache
        RESET=$?
    fi
fi

if [ "$RESET" = baseline ]; then
    skip "cache (--baseline: no connector, so nothing to find)"
    [ "${OFFLOAD_C:-0}" = 0 ] || info "though this stack was started with KV_OFFLOAD=${OFFLOAD_C}"
elif [ "$RESET" = no-connector ]; then
    bad "cache — this stack was started with KV_OFFLOAD=0 and has no connector"
    info "for a baseline that is right: make serve-test-baseline SERVE_DEVICE=cpu"
elif [ "$RESET" = none ]; then
    bad "the ${PREFIX_WORDS}-word prompt got no answer — is the server still up?"
    [ "$HAVE_C" = 1 ] && logs "$VLLM_C" | tail -30
elif [ "$RESET" = 3 ]; then
    case "${RESET_CODE:-000}" in
        000) bad "/reset_prefix_cache got no reply — is the server still up?" ;;
        *)   bad "/reset_prefix_cache failed (HTTP ${RESET_CODE}) — is the server still up?" ;;
    esac
    [ "$HAVE_C" = 1 ] && logs "$VLLM_C" | tail -30
elif [ "$RESET" = 2 ] && [ "$STARTED" = 1 ]; then
    bad "/reset_prefix_cache is a 404, though this stack enables it"
elif [ "$RESET" = 2 ] && [ -n "$ATTACH" ]; then
    # A failure, not a skip: the caller asked whether the cache works,
    # and an exit of 0 would read as yes.
    bad "cache — cannot be checked: the server has no /reset_prefix_cache (VLLM_DEV_MODE=${DEV_C:-unset})"
    info "without it LMCache's blocks cannot be told from vLLM's own. Re-run the"
    info "serve-stack command that started this stack with VLLM_DEV_MODE=1 added;"
    info "KV_TIER, KV_STORE and the rest are not remembered between runs."
elif [ "$RESET" = 2 ]; then
    skip "cache (no /reset_prefix_cache — the server needs VLLM_SERVER_DEV_MODE=1)"
elif [ "$RESET" = 1 ]; then
    bad "vLLM's prefix cache would not reset — blocks still held after 20s"
else
    # ─── l2 ──────────────────────────────────────────────────────
    # L1 is emptied only once the files exist: the fs tier is written
    # behind the store, and clearing L1 first would drop blocks that
    # had not reached the disk yet.
    if [ "$L2" = 1 ] && [ "$HAVE_C" = 1 ]; then
        n=0
        FILES1=$(l2_files)
        while [ "${FILES1:-0}" -le "${FILES0:-0}" ] && [ "$n" -lt 120 ]; do
            sleep 0.25; n=$((n + 1)); FILES1=$(l2_files)
        done
        if [ "${FILES1:-0}" -gt "${FILES0:-0}" ]; then
            ok "fs tier holds the blocks — $((FILES1 - FILES0)) new files in /kv-store"
        else
            bad "nothing was written to /kv-store (${FILES1:-?} files)"
            info "was the stack started with KV_TIER=file?"
        fi
        case "$(lmcache_api POST /cache/clear '{"tier":"l1"}')" in
            *'"status":"ok"'*) info "LMCache L1 cleared — only L2 can answer now" ;;
            *) bad "could not clear LMCache L1" ;;
        esac
    elif [ "$L2" = 1 ]; then
        skip "l2 (--endpoint: no lmcache container to read)"
    fi

    t3=$(date +%s.%N)
    WARM=$(request chat "$PROMPT" 12 logprobs)
    t4=$(date +%s.%N)
    EXT2=$(metric external_prefix_cache_hits_total)
    OWN2=$(metric prefix_cache_hits_total)

    info "computed $(elapsed "$t0" "$t1")s, from vLLM's cache $(elapsed "$t1" "$t2")s," \
         "from LMCache $(elapsed "$t3" "$t4")s — for information"
    if [ "${EXT2:-0}" -gt "${EXT1:-0}" ] && [ -z "$WARM" ]; then
        # The hit is counted when the request is scheduled, so the
        # counter alone would credit a load that then failed.
        bad "LMCache was asked for $((EXT2 - EXT1)) tokens, but the request returned no answer"
        [ "$HAVE_C" = 1 ] && logs "$VLLM_C" | tail -30
    elif [ "${EXT2:-0}" -gt "${EXT1:-0}" ]; then
        ok "served from LMCache — $((EXT2 - EXT1)) prompt tokens from the connector," \
           "$((OWN2 - OWN1)) from vLLM's own cache"
        # And they have to be the RIGHT blocks: a transfer that hands
        # back stale or unwritten memory still counts as a hit.
        #
        # Compared with the answer from vLLM's own cache, not with the
        # computed one. Those two prefill the same 70-token tail over
        # the same prefix, so they agree to the last bit of every
        # logprob (100 of 100 here). A full prefill rounds differently in
        # bfloat16, and against it a near-tie flipped about one prompt
        # in fifteen on 32 threads with nothing wrong.
        #
        # No reference is a SKIP only when that cache is really off
        # (--no-enable-prefix-caching). A counter that has gone from
        # /metrics would otherwise drop this check silently, for good.
        if ! has_metric prefix_cache_hits_total; then
            bad "vllm:prefix_cache_hits_total is not exported — renamed? the same-answer check cannot run"
        elif [ "${OWN1:-0}" -le "${OWN0:-0}" ]; then
            skip "same-answer (vLLM's own prefix cache did not serve the reference)"
        elif [ -n "$REF" ] && [ "$REF" = "$WARM" ]; then
            ok "same answer, same logprobs as from vLLM's own cache —" \
               "\"$(printf '%s\n' "$WARM" | head -1 | cut -c1-50)\""
        else
            bad "the answer changed when the prefix came from LMCache"
            info "vLLM's cache: $(printf '%s\n' "$REF" | head -1 | cut -c1-80)"
            info "LMCache:      $(printf '%s\n' "$WARM" | head -1 | cut -c1-80)"
        fi
    else
        bad "the repeated prefix was not served from LMCache — external cache hits ${EXT1:-?} -> ${EXT2:-?}"
        info "endpoint healthy, cache idle: is KV_OFFLOAD=1, and do the two"
        info "services agree on TRANSFER_MODE?"
    fi

    # ─── LMCache's own account ───────────────────────────────────
    # engine_driven and lmcache_driven word the store differently:
    #   Stored 1280 tokens in 0.191 seconds
    #   Stored 1280 of 1280 requested tokens in 0.021 seconds
    #   Prefetch request completed (L1+L2): 5/5 retained keys (5 L1, 0 L2)
    #   Retrieved 1280 tokens in 0.050 seconds
    if [ "$HAVE_C" = 1 ]; then
        LOGS=$(evidence_logs "$LMCACHE_C")
        STORED=$(printf '%s\n' "$LOGS" | grep -acE 'Stored [0-9]+ (of [0-9]+ requested )?tokens')
        GOT=$(printf '%s\n' "$LOGS" | grep -acE 'Retrieved [0-9]+ tokens')
        TIERS=$(printf '%s\n' "$LOGS" | grep -aoE '\([0-9]+ L1, [0-9]+ L2\)' | tail -1)
        FROM_L1=$(printf '%s' "$TIERS" | sed -n 's/^(\([0-9]*\) L1.*/\1/p')
        FROM_L2=$(printf '%s' "$TIERS" | sed -n 's/.*, \([0-9]*\) L2)$/\1/p')
        if [ "$STORED" -gt 0 ] && [ "$GOT" -gt 0 ]; then
            ok "LMCache stored (${STORED}) and retrieved (${GOT}) — last prefetch ${TIERS:-not logged}"
        elif [ "$STORED" -gt 0 ]; then
            bad "LMCache stored blocks but served none back"
        else
            bad "LMCache log shows no store and no retrieve"
        fi
        if [ "$L2" = 1 ]; then
            if [ "${FROM_L2:-0}" -gt 0 ] && [ "${FROM_L1:-0}" -eq 0 ]; then
                ok "served ${FROM_L2} chunks from L2 with L1 emptied — fs tier works"
            else
                bad "the blocks did not come from L2 (last prefetch: ${TIERS:-none seen})"
            fi
        fi
    else
        skip "LMCache evidence (--endpoint: no log access)"
    fi
fi

echo
[ "$STARTED" = 1 ] && info "startup ${STARTUP}s, whole test $(( $(date +%s) - T0 ))s"
printf '  %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
