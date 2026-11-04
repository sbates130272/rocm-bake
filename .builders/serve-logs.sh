#!/usr/bin/env bash
# serve-logs.sh - tail the serving containers on the GPU host, merged.
#
# The vLLM and LMCache containers log independently, and the useful
# lines alternate between them: vLLM reports what it asked for, LMCache
# reports whether it had it. Reading them in two terminals means
# correlating by eye.
#
# Default is a live follow in arrival order, each line tagged with its
# container. --sorted instead takes a snapshot and merges on Docker's
# own timestamps, which is the only way to get true chronological
# order across two independent streams.
#
# Usage:
#   ./serve-logs.sh                        follow both, live
#   ./serve-logs.sh --sorted               snapshot, time-ordered
#   ./serve-logs.sh --cache                only the cache-relevant lines
#   ./serve-logs.sh -n 200 ov-vllm         one container, more history
#   GPU_HOST=other ./serve-logs.sh
set -uo pipefail

# The node the fleet manifest marks `gpu_node:`. Empty on a fleet that
# has none, which the check below reports rather than running
# `docker -H ssh://` with nothing after it.
GPU_HOST="${GPU_HOST:-$(python3 -I "$(dirname "${BASH_SOURCE[0]}")/fleet.py" \
    --make 2>/dev/null | sed -n 's/^FLEET_GPU_HOST=//p')}"
if [ -z "${GPU_HOST}" ]; then
    echo "serve-logs: this fleet declares no gpu node; set GPU_HOST=<host>" >&2
    exit 1
fi
TAIL="${TAIL:-40}"
MODE=follow
FILTER=""
CONTAINERS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --sorted)  MODE=sorted; shift ;;
        --cache)   FILTER='stored|retriev|hit|miss|evict|lookup|offload|KV'; shift ;;
        --grep)    FILTER="$2"; shift 2 ;;
        -n)        TAIL="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *)         CONTAINERS+=("$1"); shift ;;
    esac
done

# Default to whatever serving containers are actually up, so this works
# for both the compose stack (rocm-serving-*) and the bench harness
# (ov-*) without being told which.
if [ "${#CONTAINERS[@]}" -eq 0 ]; then
    mapfile -t CONTAINERS < <(ssh -o BatchMode=yes "$GPU_HOST" \
        "docker ps --format '{{.Names}}' | grep -E '^(ov-|rocm-serving-)' | sort")
fi
if [ "${#CONTAINERS[@]}" -eq 0 ]; then
    echo "no serving containers running on $GPU_HOST" >&2
    ssh -o BatchMode=yes "$GPU_HOST" "docker ps --format '  {{.Names}}\t{{.Status}}'" >&2
    exit 1
fi
echo "== $GPU_HOST: ${CONTAINERS[*]}  (mode=$MODE tail=$TAIL)" >&2

# Built remotely and run in one ssh session: a separate connection per
# container would multiply the latency and desynchronise the streams.
# 2>&1 per container is not optional — vLLM and LMCache both log to
# stderr, so without it this prints almost nothing.
if [ "$MODE" = sorted ]; then
    remote='for c in '"${CONTAINERS[*]}"'; do
        docker logs -t --tail '"$TAIL"' "$c" 2>&1 | sed "s/^/$c /"
    done | sort -k2'
else
    remote='pids=""
    for c in '"${CONTAINERS[*]}"'; do
        ( docker logs -f -t --tail '"$TAIL"' "$c" 2>&1 | sed "s/^/[$c] /" ) &
        pids="$pids $!"
    done
    trap "kill $pids 2>/dev/null" INT TERM
    wait'
fi

[ -n "$FILTER" ] && remote="$remote | grep -aiE '$FILTER'"

exec ssh -o BatchMode=yes -o ServerAliveInterval=30 -t "$GPU_HOST" "$remote"
