#!/bin/bash
# perfrun.sh - a cold, parallel, fully-instrumented build of every wheel.
#
# Produces the inputs for a performance report: what each builder was
# doing at each moment, what it cost them, and what moved over the wire.
# Five streams, each from the cheapest source that actually answers the
# question rather than from one general-purpose collector:
#
#   samples.jsonl    node_exporter on all three nodes, polled. CPU,
#                    memory, disk and network over time.
#   build-<t>.jsonl  buildx --progress=rawjson, one file per target.
#                    Every vertex with its start, end and cached flag —
#                    this is "what was the builder doing at 14:32" —
#                    and every transfer with byte counts over time.
#   sccache.log      the WebDAV vhost's own nginx log, sliced to this
#                    run. One line per object written, with its size.
#   zot.jsonl        Zot's structured log, sliced to this run. Layer
#                    cache and image pushes, with sizes.
#   artifacts.json   what ended up published, from wheelhouse.py.
#
# Cold means --no-cache *and* an sccache prefix of its own, the same
# isolation bench.sh uses: a cold run must not evict the fleet's
# working cache, and it must not be allowed to hit it either.
#
# Parallel means balance.sh, which is only usable here because
# PUBLISHED_INPUTS=1 collapses every wheel to a single self-contained
# target. Without it each wheel drags pytorch in and --no-cache
# rebuilds it, five times over.
#
# The timings this produces are throughput, not clean per-target
# measurements: three concurrent builds share the sccache store and the
# registry, both on Strix, which is also a build node. For isolated
# per-wheel numbers use bench.sh cold, which serialises on purpose.
#
# Usage: ./perfrun.sh [--dry-run] [--arch gfx1201]

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ARCH="${PYTORCH_ROCM_ARCH:-}"
DRY=0
# cold: --no-cache, an sccache prefix of its own, no push, cache-to
#   cleared. Measures what a build costs from nothing.
# normal: caches on, pushes, writes the shared sccache store. An
#   ordinary build that happens to be instrumented - the same five
#   streams, the same report, the same live chart.
MODE="${PERF_MODE:-cold}"
# Resolved after argument parsing, not here: --normal sets MODE in the
# loop below, so deciding this now made `--normal --dry-run` plan a
# cold run's placement.
# while/shift, not `for a in "$@"`. A shift inside a for-loop does not
# advance the loop variable — the list was captured when the loop
# started — so `--arch gfx1201` set ARCH to "--arch" and then saw
# "gfx1201" as an unrecognised argument and ignored it.
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --normal)  MODE=normal ;;
        --arch)    shift; ARCH="${1:-}" ;;
        --arch=*)  ARCH="${1#--arch=}" ;;
        *)         echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
[ -z "${ARCH}" ] && ARCH=$(make -s --eval='__a:;@printf "%s" "$(PYTORCH_ROCM_ARCH)"' __a 2>/dev/null)

DRY_PUSH_FLAG="--no-push"
[ "${MODE}" = normal ] && DRY_PUSH_FLAG=""

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="${PERF_DIR:-/var/tmp/rocm-perf}/${STAMP}"
INTERVAL="${PERF_INTERVAL:-5}"
SCCACHE_LOG="${SCCACHE_LOG_FILE:-/var/log/nginx/sccache.log}"

# What this run measures.
#
# bake's `wheels` group, plus pytorch. pytorch is not a wheel and is
# not in that group, but it is the image every other wheel builds
# FROM, and it is the most expensive thing in the graph — leaving it
# out measured the cheap half of a build and, on an arch nobody had
# built before, scheduled wheels against an image that did not exist.
#
# Including it is close to free on a normal run: the layer cache
# serves it in seconds. On a cold run it genuinely rebuilds, which is
# what cold means.
#
# No ordering here. balance.sh reads the dependency edges out of
# rocm-bake.hcl via depgraph.py and schedules against them, so a
# target starts when its own inputs are published and not before.
PERF_TARGETS="${PERF_TARGETS:-$(python3 -I "$(dirname "${BASH_SOURCE[0]}")/depgraph.py" --group wheels) pytorch}"

# A prefix of this run's own, deleted afterwards. Identical reasoning to
# bench.sh: the store is shared with the fleet and with the sibling
# project, so a cold run that wrote into the live prefix would evict
# objects other builds depend on, and one that read from it would not
# be cold.
# A normal build must use the fleet's real compiler cache, not a
# throwaway prefix: the point of it is to populate and benefit from
# what everything else shares.
if [ "${MODE}" = normal ]; then
    PREFIX=""
else
    PREFIX="perf-${STAMP}"
fi

