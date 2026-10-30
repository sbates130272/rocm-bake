#!/bin/bash
# bench.sh - measure build time under frozen, cold, warm and hot cache
# conditions.
#
# The four scenarios exist because they fail differently, and only one
# of them is the common case. They nest: each is the one below it plus
# one more cache taken away.
#
#   frozen  Cold, and Zot holds no pull-through copy of the upstream
#           base image either, so the layers egress from Docker Hub.
#           What a brand-new site costs, before any of this fleet's
#           infrastructure has warmed up. The ROCm base is a single
#           8.67GB layer, so the difference between frozen and cold is
#           essentially WAN bandwidth — and it is the number to quote
#           when someone asks what the local registry is worth.
#   cold    No layer cache, no compiler cache, but the base image is
#           resident in Zot. What a new build node or a changed base
#           image costs. Upper bound on compile cost.
#   warm    Layer and compiler caches are populated, but
#           SOURCE_DATE_EPOCH moved — which is what every new commit
#           does, including commits that touch nothing this image
#           depends on. This is the case that matters day to day.
#   hot     Same commit, everything cached. Lower bound; mostly a check
#           that the caches are being read at all.
#
# frozen and cold runs are isolated by SCCACHE_WEBDAV_KEY_PREFIX so they
# never pollute or evict the fleet's shared compiler cache. The prefix
# is a directory in the WebDAV store and is deleted afterwards.
# Verified: writes land under /var/cache/sccache-webdav/<prefix>/.
#
# Results append as JSON lines, one per build, so a partial run is still
# usable and successive nights accumulate rather than overwrite.
#
# Usage:
#   ./bench.sh <scenario> [target ...]     run one scenario
#   ./bench.sh all                         frozen, cold, warm, then hot
#   ./bench.sh report                      render results as markdown
#   ./bench.sh json [out.json]             aggregate for the docs site

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# /var/tmp, not /tmp: /tmp is a 16GB tmpfs here and a single base image
# export already filled it once.
BENCH_DIR="${BENCH_DIR:-/var/tmp/rocm-bench}"
RESULTS="${BENCH_DIR}/results.jsonl"
LOGS="${BENCH_DIR}/logs"
mkdir -p "${LOGS}"

BUILDER="${BUILDER:-snoc-think}"
TARGETS_DEFAULT="pytorch-base triton-wheel pytorch"

# The arch every run in this invocation is measured at, recorded with
# the result. Builds for different GPUs are not comparable — vLLM's
# kernel prebuild is ~50 min on gfx950 and hours on gfx1201, and AITER
# drops to PREBUILD_KERNELS=0 on RDNA — so pooling them would be the
# same mistake as pooling runs at different MAX_JOBS, which the report
# already guards against for exactly this reason.
#
# Resolved through make rather than defaulted here: the Makefile
# already takes PYTORCH_ROCM_ARCH from the environment before falling
# back to the bake default, so asking it gives exactly the answer a
# build would use. A literal "gfx950" in this file would be a second
# copy of a value rocm-bake.hcl owns — the drift check-defaults.py
# exists to catch.
#
# Exported, not just read, so make and bake downstream see it. That is
# what makes `PYTORCH_ROCM_ARCH=gfx1201 ./bench.sh cold ...` actually
# measure gfx1201 rather than silently measuring the default.
BENCH_ARCH=$(make -s --eval='__a:;@printf "%s" "$(PYTORCH_ROCM_ARCH)"' __a 2>/dev/null)
export PYTORCH_ROCM_ARCH="${BENCH_ARCH}"

export no_proxy="${no_proxy:-localhost,127.0.0.1,::1,.ts.net,.local,10.0.0.0/8,100.64.0.0/10}"
export NO_PROXY="${no_proxy}"

log() { printf '[bench %(%H:%M:%S)T] %s\n' -1 "$*"; }

# Refuse to run while a real build is in flight: two builds on one node
# contend for cores and memory, and every timing from this harness would
# be meaningless. Better to skip a slot than record a bad number.
# Ask the builder, not the process table. `pgrep -f` matches a pattern
# anywhere in a command line — including the command line of whatever
# invoked this script, and of this function's own subshell — so the
# previous version reported busy against itself. It was also
# fleet-wide: a build on any node blocked a benchmark on an idle one,
# and these builders are shared with another project.
#
# buildx reports what a specific builder is actually solving, which is
# the question that matters: can this node take work now.
busy() {
    local running
    running=$(timeout 30 docker buildx history ls --builder "$BUILDER" \
        --filter status=running --format '{{.Name}}' 2>/dev/null | head -1)
    [ -n "$running" ]
}

