#!/bin/bash
# balance.sh - schedule bake targets across the fleet by current load.
#
# Why this exists: buildx's multi-node builder does not balance. Node
# selection is driven by platform matching, and when every node
# advertises linux/amd64 the choice among them ignores capacity — we
# watched all five targets land on snoc-gaming (16 cores, 15GB) while
# snoc-think (32 cores, 122GB) sat idle. There is no hook to change
# that, so the scheduling happens here instead: one bake invocation per
# target, each pinned to a builder we pick.
#
# Consequence: targets must exchange results through the registry
# rather than bake's `target:` contexts, because those only work within
# a single invocation. So every stage pushes, and later stages pull.
#
# Usage: ./balance.sh [--dry-run]
#
# Env:
#   NODES        space-separated builder names (default: the snoc-* set)
#   REGISTRY     passed through to bake
#   MIN_MEM_GB   skip nodes with less free memory than this (default 8)

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Record this run so `make build-stop` can find it without matching
# command lines, which is unreliable — see .builders/build-stop.sh.
echo $$ >> "${BUILD_PIDFILE:-/tmp/.rocm-build.pids}"

DRY_RUN=0
BEST_ONLY=0
PUSH=1
STREAM="${BALANCE_STREAM:-0}"
for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=1 ;;
        --best)     BEST_ONLY=1 ;;   # print the strongest node and exit
        --no-push)  PUSH=0 ;;
        --stream)   STREAM=1 ;;  # multiplex target logs to the terminal
        # Accepted and ignored. Scheduling is dependency-ordered now,
        # which is what --queue approximated by dropping barriers
        # entirely; callers still passing it get the better behaviour
        # rather than an "unknown argument" in the middle of a build.
        --queue)    ;;
    esac
done

# One bake per target, each pinned to a different node, results handed
# over through Zot. `target:` contexts cannot cross that boundary, so
# every target here resolves its inputs from published images instead.
# See the PUBLISHED_INPUTS comment in rocm-bake.hcl.
export PUBLISHED_INPUTS=1

NODES="${NODES:-snoc-think snoc-strix snoc-gaming}"
MIN_MEM_GB="${MIN_MEM_GB:-8}"

# What to build. The ORDER is deliberately not here.
#
# This file used to carry the dependency order by hand, as STAGE_1
# through STAGE_5. That was a second copy of something rocm-bake.hcl
# already states exactly — every target's `contexts` block — and the
# two could drift without anything saying so. They also could not
# express "wait for your own inputs" to a caller that overrode them: a
# gfx1250 perf-build scheduled vllm-wheel when no gfx1250 pytorch image
# existed, and it died resolving that base image at step 1 of 7, 0s in,
# taking the rest of its node's queue with it.
#
# depgraph.py reads the edges from bake instead, and run_dag below
# schedules against them. The default set is bake's `default` group,
# which is exactly what the five stages added up to.
#
# Override to build a subset; the order still takes care of itself:
#   TARGETS="pytorch-wheel triton-wheel" .builders/balance.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGETS="${TARGETS:-$(python3 -I "${HERE}/depgraph.py" --group default)}"
if [ -z "${TARGETS// /}" ]; then
    echo "balance: no targets to build" >&2
    exit 1
fi

# Facts from the old stage list that run_dag still has to honour, kept
# because they were learned the hard way:
#
#  - pytorch-run is deliberately absent from the `default` group: no
#    node has a working GPU, so the runtime image cannot be exercised
#    and is not worth a slot. Add it to the group when one does.
#  - triton-wheel comes before pytorch, not beside it. The pytorch
#    image installs our triton wheel, so it needs that target's result
#    (~90s once warm, the build being architecture-independent).
#  - lmcache-wheel comes before vllm-wheel, not beside it. vllm takes a
#    lmcache-wheel context, and results are handed between nodes
#    through Zot — so the wheel has to be *published* before vllm
#    starts, not merely building somewhere.
#
# All three are now edges in rocm-bake.hcl rather than assertions here,
# and run_dag enforces them by construction.