log() { printf '[perf %(%H:%M:%S)T] %s\n' -1 "$*"; }

log "arch      ${ARCH}  mode=${MODE}"
if [ "${DRY}" = 1 ]; then
    log "dry run: showing placement only"
    PUBLISHED_INPUTS=1 PYTORCH_ROCM_ARCH="${ARCH}" \
    TARGETS="${PERF_TARGETS}" \
        ./.builders/balance.sh --dry-run ${DRY_PUSH_FLAG}
    exit 0
fi

mkdir -p "${RUN_DIR}"
log "run dir   ${RUN_DIR}"
log "prefix    ${PREFIX}"

cat > "${RUN_DIR}/run.json" <<EOF
{
  "stamp": "${STAMP}",
  "arch": "${ARCH}",
  "mode": "${MODE}",
  "interval_seconds": ${INTERVAL},
  "sccache_key_prefix": "${PREFIX}",
  "targets": "${PERF_TARGETS}",
  "vcs_ref": "$(git rev-parse --short HEAD 2>/dev/null)",
  "vcs_dirty": $( [ -n "$(git status --porcelain 2>/dev/null)" ] && echo true || echo false )
}
EOF


# Where each log stood before the build, so the slice afterwards is
# exactly this run and not whatever else the day contained.
NGINX_OFFSET=0
if sudo test -f "${SCCACHE_LOG}"; then
    NGINX_OFFSET=$(sudo stat -c %s "${SCCACHE_LOG}")
else
    log "WARNING ${SCCACHE_LOG} absent — re-run .builders/deploy-webdav.sh"
    log "        for per-object sccache write sizes. Continuing without."
fi
ZOT_CURSOR=$(sudo journalctl -u zot -n0 --show-cursor -o cat 2>/dev/null \
             | sed -n 's/^-- cursor: //p')

log "starting sampler every ${INTERVAL}s"
python3 -I .builders/perfsample.py \
    --out "${RUN_DIR}/samples.jsonl" --interval "${INTERVAL}" &
SAMPLER=$!
# Always reap the sampler: it outlives a Ctrl-C otherwise and keeps
# appending to a run nobody is watching.
trap 'kill "${SAMPLER}" 2>/dev/null || true' EXIT INT TERM

# balance.sh truncates a target's log when it runs it, but a target in
# a stage that never ran keeps whatever the last run left there — and
# the collection loop below would copy it in as if it were ours. An
# aborted run picked up a nixl-wheel stream from the previous day that
# way. Clear them up front so a stale file cannot be mistaken for data.
for t in ${PERF_TARGETS}; do
    rm -f "/tmp/balance-${t}.log"
done

START=$(date +%s)

# TELEMETRY=0: telemetry/build.sh parses bake's human-readable output
# for sccache counters, and rawjson is not that. The same numbers are
# recoverable from the rawjson logs, so nothing is lost by turning the
# wrapper off — whereas leaving it on costs a parse that silently finds
# nothing.
# In cold mode, --set *.cache-to= is not optional, and bench.sh
# clears it for the same reason: --no-push suppresses the *image*
# push, but a cache export is a separate registry write and still
# runs. Measured on a real gfx1201 run, triton-wheel reported 38m52s
# of which the trace accounts for 15m48s — the other 23m04s, 59% of
# its headline duration, was uploading mode=max cache nobody asked
# for, which made every per-target number useless as a build time.
#
# In normal mode none of that applies: the export is the point, the
# layer cache is the point, and the shared sccache prefix is the
# point. The only thing carried over is the instrumentation.
if [ "${MODE}" = normal ]; then
    EXTRA="--progress=rawjson"        # both caches live, cache-to kept
    PUSH_FLAG=""                      # publish, like any ordinary build
    log "building (normal: caches on, pushing, shared sccache)"
else
    EXTRA="--set *.cache-to= --no-cache --progress=rawjson"
    PUSH_FLAG="--no-push"
    log "building (cold: no layer cache, isolated sccache, no push)"
fi

TELEMETRY=0 \
BAKE_EXTRA="${EXTRA}" \
PUBLISHED_INPUTS=1 \
PYTORCH_ROCM_ARCH="${ARCH}" \
SCCACHE_WEBDAV_KEY_PREFIX="${PREFIX:-rocm-pytorch}" \
TARGETS="${PERF_TARGETS}" \
    ./.builders/balance.sh ${PUSH_FLAG} \
        > "${RUN_DIR}/balance.log" 2>&1
RC=$?
END=$(date +%s)
log "build finished rc=${RC} in $((END - START))s"

kill "${SAMPLER}" 2>/dev/null || true
wait "${SAMPLER}" 2>/dev/null