# One-minute load average on the node that will run the build.
node_load() {
    if [ "${BUILDER}" = "snoc-strix" ]; then
        cut -d' ' -f1 /proc/loadavg
    else
        timeout 10 ssh -n -o BatchMode=yes \
            "${BUILDER/snoc-think/snoc-thinkstation}" \
            "cut -d' ' -f1 /proc/loadavg" 2>/dev/null
    fi
}

# MemAvailable on the node that will run the build, in whole GB.
# Same local-or-ssh split as the load sampling below: snoc-strix is
# this host, everything else is remote.
node_mem_avail_gb() {
    if [ "${BUILDER}" = "snoc-strix" ]; then
        awk '/^MemAvailable:/ {printf "%d", $2/1048576}' /proc/meminfo
    else
        timeout 10 ssh -n -o BatchMode=yes \
            "${BUILDER/snoc-think/snoc-thinkstation}" \
            "awk '/^MemAvailable:/ {printf \"%d\", \$2/1048576}' /proc/meminfo" \
            2>/dev/null
    fi
}

# ── frozen: evict the pull-through copy of the base image ────────
# Read a default out of rocm-bake.hcl rather than keeping a copy here.
# Same awk as the Makefile's BAKE_DEFAULTS block and for the same
# reason: that file is the single source for every value a build reads,
# and a second copy is drift waiting to happen. POSIX awk only.
bake_default() {
    awk -v want="$1" '
        /^variable[ \t]*"/ {
            n = $0; sub(/^variable[ \t]*"/, "", n); sub(/".*/, "", n) }
        n == want && /default[ \t]*=[ \t]*"/ {
            v = $0; sub(/^.*default[ \t]*=[ \t]*"/, "", v); sub(/".*/, "", v)
            print v; exit }' rocm-bake.hcl
}

# The upstream images the graph pulls through Zot. Only the ROCm base is
# worth evicting: it is 8.67GB in a single layer, against a few hundred
# megabytes for everything else the build fetches from a registry.
FROZEN_REPO="${FROZEN_REPO:-rocm/dev-ubuntu-26.04}"