# ── node capacity ────────────────────────────────────────────────
# score = free GB of RAM + idle cores. Memory is weighted equally with
# cores on purpose: a cold PyTorch build runs one cc1plus per core and
# each takes 1-2GB, so RAM is what actually bounds a big node.
node_score() {
    local builder="$1" endpoint stats cores load freemem idle score

    # Health first, before anything is measured. A node whose buildkitd
    # is wedged still answers ssh, still reports idle cores and free
    # memory, and so scores *well* — snoc-gaming has ranked first while
    # sitting in buildx's `error` state, and the build scheduled onto it
    # failed after the endpoint gave up. Capacity is only meaningful on
    # a node that can accept work.
    if ! python3 "$(dirname "${BASH_SOURCE[0]}")/builder-health.py" \
            --check "$builder" >/dev/null 2>&1; then
        echo "0"; return
    fi

    endpoint=$(timeout 10 docker buildx inspect "$builder" 2>/dev/null \
        | awk '/^Endpoint:/ {print $2; exit}')
    [ -n "$endpoint" ] || { echo "0"; return; }

    case "$endpoint" in
        ssh://*) stats=$(timeout 10 ssh -n -o BatchMode=yes "${endpoint#ssh://}" \
            "nproc; cat /proc/loadavg | cut -d' ' -f1; free -g | awk '/^Mem:/{print \$7}'" 2>/dev/null) ;;
        *)       stats=$(nproc; cut -d' ' -f1 /proc/loadavg; free -g | awk '/^Mem:/{print $7}') ;;
    esac

    cores=$(echo "$stats" | sed -n 1p)
    load=$(echo "$stats" | sed -n 2p)
    freemem=$(echo "$stats" | sed -n 3p)
    [ -n "$cores" ] && [ -n "$freemem" ] || { echo "0"; return; }

    # Nodes too short on memory are excluded outright rather than
    # ranked low: a build that OOMs wastes more than it saves.
    if [ "$freemem" -lt "$MIN_MEM_GB" ]; then echo "0"; return; fi

    idle=$(awk -v c="$cores" -v l="${load:-0}" 'BEGIN{v=c-l; print (v>0)?v:0}')
    score=$(awk -v m="$freemem" -v i="$idle" 'BEGIN{printf "%.0f", m + i}')
    echo "$score"
}

declare -A SCORE

score_all() {
    local n
    for n in $NODES; do
        SCORE[$n]=$(node_score "$n")
    done
}

# Ranked best-first, excluding anything scored 0 (unreachable, or below
# the memory floor). Runs in a subshell via mapfile, hence score_all
# being a separate step in the parent.
rank_nodes() {
    local n
    for n in $NODES; do
        printf '%s %s\n' "${SCORE[$n]:-0}" "$n"
    done | sort -rn | awk '$1 > 0 {print $2}'
}

# bake target -> make target. Spelled out rather than derived: the two
# naming schemes genuinely differ (pytorch-run is push-runtime,
# pytorch-wheel is push-torch-wheel) and a clever substitution gets
# those wrong silently.
make_target() {
    case "$1" in
        pytorch-base)  echo push-base ;;
        pytorch)       echo push-pytorch ;;
        pytorch-run)   echo push-runtime ;;
        pytorch-wheel) echo push-torch-wheel ;;
        triton-wheel)  echo push-triton-wheel ;;
        aiter-wheel)   echo push-aiter-wheel ;;
        *)             echo "push-$1" ;;
    esac
}

# ── run one stage, one target per node, highest score first ──────

# ── per-node queues ───────────────────────────────────────────────
# Stages exist to order work that depends on earlier work. Under
# PUBLISHED_INPUTS=1 nothing here does: every wheel resolves to a
# single self-contained target that pulls its inputs from Zot. The
# stage barrier then buys nothing and costs a great deal - measured on
# run 20261029T184335Z, stage 1 took 44m16s of wall clock to do 77m09s
# of work, leaving 55m39s of idle builder time, with the weakest node
# idle for 82% of it.
#
# This mode drops the barrier. Targets are packed onto nodes
# longest-first (LPT list scheduling), and each node then drains its
# own queue sequentially while the nodes run concurrently. Sequential
# per node matters: five concurrent builds on one box each derive
# MAX_JOBS from MemAvailable as though they were alone, and
# oversubscribe it.
#
# LPT's makespan is within 4/3 of optimal, and with one job far longer
# than the rest - pytorch-wheel at 2336s against a 5232s total - it
# lands on the real lower bound, which is that longest job.
COSTS_FILE="${COSTS_FILE:-.builders/target-costs}"

