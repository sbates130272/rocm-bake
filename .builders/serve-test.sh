#!/usr/bin/env bash
# serve-test.sh - exercise a running serving stack and prove it caches.
#
# `make serve-wait` already answers "is it up". This answers the harder
# question: is it doing the thing it was built to do. Those are not the
# same question here, and the gap between them is the whole reason this
# script exists.
#
# LMCache on ROCm has a documented failure mode where the endpoint is
# perfectly healthy and caches nothing — LMCache/LMCache#4419, where a
# reporter ran eight days and ~36k requests at a zero hit rate, the only
# symptom being "no lookup ipc key" in a log nobody was reading. Every
# check short of measuring a hit passes in that state. So the last two
# checks below do not ask whether a response came back; they ask whether
# the second identical prefill was cheaper than the first, and whether
# LMCache itself says it served the blocks.
#
# Checks, in order, each independent of the next:
#   health      /health answers
#   models      /v1/models lists the model we think we are serving
#   completion  a chat request returns non-empty content
#   prefill     a repeated long prefix prefills measurably faster
#   evidence    LMCache's own log shows the store and the retrieve
#
# prefill and evidence are skipped, not failed, when the stack was
# started with KV_OFFLOAD=0 — that is the baseline configuration and
# has no cache by design.
#
# Usage:
#   ./serve-test.sh                       against $GPU_HOST:8000
#   ./serve-test.sh --baseline            skip the cache checks
#   ./serve-test.sh --l2                  empty L1 too, so only disk can answer
#   GPU_HOST=other PORT=8001 ./serve-test.sh
set -uo pipefail

GPU_HOST="${GPU_HOST:-snoc-thinkstation}"
PORT="${PORT:-8000}"
BASE="http://${GPU_HOST}:${PORT}"
MODEL="${SERVE_MODEL:-}"
BASELINE=0
# Long enough to span several LMCache chunks (default chunk size 256
# tokens), because a prefix shorter than one chunk is never stored and
# the cache checks would fail against a working stack.
PREFIX_WORDS="${PREFIX_WORDS:-1200}"

L2=0

while [ $# -gt 0 ]; do
    case "$1" in
        --baseline) BASELINE=1; shift ;;
        --l2)       L2=1; shift ;;
        -h|--help)  sed -n '2,32p' "$0"; exit 0 ;;
        *)          echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# LMCache's control API, which listens on loopback inside its own
# container and is deliberately not published — so it is reached the
# same way the logs are, through the GPU host.
lmcache_api() {
    # $1 method, $2 path, $3 optional JSON body
    local body=""
    [ -n "${3:-}" ] && body="-d '$3' -H 'Content-Type: application/json'"
    ssh -o BatchMode=yes "$GPU_HOST" \
        "docker exec \$(docker ps --format '{{.Names}}' | grep -m1 lmcache) \
         curl -s --max-time 10 -X $1 $body http://127.0.0.1:8080$2" 2>/dev/null
}

PASS=0
FAIL=0
SKIP=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$*"; SKIP=$((SKIP + 1)); }
info() { printf '        %s\n' "$*"; }

echo "== ${BASE}"

# ─── health ──────────────────────────────────────────────────────
if curl -fsS --max-time 10 "${BASE}/health" >/dev/null 2>&1; then
    ok "/health"
else
    bad "/health did not answer — is the stack up? (make serve-status)"
    echo
    echo "no point running the rest against a dead endpoint."
    exit 1
fi

# ─── models ──────────────────────────────────────────────────────
# vLLM reports the model id it actually loaded, which is not always the
# one that was asked for: a typo in MODEL makes it fall back to nothing
# and this is where that shows up.
MODELS_JSON=$(curl -fsS --max-time 10 "${BASE}/v1/models" 2>/dev/null)
SERVED=$(printf '%s' "$MODELS_JSON" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["data"][0]["id"])
except Exception:
    pass
' 2>/dev/null)

if [ -n "$SERVED" ]; then
    ok "/v1/models — serving ${SERVED}"
    if [ -n "$MODEL" ] && [ "$MODEL" != "$SERVED" ]; then
        bad "expected ${MODEL}, endpoint is serving ${SERVED}"
    fi
    MODEL="$SERVED"
else
    bad "/v1/models returned nothing usable"
    MODEL="${MODEL:-unknown}"
fi

# ─── completion ──────────────────────────────────────────────────
# jq is not assumed: these hosts have python in every image and jq in
# none of them.
chat() {
    # $1 prompt, $2 max_tokens. Prints the response body.
    python3 -c '
import json, sys
print(json.dumps({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": sys.argv[2]}],
    "max_tokens": int(sys.argv[3]),
    "temperature": 0,
}))' "$MODEL" "$1" "$2" \
        | curl -fsS --max-time 180 -H 'Content-Type: application/json' \
               -d @- "${BASE}/v1/chat/completions" 2>/dev/null
}

RESP=$(chat "Reply with the single word: ready" 16)
CONTENT=$(printf '%s' "$RESP" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["choices"][0]["message"]["content"].strip())
except Exception:
    pass