# Delete Zot's cached manifest for an upstream tag, so the next pull
# re-syncs it from Docker Hub.
#
# Through the registry API, not by deleting files under zot's rootDir:
# the harness runs on whichever node BUILDER names, and only one of
# those is the machine zot lives on. The API works from all of them.
#
# Absent is the state we want, so a tag with no manifest is a success,
# not a failure. A 405 is not: it means zot was built or configured
# without delete support, and the run that follows would silently be a
# cold run wearing a frozen label. That distinction is recorded in the
# result line.
zot_evict() {
    local repo="$1" tag="$2" reg="$3" digest
    digest=$(curl -sI --max-time 30 \
        -H 'Accept: application/vnd.oci.image.index.v1+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        "http://${reg}/v2/${repo}/manifests/${tag}" 2>/dev/null \
        | awk 'tolower($1) == "docker-content-digest:" { print $2 }' \
        | tr -d '\r')
    if [ -z "${digest}" ]; then
        log "  ${repo}:${tag} is not resident in ${reg} — already frozen"
        return 0
    fi
    if curl -sf --max-time 60 -X DELETE -o /dev/null \
            "http://${reg}/v2/${repo}/manifests/${digest}"; then
        log "  evicted ${repo}:${tag} (${digest:0:19}) from ${reg}"
        return 0
    fi
    log "  WARNING: could not delete ${repo}:${tag} from ${reg}"
    log "           zot needs deletes enabled; this run is cold, not frozen"
    return 1
}

# Evicting from zot is necessary but not sufficient. buildkit keeps the
# blobs it has already pulled in its own content store, so a build whose
# base is still there never touches a registry at all and frozen would
# measure exactly what cold measures.
#
# This empties that store for the whole node, including any other
# project's layers — these builders are shared. It is the price of the
# measurement, and it is why frozen is not in the nightly rotation by
# default. BENCH_FROZEN_PRUNE=0 skips it, which gives a frozen run that
# only re-pulls what buildkit happens to have dropped.
buildkit_prune() {
    [ "${BENCH_FROZEN_PRUNE:-1}" = 0 ] && { log "  skipping buildkit prune"; return 0; }
    log "  pruning buildkit's content store on ${BUILDER} (shared with other projects)"
    timeout 600 docker buildx prune -af --builder "${BUILDER}" >/dev/null 2>&1
}

# ── one build ────────────────────────────────────────────────────
# Emits a JSON line. Never aborts the harness: a failing build is a
# result, and recording it is the point.
bench_run() {
    local scenario="$1" target="$2" extra="${3:-}" extra_env=""
    local stamp; stamp=$(date -u +%Y%m%dT%H%M%SZ)
    local log="${LOGS}/${scenario}-${target}-${stamp}.log"
    local epoch; epoch=$(git log -1 --format=%ct 2>/dev/null)
    local prefix="" frozen=""

    case "${scenario}" in
        frozen)
            # Cold, plus the registry. Everything the cold arm does, and
            # then the two stores that would otherwise hand the base
            # image over for free.
            prefix="bench-frozen-${stamp}"
            extra="${extra} --no-cache"
            frozen=ok
            zot_evict "${FROZEN_REPO}" "$(bake_default ROCM_VERSION)" \
                "$(bake_default REGISTRY)" || frozen=partial
            buildkit_prune
            ;;
        cold)
            prefix="bench-cold-${stamp}"
            extra="${extra} --no-cache"
            ;;
        warm)
            # What a new commit costs. Under the current design that is
            # nothing, and this scenario exists to keep it that way.
            #
            # It used to force SDE_BASE, SDE_PYTORCH and the rest to
            # HEAD's commit time plus a minute, back when the Makefile
            # derived them from `git log -1 -- Dockerfile.<image>` and
            # a new commit really did move them. The Makefile now pins
            # them to a constant, SDE_EPOCH, so no commit can move
            # them — and overriding them here priced something the
            # pipeline cannot do to itself. Measured at the time: 220s
            # against hot's 3s, for a condition only this harness could
            # create.
            #
            # So warm builds exactly what hot builds, and the result is
            # the assertion rather than the number: if warm ever
            # diverges from hot, some per-commit value has found its
            # way back into the image digest. That has happened twice
            # (HEAD's timestamp, then a squash collapsing the per-image
            # timestamps), which is why it is worth a standing check.
            :
            ;;
        hot) ;;
    esac

    log "${scenario}/${target} on ${BUILDER} -> $(basename "${log}")"

    # The builders are shared with other projects — a concurrent vLLM
    # build on snoc-strix skewed the first timings taken here. Record
    # the node's load so a contaminated run is visible in the results
    # rather than quietly wrong.
    local load
    if [ "${BUILDER}" = "snoc-strix" ]; then  # this host
        load=$(cut -d' ' -f1 /proc/loadavg)
    else
        load=$(timeout 10 ssh -n -o BatchMode=yes "${BUILDER/snoc-think/snoc-thinkstation}" \
               "cut -d' ' -f1 /proc/loadavg" 2>/dev/null)
    fi

    # Wait for memory to settle before starting.
    #
    # MAX_JOBS is derived inside the build from MemAvailable, sampled
    # once when the compile step starts and fixed for the whole build.
    # Launching a benchmark straight after another one samples it while
    # buildkit is still flushing the previous build's layers: a cold
    # pytorch started that way derived MAX_JOBS=3 on a 30GB node that
    # reported 18GB free two minutes later, and a cold time at 3 jobs
    # is not comparable to one at 10. Across slots this node has
    # produced 3, 4, 7 and 10 — mostly scheduling artefact, not node.
    #
    # Polling until two consecutive reads agree keeps the derivation
    # (which is the thing being exercised) while removing the artefact.
    local mem prev=0 settled=0
    for _ in $(seq 1 "${MEM_SETTLE_TRIES:-18}"); do
        mem=$(node_mem_avail_gb)
        [ -n "${mem}" ] || break
        if [ "${mem}" -ge "${MIN_MEM_GB:-8}" ] && \
           [ "$(( mem > prev ? mem - prev : prev - mem ))" -le 2 ] && \
           [ "${prev}" != 0 ]; then
            settled=1; break
        fi
        prev="${mem}"
        sleep 10
    done
    if [ "${settled}" = 1 ]; then
        log "  memory settled at ${mem}GB available"
    else
        log "  memory did not settle (last ${mem:-?}GB); MAX_JOBS may be low"
    fi

    # Settling is necessary but not sufficient, and on its own it does
    # not buy comparability. MAX_JOBS is sampled when the *compile*
    # step starts, by which point the build's own earlier steps —
    # fetching the base image, the checkout, aotriton — have taken
    # memory of their own: a cold pytorch that settled at 21GB still
    # derived 5, not the 10 the same node gives a hot run whose early
    # steps are all cache hits. The derivation therefore tracks how
    # much work precedes the compile, which differs by scenario, so
    # cold and hot are measured at different job counts by
    # construction.
    #
    # Set BENCH_MAX_JOBS to pin it when the point is to compare
    # scenarios. Left unset the derivation runs, which is what to use
    # when the point is to exercise the derivation itself.
    local pin_jobs=""
    if [ -n "${BENCH_MAX_JOBS:-}" ]; then
        pin_jobs="--set *.args.MAX_JOBS=${BENCH_MAX_JOBS}"
        log "  MAX_JOBS pinned to ${BENCH_MAX_JOBS}"
    fi

    # Force the compile stage to run again without altering the build.
    #
    # Until now the only way to make a hot build actually compile was
    # to give MAX_JOBS a value it had not had before, since changing a
    # build arg changes the layer key. That conflated the cache-buster
    # with the variable under test: each job count was usable exactly
    # once per tree state, which is why almost every width in the
    # report has n=1 and why the 133s at 32 jobs could not be checked.
    #
    # no-cache-filter asks buildkit to ignore cache for one stage and
    # nothing else, so the same width can be measured repeatedly. It
    # has to arrive as an HCL override file: bake accepts the attribute
    # there, but `--set target.no-cache-filter=` is silently dropped
    # (tested on buildx 0.30.1 — it does not appear in --print).
    #
    # Note this invalidates every step in the stage, not just the
    # compile: the git clone, the sccache download and the pip installs
    # all re-run. That is visible in the build log.
    #
    # Whether it changes the *timing* enough to matter is not
    # established. It looked that way from two samples — 403s and 429s
    # against a 267s pin-change run — but with every converged run
    # counted, the pin-change method spans 203-617s and contains the
    # forced range entirely. pytorch's hot time varies about 3x
    # run-to-run whatever forces the compile, and that swamps any
    # method effect this data could show.
    #
    # Treat the two as interchangeable until something separates them.
    local nocache=""
    if [ -n "${BENCH_FORCE_COMPILE:-}" ]; then
        local hcl="/tmp/bench-nocache-$$.hcl"
        printf 'target "%s" {\n  no-cache-filter = ["builder"]\n}\n' \
            "${target}" > "${hcl}"
        nocache="-f ${hcl}"
        log "  forcing the builder stage to recompile (no-cache-filter)"
    fi

    local start end rc
    start=$(date +%s)
    (
        export SOURCE_DATE_EPOCH="${epoch}"
        [ -n "${prefix}" ] && export SCCACHE_WEBDAV_KEY_PREFIX="${prefix}"
        # shellcheck disable=SC2086
        # build-, not push-: the docker credential helper on this host
        # fails with "gpg: public key decryption failed" outside an
        # interactive session, so writes to the registry are impossible
        # unattended. cache-to is cleared for the same reason — it is a
        # registry write. Reads (cache-from) are anonymous and still
        # work, so cache *hits* are measured faithfully; what these
        # numbers exclude is push time, which is not what we are timing.
        BUILDKIT_PROGRESS=plain TELEMETRY=1 \
            make "build-$(mk_name "${target}")" BUILDER="${BUILDER}" \
            ${extra_env} \
            BAKE_EXTRA="--set *.cache-to= ${nocache} ${pin_jobs} ${extra}"
    ) > "${log}" 2>&1
    rc=$?
    end=$(date +%s)

    # Clean the isolated prefix immediately; a cold run writes the whole
    # compile output and these add up fast.
    if [ -n "${prefix}" ]; then
        sudo rm -rf "/var/cache/sccache-webdav/${prefix}" 2>/dev/null
    fi

    # Load again now the build is over. One sample at t=0 does not
    # characterise a run lasting ten to twenty minutes: the slowest
    # cold triton on record, 1168s against a 432-669s cluster, *began*
    # at load 0.99 — the lowest of its group — and the node's
    # fifteen-minute average reached 41 on 32 cores by the time it
    # finished. Contention arriving after the start was invisible, and
    # it is the best candidate for the spread these numbers carry.
    local load_end; load_end=$(node_load)
    record "${scenario}" "${target}" "$((end - start))" "${rc}" "${log}" \
        "${load:-0}" "${load_end:-0}" "${frozen}"
}