# balance.sh writes one log per target to /tmp; with BAKE_EXTRA set
# those are the rawjson streams. Move them in so the run directory is
# self-contained and the next run does not overwrite them.
# Only logs this run actually wrote. The mtime test is redundant given
# the clear above, but the cost of a stale stream here is a report that
# looks complete and is not, so it is worth asserting twice.
for t in ${PERF_TARGETS}; do
    src="/tmp/balance-${t}.log"
    [ -f "${src}" ] || continue
    if [ "$(stat -c %Y "${src}" 2>/dev/null || echo 0)" -lt "${START}" ]; then
        log "skipping ${t}: log predates this run"
        continue
    fi
    cp "${src}" "${RUN_DIR}/build-${t}.jsonl"
done

# The timeline, from BuildKit's own record rather than from the
# progress stream. The stream capture has been seen to truncate itself
# back to its 8-byte header partway through a healthy build, losing
# every vertex; the trace is written by BuildKit and read back after
# the fact, so there is nothing to miss. perfreport prefers it.
#
# The record name is asked of bake rather than built from the target
# name, because the two differ: vllm-wheel reports as
# rocm-pytorch-build/vllm/<arch>/<run>, and a guess would match
# nothing and fail silently.
#
# Parsed once, and its stderr is not discarded. A 2>/dev/null here
# would hide the one failure this script cannot otherwise detect:
# placement.py returning nothing, which looks identical to a run in
# which no target was scheduled and costs every trace in the run.
PLACEMENT=$(python3 .builders/placement.py "${RUN_DIR}")
[ -n "${PLACEMENT}" ] || log "warning: no placement parsed; traces will be skipped"

for t in ${PERF_TARGETS}; do
    node=$(echo "${PLACEMENT}" | awk -v t="${t}" '$1 == t {print $2; exit}')
    [ -n "${node}" ] || continue
    name=$(PYTORCH_ROCM_ARCH="${ARCH}" docker buildx bake -f rocm-bake.hcl \
           --print "${t}" 2>/dev/null \
           | jq -r ".target[\"${t}\"].args.BUILDKIT_BUILD_NAME // empty")
    [ -n "${name}" ] || continue
    python3 .builders/perftrace.py --builder "${node}" --name "${name}" \
        --out "${RUN_DIR}/trace-${t}.json" 2>&1 | sed 's/^/  /' || true
done

# Slice both logs to the window. tail -c +N is 1-indexed, hence the +1.
if sudo test -f "${SCCACHE_LOG}"; then
    # shellcheck disable=SC2024
    # The redirect is deliberately the caller's, not root's: only the
    # read needs privilege, and RUN_DIR belongs to the user. Writing it
    # as root would leave a file they cannot then clean up.
    sudo tail -c "+$((NGINX_OFFSET + 1))" "${SCCACHE_LOG}" 2>/dev/null \
        > "${RUN_DIR}/sccache.log"
fi
if [ -n "${ZOT_CURSOR}" ]; then
    sudo journalctl -u zot --after-cursor "${ZOT_CURSOR}" -o cat 2>/dev/null \
        | grep -a '^{' > "${RUN_DIR}/zot.jsonl"
else
    sudo journalctl -u zot --since "@${START}" -o cat 2>/dev/null \
        | grep -a '^{' > "${RUN_DIR}/zot.jsonl"
fi

# What the store gained, and then put it back as we found it.
[ -n "${PREFIX}" ] && log "sccache prefix: $(sudo du -sh "/var/cache/sccache-webdav/${PREFIX}" 2>/dev/null | cut -f1 || echo 'n/a')"
[ -n "${PREFIX}" ] && sudo rm -rf "/var/cache/sccache-webdav/${PREFIX}" 2>/dev/null

# Unquoted on purpose: WHEEL_REPOS is a list of repo names and each
# must arrive as its own argument.
read -r -a _repos <<< "$(make -s --eval='__w:;@printf "%s" "$(WHEEL_REPOS)"' __w)"
python3 .builders/wheelhouse.py --brief --limit 1 \
    "$(make -s --eval='__r:;@printf "%s" "$(REGISTRY)"' __r)" \
    "$(make -s --eval='__n:;@printf "%s" "$(REGISTRY_NAME)"' __n)" \
    "${_repos[@]}" \
    > "${RUN_DIR}/artifacts.txt" 2>&1 || true

printf '{"rc": %d, "started": %d, "ended": %d, "seconds": %d}\n' \
    "${RC}" "${START}" "${END}" "$((END - START))" > "${RUN_DIR}/result.json"

log "done: ${RUN_DIR}"
log "report with: make perf-report"
exit "${RC}"