' 2>/dev/null)

if [ -n "$CONTENT" ]; then
    ok "chat completion — $(printf '%.40s' "$CONTENT")"
else
    bad "chat completion returned no content"
fi

if [ "$BASELINE" = 1 ]; then
    skip "prefill timing (--baseline: no connector configured)"
    skip "LMCache evidence (--baseline)"
else

# ─── prefill ─────────────────────────────────────────────────────
# max_tokens=1 on purpose. Decode time then rounds to nothing and the
# measured latency is almost entirely prefill, which is the only part
# a KV cache can make cheaper. Timing a long generation would bury the
# effect in decode noise and make the threshold below meaningless.
#
# The prefix is unique per run. A fixed one would be in the cache from
# the previous run of this script, so the "cold" measurement would
# already be warm and the comparison would show nothing.
PREFIX=$(python3 -c '
import random, string, sys
n = int(sys.argv[1])
random.seed()
tag = "".join(random.choices(string.ascii_lowercase, k=8))
# Prose-shaped filler rather than random characters: a tokenizer turns
# random strings into far more tokens than words, which makes the
# prompt length unpredictable across runs.
words = ["cache", "tensor", "kernel", "stream", "block", "offload",
         "prefix", "token", "layer", "device", "memory", "engine"]
print(f"Document {tag}. " + " ".join(random.choices(words, k=n)))
' "$PREFIX_WORDS")

QUESTION=$'\n\nIn one word, what is the first word of this document?'

timed_chat() {
    local start end
    start=$(date +%s.%N)
    chat "$1" 1 >/dev/null
    end=$(date +%s.%N)
    python3 -c "print(f'{float('$end') - float('$start'):.3f}')"
}

vllm_metric() {
    curl -fsS --max-time 10 "${BASE}/metrics" 2>/dev/null \
        | grep -aE "^vllm:$1" | awk '{print $2}' | head -1
}

COLD=$(timed_chat "${PREFIX}${QUESTION}")

# Drop vLLM's own GPU prefix cache between the two requests, so the
# second one cannot be served from VRAM. Without this the timing proves
# only that *something* cached — vLLM's prefix cache produces the same
# speedup as LMCache and the test cannot tell them apart.
#
# /reset_prefix_cache only exists when the server was started with
# VLLM_SERVER_DEV_MODE=1 (VLLM_DEV_MODE=1 for this compose file). When
# it is absent the timing check still runs, but it is reported as
# unattributed rather than claimed as LMCache's doing.
HITS_BEFORE=$(vllm_metric 'prefix_cache_hits_total')
if curl -fsS --max-time 20 -X POST "${BASE}/reset_prefix_cache" \
        -o /dev/null 2>/dev/null; then
    RESET=yes
else
    RESET=no
fi

# --l2 additionally empties LMCache's own L1, so the blocks cannot come
# from host RAM either. With VRAM and L1 both gone, anything that still
# answers came off disk. Requires the stack to have been started with
# KV_TIER=file; with KV_TIER=cpu there is no L2 and the retrieve simply
# misses, which the evidence check below reports rather than hides.
if [ "$L2" = 1 ]; then
    CLEARED=$(lmcache_api POST /cache/clear '{"tier":"l1"}')
    case "$CLEARED" in
        *'"status":"ok"'*) info "LMCache L1 cleared — only L2 can answer now" ;;
        *) bad "could not clear LMCache L1 (${CLEARED:-no response})"
           info "needs the lmcache container up and its API on :8080." ;;
    esac
fi

# Same prefix, different suffix. The shared prefix is what should come
# from the cache; changing the tail proves the hit is a real prefix
# match and not a whole-response cache somewhere else in the path.
WARM=$(timed_chat "${PREFIX}${QUESTION} Answer briefly.")
HITS_AFTER=$(vllm_metric 'prefix_cache_hits_total')

info "prefill: cold ${COLD}s, warm ${WARM}s"
if [ "$RESET" = yes ]; then
    info "vLLM GPU prefix cache reset between them; its hits ${HITS_BEFORE:-?} -> ${HITS_AFTER:-?}"
else
    info "vLLM prefix cache NOT reset (needs VLLM_DEV_MODE=1) — the win"
    info "below cannot be attributed to LMCache rather than to VRAM."
fi