# Cost of running <target> on <node>, in seconds: the build, plus the
# time to push its cache over that node's link.
#
# The second term is not a refinement. The fleet's upload speeds span
# a factor of 25 - 3000MB/s on the host itself, 90 wired, 3.7 over
# WiFi - so the same 6GB export is ~1 minute on one node and ~28 on
# another. Scheduling on build time alone sent the largest export to
# the slowest link and spent most of a normal build waiting on it.
cost_of() {
    local t="$1" node="${2:-}" build cache net
    build=$(awk -v t="$t" '$1 == "build" && $2 == t {print $3; exit}' \
            "${COSTS_FILE}" 2>/dev/null)
    build="${build:-1}"
    [ -z "${node}" ] && { echo "${build}"; return; }
    cache=$(awk -v t="$t" '$1 == "cache" && $2 == t {print $3; exit}' \
            "${COSTS_FILE}" 2>/dev/null)
    net=$(awk -v n="$node" '$1 == "netmb" && $2 == n {print $3; exit}' \
          "${COSTS_FILE}" 2>/dev/null)
    # No figure for this node means no reason to penalise it; fall back
    # to the build term rather than inventing a link speed.
    [ -n "${cache}" ] && [ -n "${net}" ] || { echo "${build}"; return; }
    awk -v b="${build}" -v c="${cache}" -v n="${net}" \
        'BEGIN{printf "%d", b + c/(n*1048576)}'
}

# ── dependency-ordered scheduling ────────────────────────────────
# A target becomes eligible when every dependency *inside this run* has
# finished and pushed. Dependencies outside the run resolve from the
# registry, which preflight verified, so they impose no ordering.
#
# Within that constraint this is the LPT packing the per-node queues
# used: among eligible targets the longest goes to the node that would
# finish it soonest. One build per node at a time — concurrent builds
# on one box each size MAX_JOBS from MemAvailable as though they were
# alone, and oversubscribe it.
#
# This replaces both earlier modes. Stage barriers idled whole nodes
# waiting for an unrelated target to finish (measured on
# 20261029T184335Z: 44m16s of wall clock for 77m09s of work, 55m39s of
# it idle). Flat per-node queues dropped the barrier but could not
# express a real dependency, which is how a gfx1250 run scheduled
# vllm-wheel with no pytorch image to build on.
declare -A DEPS STATE RUNTGT RUNNODE BUSY DF DFBUSY

load_deps() {
    local t rest
    while read -r t rest; do
        [ -n "$t" ] && DEPS[$t]="${rest}"
    done < <(python3 -I "${HERE}/depgraph.py" --deps ${TARGETS} 2>/dev/null)
    while read -r t rest; do
        [ -n "$t" ] && DF[$t]="${rest}"
    done < <(python3 -I "${HERE}/depgraph.py" --dockerfiles ${TARGETS} 2>/dev/null)
}

# Targets over the same Dockerfile share its stages — pytorch and
# pytorch-wheel are `final` and `wheel` over one builder — so running
# them concurrently compiles the same objects twice.
#
# Not a dependency: neither consumes the other, and ordering between
# them is free either way. It is mutual exclusion, so it lives here
# rather than as an edge in the graph.
#
# Serialised, NOT pinned to one node. The compiler cache is shared
# fleet-wide over WebDAV, so the second build hits whatever the first
# wrote wherever it runs. Measured on the gfx1250 run that prompted
# this, where the two ran concurrently on different nodes: pytorch took
# 2533 sccache hits against 186 misses, while pytorch-wheel — racing it
# for the same objects, neither having written them yet — managed 1918
# hits against 801. Ordering is what recovers those 615; co-location
# would have bought nothing extra and would have wasted a node.
df_busy() {
    local t="$1" f="${DF[$t]:-}"
    [ -n "$f" ] || return 1
    [ -n "${DFBUSY[$f]:-}" ]
}