# bake target -> make target suffix, matching balance.sh's mapping.
mk_name() {
    case "$1" in
        pytorch-base)  echo base ;;
        pytorch)       echo pytorch ;;
        pytorch-run)   echo runtime ;;
        pytorch-wheel) echo torch-wheel ;;
        triton-wheel)  echo triton-wheel ;;
        aiter-wheel)   echo aiter-wheel ;;
        *)             echo "$1" ;;
    esac
}

# Pull the numbers that explain the duration out of the log, so the
# result line stands on its own without re-reading it.
record() {
    local scenario="$1" target="$2" secs="$3" rc="$4" log="$5" load="$6" load_end="${7:-0}"
    # "ok" when the registry copy was really evicted, "partial" when the
    # delete was refused, empty for every other scenario. Without it a
    # frozen row that silently ran cold is indistinguishable from one
    # that did not, and it would drag the published average down.
    local frozen="${8:-}"
    local cached total hits misses reqs maxjobs fail=""

    # Anchor to this repo's Dockerfile. The builders are shared, and
    # telemetry attributes any build running on the node at the time —
    # a run of ours once collected "vllm-lmcache/Dockerfile.nixl" from
    # an unrelated project. A bare tail -1 would record its numbers as
    # ours and silently corrupt the benchmark.
    # Count real build steps, not buildkit vertices. Telemetry's
    # "5/12 steps cached" counts loading the dockerfile, the
    # dockerignore, metadata and exporting among the 12 — none of which
    # can ever be cached, so the ratio reads far worse than reality. A
    # fully-cached base build reports 5/12 while every one of its five
    # actual steps was CACHED. Here a step is a vertex buildkit labels
    # [n/m], and cached means that same vertex reported CACHED.
    #
    # The vertex name carries a bake-target prefix whenever the build
    # has more than one target, and pytorch now always does — it pulls
    # triton-wheel in as a named context. So buildkit emits
    # "[pytorch builder 4/11]" and "[triton-wheel builder 9/11]" where
    # a single-target build emits a bare "[builder 9/11]". The regex
    # below only allowed the bare form, so a pytorch benchmark counted
    # zero steps out of zero and recorded 0/0.
    #
    # Count only vertices belonging to the target being measured:
    # strip an optional leading "<target> ", then require what remains
    # to be "<stage> n/m". Another target's prefix leaves two words
    # before the numbers and fails to match, which keeps triton's
    # steps out of a pytorch result.
    read -r cached total < <(
        awk -v tgt="${target}" '
            match($0, /^#[0-9]+ \[[^]]*[0-9]+\/[0-9]+\]/) {
                hdr = substr($0, RSTART, RLENGTH)
                sub(/^#[0-9]+ \[/, "", hdr); sub(/\]$/, "", hdr)
                sub("^" tgt " ", "", hdr)
                if (hdr !~ /^[a-z-]* *[0-9]+\/[0-9]+$/) next
                id = substr($1, 2); step[id] = 1
            }
            match($0, /^#[0-9]+ CACHED/) {
                id = substr($1, 2); hit[id] = 1
            }
            END {
                t = 0; c = 0
                for (i in step) { t++; if (i in hit) c++ }
                print c, t
            }' "${log}")
    # sccache's stats come from the build output, mapped to the target
    # by buildkit's step number.
    #
    # Not from ^Cache hits: the lines carry a buildkit prefix
    # ("#32 178.7 Cache hits  5674"), so that anchor never matched and
    # every run recorded 0 hits.
    #
    # And not from the telemetry summary either, which was the first
    # fix and was wrong. A pytorch build prints two stats blocks, its
    # own and triton's, and telemetry attributes triton's numbers to
    # both images: a run whose pytorch compile reported 5674 hits was
    # summarised as "rocm-pytorch-build/pytorch/...: sccache 361
    # hits/0 misses", which is triton's figure. Trusting it moved the
    # bug rather than fixing it.
    #
    # Buildkit does carry the association, in the step number: the
    # vertex header "#32 [pytorch builder 10/11] RUN ..." ties step 32
    # to pytorch, and every stats line from that step is prefixed
    # "#32 ". Mapping headers to targets and then selecting that
    # target's steps is exact, with no heuristic about ordering or
    # magnitude.
    read -r hits misses reqs < <(
        awk -v tgt="${target}" '
            # Vertex header: remember which target owns this step.
            match($0, /^#[0-9]+ \[[^]]*\]/) {
                hdr = substr($0, RSTART, RLENGTH)
                id = substr($1, 2)
                sub(/^#[0-9]+ \[/, "", hdr); sub(/\]$/, "", hdr)
                # Ours if the header carries this bake target as a
                # prefix, or carries no prefix at all — a single-target
                # build emits a bare "[builder  9/11]". Testing for an
                # absent prefix with "no space in the header" was
                # wrong: that bare form has one, so a cold triton
                # recorded 0/0.
                stripped = hdr
                sub("^" tgt " ", "", stripped)
                owner[id] = (stripped ~ /^[a-z-]* *[0-9]+\/[0-9]+$/) ? 1 : 0
            }
            # Stats line from a step we own. Last block wins.
            /^#[0-9]+ [0-9.]+ (Cache hits|Cache misses|Compile requests) +[0-9]+$/ {
                id = substr($1, 2)
                if (!(id in owner) || !owner[id]) next
                if ($3 == "Compile" && $4 == "requests") r = $NF
                else if ($3 == "Cache" && $4 == "hits")   h = $NF
                else if ($3 == "Cache" && $4 == "misses") m = $NF
            }
            END { print h+0, m+0, (h+0)+(m+0) }' "${log}")
    maxjobs=$(grep -ahoE 'MAX_JOBS=[0-9]+' "${log}" | tail -1 | cut -d= -f2)

    if [ "${rc}" != 0 ]; then
        # First line that looks like a cause, not the generic wrapper.
        fail=$(grep -ahE 'Killed signal|cannot allocate|Timed out waiting|^ERROR: failed to solve' "${log}" \
               | head -1 | cut -c1-160)
    fi

    # Values go through the environment, not string interpolation: a
    # failure message containing a quote or backslash would otherwise
    # produce invalid Python and lose the whole result line.
    B_SCENARIO="${scenario}" B_TARGET="${target}" B_BUILDER="${BUILDER}" \
    B_ARCH="${BENCH_ARCH}" \
    B_SECS="${secs}" B_RC="${rc}" B_CACHED="${cached:-0}" B_TOTAL="${total:-0}" \
    B_REQS="${reqs:-0}" B_HITS="${hits:-0}" B_MISSES="${misses:-0}" \
    B_JOBS="${maxjobs:-0}" B_FAIL="${fail}" B_LOG="${log}" B_LOAD="${load:-0}" \
    B_LOAD_END="${load_end:-0}" B_FROZEN="${frozen}" \
    python3 -I - <<'PY' >> "${RESULTS}"
import json, os, datetime
def num(k):
    try: return int(os.environ.get(k) or 0)
    except ValueError: return 0
print(json.dumps({
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "scenario": os.environ["B_SCENARIO"],
    "target": os.environ["B_TARGET"],
    "builder": os.environ["B_BUILDER"],
    "arch": os.environ.get("B_ARCH") or "gfx950",
    "seconds": num("B_SECS"),
    "rc": num("B_RC"),
    "steps_cached": num("B_CACHED"),
    "steps_total": num("B_TOTAL"),
    "sccache_requests": num("B_REQS"),
    "sccache_hits": num("B_HITS"),
    "sccache_misses": num("B_MISSES"),
    "max_jobs": num("B_JOBS"),
    "node_load_at_start": float(os.environ.get("B_LOAD") or 0),
    "node_load_at_end": float(os.environ.get("B_LOAD_END") or 0),
    "registry_evicted": os.environ.get("B_FROZEN") or None,
    "failure": os.environ.get("B_FAIL") or None,
    "log": os.environ["B_LOG"],
}))
PY
    log "  -> ${secs}s rc=${rc} steps=${cached:-0}/${total:-0} sccache=${hits:-0}/${reqs:-0}"
}

# ── report ───────────────────────────────────────────────────────
render_report() {
    python3 -I - "${RESULTS}" <<'PY'
import json, sys, collections
rows = []
try:
    for line in open(sys.argv[1]):
        line = line.strip()
        if line:
            rows.append(json.loads(line))
except FileNotFoundError:
    print("No results yet."); raise SystemExit

if not rows:
    print("No results yet."); raise SystemExit

print("| scenario | target | arch | time | steps cached | sccache hit "
      "| jobs | result |")
print("|---|---|---|---|---|---|---|---|")
for r in rows:
    secs = r["seconds"]
    t = f"{secs//60}m{secs%60:02d}s" if secs >= 60 else f"{secs}s"
    steps = f'{r["steps_cached"]}/{r["steps_total"]}' if r["steps_total"] else "-"
    req = r["sccache_requests"]
    hit = f'{100*r["sccache_hits"]//req}%' if req else "-"
    res = "ok" if r["rc"] == 0 else "FAIL"
    # A frozen row the registry refused to evict for is really a cold
    # row. Say so in the table rather than letting it read as frozen.
    scen = r["scenario"]
    if scen == "frozen" and r.get("registry_evicted") != "ok":
        scen = "frozen*"
    print(f'| {scen} | {r["target"]} | {r.get("arch", "gfx950")} '
          f'| {t} | {steps} | {hit} | {r["max_jobs"] or "-"} | {res} |')

print()
# Two caches, two ratios. Dividing cold by whichever hot run came last
# conflated them and printed "2297.3x" — the cold run against a 3s
# layer-cache hit that compiled nothing at all. The compiler cache and
# the layer cache answer different questions and are worth separating:
#
#   compiler cache  cold vs a hot run that still compiled (sccache
#                   served the requests instead of the compiler)
#   layer cache     that run vs a hot run where buildkit skipped the
#                   compile step outright, so sccache saw no requests
# Keyed by (target, builder), and the best run of each kind rather
# than the last. Two reasons. Nodes differ by 16x in memory, so a cold
# run on the 15GB box against a hot run on the 30GB one is not a
# ratio. And "last" picks up one-offs — the run that re-established
# every digest after the epoch changed, or one taken before the
# compiler cache had converged — which flatter cold and understate the
# cache. The best run of each kind is the one worth quoting.
# Keyed by (target, builder, MAX_JOBS), and a ratio is printed only
# when cold and hot were measured at the same job count.
#
# Two earlier attempts got this wrong. Taking the best run of each kind
# looked principled but pulls in opposite directions: cold runs vary
# far more than hot ones, so min(cold) picks an outlier that shrinks
# the ratio while min(hot) picks one that inflates it. Switching to the
# median then exposed the real fault — the pools were mixing runs at
# different job counts. "pytorch hot, n=12, 244-1366s" spans pins 5 to
# 15 and runs taken before the compiler cache had converged; no average
# over that means anything.
#
# Job count is not a nuisance parameter here, it is the dominant one:
# the same cold pytorch is 6892s at 5 jobs and 2342s at 32. So it
# belongs in the key, and cold at one width divided by hot at another
# is not a ratio at all.
#
# frozen is a third pool against the same key. It answers a question
# neither cache does: what the local registry is worth. frozen divided
# by cold is the pull-through saving — almost entirely the 8.67GB base
# layer, so it tracks the link rather than the build. A frozen row whose
# registry eviction was refused is dropped here rather than averaged in:
# it is a cold run with the wrong label, and counting it would quietly
# drive the ratio towards 1.0 and make the registry look worthless.
import statistics
frozen, cold, compiled, skipped = {}, {}, {}, {}
for r in rows:
    if r["rc"] != 0:
        continue
    # Arch is in the key for the same reason MAX_JOBS is: it is a
    # dominant parameter, not a nuisance one. vLLM's kernel prebuild is
    # ~50 min on gfx950 and hours on gfx1201, and AITER drops to
    # PREBUILD_KERNELS=0 on RDNA, so cold on one arch over hot on
    # another is not a ratio. Rows predating the field are gfx950:
    # bench never set PYTORCH_ROCM_ARCH, so they used the bake default,
    # which has been gfx950 since c0d7830 (2026-10-26) — before the
    # oldest result here.
    key = (r["target"], r["builder"], r.get("arch", "gfx950"),
           r["max_jobs"] or 0)
    if r["scenario"] == "frozen":
        if r.get("registry_evicted") != "ok":
            continue
        d = frozen
    elif r["scenario"] == "cold":
        d = cold
    elif r["scenario"] == "hot":
        # Whether the compile step ran, judged on steps cached rather
        # than on sccache having reported anything. Rows written before
        # the sccache parser was fixed carry requests=0 because nothing
        # was recorded, not because nothing was compiled — two triton
        # rows at 529s and 218s have requests=0 and steps 0/3, so they
        # plainly compiled, and counting them as layer-cache hits
        # produced "layer cache a further 0x (-> 374s)".
        total = r["steps_total"] or 0
        reused = total and (r["steps_cached"] / total) >= 0.5
        d = skipped if reused else compiled
    else:
        continue
    d.setdefault(key, []).append(r["seconds"])   # file order: oldest first

def mid(d, key):
    """The most recent run at this key, not the best or the median.

    Each has been tried and each is wrong here. The minimum picks an
    outlier, and picking it on both sides biases the ratio in opposite
    directions. The median assumes the samples are drawn from one
    population, and they are not: this pipeline changed underneath its
    own measurements — the compiler cache converged partway through,
    and rows written before the sccache parser was fixed record no hit
    data at all. Averaging a run from before a fix with one from after
    describes a system that never existed.

    The question a ratio answers is what the cache buys *now*, so the
    newest sample is the right estimator, and n with the observed range
    is printed beside it so the spread stays visible.
    """
    v = d.get(key)
    return v[-1] if v else None

def spread(d, key):
    v = d.get(key) or []
    return f' [n={len(v)}, {min(v)}-{max(v)}s]' if len(v) > 1 else ''

shown = False
for key in sorted(set(cold) & set(compiled)):
    tgt, node, arch, jobs = key
    c, h = mid(cold, key), mid(compiled, key)
    line = f'{tgt} [{arch}] on {node} at {jobs} jobs: '
    # The registry saving comes first because it is the outermost
    # layer: it is what the fleet buys before any build cache exists.
    fz = mid(frozen, key)
    if fz and fz > c:
        line += (f'registry {fz/max(c,1):.1f}x ({fz}s{spread(frozen, key)} -> '
                 f'{c}s{spread(cold, key)}); ')
    line += (f'compiler cache {c/max(h,1):.1f}x ({c}s{spread(cold, key)} -> '
             f'{h}s{spread(compiled, key)})')
    lay = mid(skipped, key)
    # Only a saving if it is actually faster; otherwise the pools are
    # not what they claim and a ratio would mislead.
    if lay and lay < h:
        line += f'; layer cache a further {h/max(lay,1):.0f}x (-> {lay}s)'
    print(line)
    shown = True

# Anything measured at only one of the two widths is still worth
# showing, just not as a ratio.
singles = ((set(frozen) | set(cold) | set(compiled) | set(skipped))
           - (set(cold) & set(compiled)))
for key in sorted(singles):
    tgt, node, arch, jobs = key
    bits = [f'{lbl} {mid(d, key)}s{spread(d, key)}'
            for lbl, d in (("frozen", frozen), ("cold", cold),
                           ("hot", compiled),
                           ("hot/layer-only", skipped)) if key in d]
    print(f'{tgt} [{arch}] on {node} at {jobs} jobs: ' + ", ".join(bits)
          + '  (no same-width pair, so no ratio)')
    shown = True

if not shown:
    print("No comparable runs yet.")
PY
}

# ── json ─────────────────────────────────────────────────────────
# What the documentation site plots. The raw JSONL carries local log
# paths and a row per build going back as far as the file does; this
# emits a single document with the rows the site needs, plus the
# per-key summary it would otherwise have to recompute in the browser.
#
# Local paths are dropped rather than published. They are useless off
# this machine and they name directories under /var/tmp that nobody
# outside the fleet should be invited to reason about.
render_json() {
    python3 -I - "${RESULTS}" "${1:-}" <<'PY'
import json, sys, datetime

rows = []
try:
    with open(sys.argv[1]) as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
except FileNotFoundError:
    pass

PUBLIC = ("ts", "scenario", "target", "builder", "arch", "seconds", "rc",
          "steps_cached", "steps_total", "sccache_requests", "sccache_hits",
          "sccache_misses", "max_jobs", "node_load_at_start",
          "node_load_at_end", "registry_evicted")

# Rows predating the arch field are gfx950, for the reason the report
# gives: bench never set PYTORCH_ROCM_ARCH, so they used the bake
# default. Defaulted here rather than left null so the site never has
# to decide what a missing arch means.
runs = [{**{k: r.get(k) for k in PUBLIC},
         "arch": r.get("arch") or "gfx950"} for r in rows]

# The site plots scenario medians per (target, builder, max_jobs). A
# median rather than the most recent run, which is what the markdown
# report quotes: the report answers "what does the cache buy right
# now", where the newest sample is the right estimator. A chart is
# showing a distribution over time, and there the newest point is just
# the newest point — it goes in the series, not in the summary.
import statistics
buckets = {}
for r in runs:
    if r["rc"] != 0:
        continue
    if r["scenario"] == "frozen" and r.get("registry_evicted") != "ok":
        continue
    key = (r["target"], r["builder"], r["arch"], r["max_jobs"] or 0,
           r["scenario"])
    buckets.setdefault(key, []).append(r["seconds"])

summary = [
    {"target": t, "builder": b, "arch": a, "max_jobs": j, "scenario": s,
     "n": len(v), "median_seconds": int(statistics.median(v)),
     "min_seconds": min(v), "max_seconds": max(v)}
    for (t, b, a, j, s), v in sorted(buckets.items())
]

out = json.dumps({
    "generated": datetime.datetime.now(datetime.timezone.utc)
                 .isoformat(timespec="seconds"),
    "scenarios": ["frozen", "cold", "warm", "hot"],
    "runs": runs,
    "summary": summary,
}, indent=2)

dest = sys.argv[2] if len(sys.argv) > 2 else ""
if dest:
    with open(dest, "w") as fh:
        fh.write(out + "\n")
    print(f"{len(runs)} runs, {len(summary)} summary rows -> {dest}")
else:
    print(out)
PY
}

# ── entry ────────────────────────────────────────────────────────
scenario="${1:-all}"; shift || true
targets="${*:-${TARGETS_DEFAULT}}"

# Both reporting modes short-circuit the busy check: rendering reads a
# file and costs the builders nothing, so there is no reason to skip it
# because a build happens to be running.
if [ "${scenario}" = "report" ]; then
    render_report
    exit 0
fi

if [ "${scenario}" = "json" ]; then
    render_json "${1:-}"
    exit 0
fi

if busy; then
    log "a build is already running; skipping this slot"
    exit 0
fi

case "${scenario}" in
    # frozen is deliberately absent from `all`. It prunes the node's
    # buildkit store and re-pulls 8.67GB over the WAN, which is neither
    # a nightly cost nor one to impose on the other projects sharing
    # these builders. Run it on purpose, when the question is what the
    # local registry is worth.
    all)
        for s in cold warm hot; do
            for t in ${targets}; do bench_run "${s}" "${t}"; done
        done
        ;;
    everything)
        for s in frozen cold warm hot; do
            for t in ${targets}; do bench_run "${s}" "${t}"; done
        done
        ;;
    frozen|cold|warm|hot)
        for t in ${targets}; do bench_run "${scenario}" "${t}"; done
        ;;
    *)
        echo "usage: bench.sh {frozen|cold|warm|hot|all|everything|report|json [out]} [target ...]" >&2
        exit 2
        ;;
esac

log "done; ./bench.sh report to render"