# 15%, not 50%: the win scales with prompt length and this prompt is
# deliberately modest so the test stays quick. A working cache on a
# 1200-word prefix clears this comfortably — measured 3.93s -> 0.39s on
# a 27k-token prompt upstream — while natural run-to-run variance on a
# quiet box does not.
FASTER=$(python3 -c "
cold, warm = float('$COLD'), float('$WARM')
print('yes' if cold > 0 and (cold - warm) / cold > 0.15 else 'no')
")

if [ "$FASTER" = yes ] && [ "$RESET" = yes ]; then
    # The strong form: VRAM was emptied and vLLM's hit counter did not
    # move, so the blocks came from outside the GPU. Measured 0.647s ->
    # 0.054s with vllm:prefix_cache_hits_total flat at 0 and LMCache
    # reporting "10/10 retained keys (10 L1, 0 L2)".
    if [ -n "$HITS_BEFORE" ] && [ "$HITS_BEFORE" = "$HITS_AFTER" ]; then
        ok "faster with VRAM cache emptied and 0 vLLM hits — served from LMCache"
    else
        ok "repeated prefix prefills faster"
        info "vLLM also recorded prefix-cache hits, so the win is shared."
    fi
elif [ "$FASTER" = yes ]; then
    ok "repeated prefix prefills faster (cache is doing work)"
else
    bad "repeated prefix was not faster — endpoint healthy, cache idle"
    info "this is the LMCache#4419 shape: serving fine, caching nothing."
    info "check 'make serve-logs-cache' for 'no lookup ipc key'."
fi

# ─── evidence ────────────────────────────────────────────────────
# Timing can be fooled by vLLM's own prefix caching, which would make
# the check above pass with LMCache contributing nothing. Ask LMCache
# directly. Both a store and a retrieve have to appear: a store alone
# means blocks went in and never came back out.
LOGS=$(ssh -o BatchMode=yes "$GPU_HOST" \
    "docker ps --format '{{.Names}}' | grep -E 'lmcache' \
     | while read -r c; do docker logs --tail 400 \"\$c\" 2>&1; done" 2>/dev/null)

if [ -z "$LOGS" ]; then
    skip "LMCache evidence — no lmcache container found on ${GPU_HOST}"
else
    # Matched against what this LMCache version actually prints, not a
    # guess at the vocabulary:
    #   Stored 1280 tokens in 0.023 seconds
    #   Prefetch request completed (L1+L2): 5/5 retained keys (5 L1, 0 L2)
    STORED=$(printf '%s' "$LOGS" | grep -acE 'Stored [0-9]+ tokens' || true)
    GOT=$(printf '%s' "$LOGS" | grep -acE 'retained keys|Retrieved [0-9]+' || true)
    NOKEY=$(printf '%s' "$LOGS" | grep -aci 'no lookup ipc key' || true)

    # "10/10 retained keys (0 L1, 10 L2)" — the tier split on the last
    # prefetch is what says which store actually answered.
    TIERS=$(printf '%s' "$LOGS" | grep -aoE '\([0-9]+ L1, [0-9]+ L2\)' | tail -1)
    # sed, not a second grep: "5 L2" piped through `grep -oE '[0-9]+'`
    # yields both the 5 and the 2 of "L2", so the count came out as two
    # lines and every numeric test errored with "integer expected".
    FROM_L1=$(printf '%s' "$TIERS" | sed -n 's/^(\([0-9]*\) L1.*/\1/p')
    FROM_L2=$(printf '%s' "$TIERS" | sed -n 's/.*, \([0-9]*\) L2)$/\1/p')

    if [ "$L2" = 1 ]; then
        if [ "${FROM_L2:-0}" -gt 0 ] && [ "${FROM_L1:-0}" -eq 0 ]; then
            ok "served ${FROM_L2} chunks from L2 with L1 emptied — disk tier works"
        elif [ "${FROM_L2:-0}" -gt 0 ]; then
            ok "served ${FROM_L2} from L2 and ${FROM_L1} from L1"
            info "L1 refilled between the clear and the request; the L2 read is still real."
        else
            bad "nothing came from L2 (last prefetch: ${TIERS:-none seen})"
            info "was the stack started with KV_TIER=file? KV_TIER=cpu has no L2."
        fi
    elif [ "$STORED" -gt 0 ] && [ "$GOT" -gt 0 ]; then
        ok "LMCache stored (${STORED}) and served (${GOT}) — cache is live"
        [ -n "$TIERS" ] && info "last prefetch tiers: ${TIERS}"
        # One of these per fresh session is normal: the first lookup of
        # a session happens before anything has been stored for it. It
        # is only the #4419 signature when it is *all* you ever see,
        # which the store/retrieve counts above rule out — so this is
        # reported, not failed.
        [ "$NOKEY" -gt 0 ] && \
            info "('no lookup ipc key' x${NOKEY} — first-lookup-of-session, benign here)"
    elif [ "$STORED" -gt 0 ]; then
        bad "LMCache stored blocks but served none back"
        info "blocks go in and never come out: check the transfer mode."
    elif [ "$NOKEY" -gt 0 ]; then
        bad "LMCache logged only 'no lookup ipc key' (${NOKEY}x), no stores"
        info "this is the LMCache#4419 shape — the IPC handshake never"
        info "completed, so it serves traffic while caching nothing."
        info "HSA_ENABLE_IPC_MODE_LEGACY is the setting in play; see"
        info "the note in serving/docker-compose.yml before changing it."
    else
        bad "LMCache log shows no cache activity at all"
    fi
fi

fi

# ─── result ──────────────────────────────────────────────────────
echo
printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