# Only deps that this run will itself build gate scheduling. An edge to
# something outside TARGETS is satisfied from the registry.
blocking_deps() {
    local t="$1" d out=""
    for d in ${DEPS[$t]:-}; do
        case " ${TARGETS} " in
            *" $d "*) out="${out} $d" ;;
        esac
    done
    printf '%s' "${out# }"
}

ready_targets() {
    local t d ok
    for t in ${TARGETS}; do
        [ "${STATE[$t]}" = pending ] || continue
        # Deferred, not skipped: it becomes ready as soon as the
        # sibling over its Dockerfile finishes.
        df_busy "$t" && continue
        ok=1
        for d in $(blocking_deps "$t"); do
            [ "${STATE[$d]}" = done ] || { ok=0; break; }
        done
        [ "$ok" = 1 ] && printf '%s %s\n' "$(cost_of "$t")" "$t"
    done | sort -rn | awk '{print $2}'
}

free_nodes() {
    local n
    for n in "${ranked[@]}"; do
        [ -z "${BUSY[$n]:-}" ] && printf '%s\n' "$n"
    done
}

launch() {
    local t="$1" node="$2" mk
    mk=$(make_target "$t")
    [ "$PUSH" = 0 ] && mk="${mk/push-/build-}"
    : > "/tmp/balance-$t.log"
    echo "   $node: starting $t"
    if [ "$STREAM" = 1 ]; then
        BUILDKIT_PROGRESS=plain make "$mk" BUILDER="$node" \
            > "/tmp/balance-$t.log" 2>&1 &
    else
        make "$mk" BUILDER="$node" > "/tmp/balance-$t.log" 2>&1 &
    fi
    local pid=$!
    RUNTGT[$pid]="$t"; RUNNODE[$pid]="$node"; BUSY[$node]="$t"
    [ -n "${DF[$t]:-}" ] && DFBUSY[${DF[$t]}]="$t"
    STATE[$t]=running
    if [ "$STREAM" = 1 ]; then
        tail -F -n +1 "/tmp/balance-$t.log" 2>/dev/null \
            | sed -u "s/^/$(printf '%-14s' "$t") | /" &
        TAILPIDS+=($!)
    fi
}

run_dag() {
    local t node rc=0 fpid prc n
    TAILPIDS=()
    score_all
    mapfile -t ranked < <(rank_nodes)
    if [ "${#ranked[@]}" -eq 0 ]; then
        echo "balance: no node has ${MIN_MEM_GB}GB free; refusing to schedule" >&2
        return 1
    fi
    for t in ${TARGETS}; do STATE[$t]=pending; done
    for n in "${ranked[@]}"; do BUSY[$n]=""; done
    load_deps

    echo "── scheduling ${TARGETS// /, }"
    for n in "${ranked[@]}"; do printf '     %-14s score=%s\n' "$n" "${SCORE[$n]:-0}"; done

    while :; do
        # Fill every idle node with whatever is eligible now.
        local placed=1
        while [ "$placed" = 1 ]; do
            placed=0
            for t in $(ready_targets); do
                # Re-checked here, not just in ready_targets. That list
                # is a command substitution, evaluated once before any
                # of these launches ran — so a sibling claiming the
                # Dockerfile mid-loop is invisible to it, and both were
                # launched anyway. Measured: all three pairs overlapped.
                df_busy "$t" && continue
                node=$(free_nodes | head -1)
                [ -n "$node" ] || break
                launch "$t" "$node"
                placed=1
            done
        done

        # Nothing running: either everything is done, or what is left
        # can never become ready.
        if [ "${#RUNTGT[@]}" -eq 0 ]; then
            local stuck=""
            for t in ${TARGETS}; do
                [ "${STATE[$t]}" = pending ] && stuck="${stuck} $t"
            done
            if [ -n "${stuck// /}" ]; then
                echo "balance: cannot schedule${stuck} — unmet dependencies" >&2
                rc=1
            fi
            break
        fi

        # Block until some build exits; -p gives us which one, so a
        # node is freed the moment its own target ends rather than at a
        # barrier. Requires bash 4.3+ for -n and 5.1+ for -p.
        if wait -n -p fpid; then prc=0; else prc=$?; fi
        [ -n "${fpid:-}" ] || continue
        t="${RUNTGT[$fpid]:-}"
        [ -n "$t" ] || continue        # a stream tail exited, not a build
        node="${RUNNODE[$fpid]}"
        unset "RUNTGT[$fpid]" "RUNNODE[$fpid]"
        BUSY[$node]=""
        [ -n "${DF[$t]:-}" ] && DFBUSY[${DF[$t]}]=""
        if [ "$prc" = 0 ]; then
            STATE[$t]=done
            echo "   $node: finished $t"
        else
            STATE[$t]=failed
            rc=1
            echo "   $node: FAILED $t (exit $prc)"
            grep -aiE '^ERROR|error:' "/tmp/balance-$t.log" 2>/dev/null \
                | grep -v 'cache importer\|rpc error' | tail -3 | sed 's/^/     /'
            # Let the in-flight builds finish rather than killing them:
            # they are independent of this one, and a half-pushed image
            # is worse than a wasted minute.
            break
        fi
    done

    for n in "${!RUNTGT[@]}"; do wait "$n" 2>/dev/null || rc=1; done
    for n in "${TAILPIDS[@]:-}"; do [ -n "$n" ] && kill "$n" 2>/dev/null; done
    return "$rc"
}

# Plan only: the same eligibility walk, with cost_of standing in for
# real durations, so a dry run shows the order and the placement
# without building. Prints the "<target> -> <node>" form; perfreport
# parses that as well as the "<node>: starting <target>" the live path
# emits.
plan_dag() {
    local t d ok node i=0 wave=0
    score_all
    mapfile -t ranked < <(rank_nodes)
    [ "${#ranked[@]}" -gt 0 ] || { echo "balance: no usable node" >&2; return 1; }
    for t in ${TARGETS}; do STATE[$t]=pending; done
    load_deps
    while :; do
        local batch=()
        for t in $(ready_targets); do batch+=("$t"); done
        [ "${#batch[@]}" -gt 0 ] || break
        wave=$((wave + 1))
        echo "── wave ${wave}"
        i=0
        # One target per Dockerfile per wave, matching run_dag's mutual
        # exclusion. Without this the plan shows pytorch and
        # pytorch-wheel side by side in one wave, which is exactly the
        # concurrency the scheduler now refuses.
        local seen_df=""
        for target in "${batch[@]}"; do
            local f="${DF[$target]:-}"
            if [ -n "$f" ]; then
                case " ${seen_df} " in *" $f "*) continue ;; esac
                seen_df="${seen_df} $f"
            fi
            node="${ranked[$((i % ${#ranked[@]}))]}"
            i=$((i + 1))
            # This exact spelling is also what perfreport's
            # read_placement parses for stage-format logs, and
            # check-contracts.py asserts the two still agree.
            echo "   $target -> $node   (log: /tmp/balance-$target.log)"
            STATE[$target]=done
        done
    done
    local left=""
    for t in ${TARGETS}; do [ "${STATE[$t]}" = pending ] && left="${left} $t"; done
    [ -n "${left// /}" ] && { echo "balance: unschedulable:${left}" >&2; return 1; }
    return 0
}

# --best: resolve a single node for callers that have one target to
# place, such as the Makefile turning BUILDER=snoc-pool into a concrete
# builder. Falls back to the first configured node so a scoring failure
# degrades to "pick something" rather than breaking the build.
if [ "$BEST_ONLY" = 1 ]; then
    score_all
    best=$(rank_nodes | head -1)
    echo "${best:-${NODES%% *}}"
    exit 0
fi

# Every image these targets resolve from the registry, minus the ones
# this run publishes itself, checked before a single build starts.
#
# Worth the two bake --print calls it costs. Without it a missing input
# surfaces as a target failing at step 1 of 7 after the scheduler has
# already committed, and under the old per-node queues that took the
# rest of that node's list down with it — which is exactly how a
# gfx1250 run lost snoc-think while strix built for another 40 minutes.
if ! python3 -I "${HERE}/depgraph.py" --preflight ${TARGETS}; then
    echo "balance: refusing to schedule against missing inputs" >&2
    exit 1
fi

if [ "$DRY_RUN" = 1 ]; then
    plan_dag || exit 1
    echo "balance: plan complete"
    exit 0
fi

run_dag || { echo "balance: build failed" >&2; exit 1; }

echo "balance: all stages complete"
