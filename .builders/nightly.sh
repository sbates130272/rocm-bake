#!/usr/bin/env bash
# A cold build and a warm build of every target, for one architecture,
# on one machine.
#
# This is not perfrun.sh. That one is a *fleet* harness: it drives
# balance.sh across nodes over ssh and reads journalctl, the nginx
# access log and the sccache tree on the services node. None of that
# exists on a rented build machine, which is what this runs on — so
# this times two bake invocations and reports what they did, and
# claims nothing about compiler-cache hit rates it cannot see.
#
# Cold means BuildKit is given nothing: --no-cache, and every
# cache-from cleared so it cannot import the layers the last run
# exported. Warm is an ordinary build with the registry cache live,
# which is the build anyone actually runs. The two differ by far more
# than intuition suggests, because a warm build's cost is mostly
# export and import rather than compile.
#
# Cold runs first and never pushes. Run the other way round and the
# "cold" build would be reading the cache the warm build just wrote.
#
#   nightly.sh --arch gfx950 --out /tmp/nightly
#   nightly.sh --arch gfx950 --out /tmp/nightly --skip-cold --no-push
#
# Writes <out>/report.md and <out>/summary.json.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}" || exit 1

ARCH=""
OUT=""
TARGETS_ARG=""
SKIP_COLD=0
PUSH=1
ENSURE_ECR=0

# Which CodeBuild compute the job is on, for the cost line in the report.
# The workflow hardcodes it in `runs-on:` as `instance-size:2xlarge`, and
# AWS exposes no environment variable naming the compute type, so it is
# passed in rather than detected. Empty means "unknown": the rate table
# misses, and summary.json reports a null cost instead of a wrong one.
NIGHTLY_INSTANCE="${NIGHTLY_INSTANCE:-}"

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)      ARCH="${2:-}"; shift 2 ;;
        --out)       OUT="${2:-}"; shift 2 ;;
        --targets)   TARGETS_ARG="${2:-}"; shift 2 ;;
        --skip-cold) SKIP_COLD=1; shift ;;
        --no-push)   PUSH=0; shift ;;
        --ensure-ecr) ENSURE_ECR=1; shift ;;
        -h|--help)   usage 0 ;;
        *) echo "nightly: unknown argument $1" >&2; usage 1 ;;
    esac
done

[ -n "${ARCH}" ] || { echo "nightly: --arch is required" >&2; exit 1; }
[ -n "${OUT}" ]  || { echo "nightly: --out is required" >&2; exit 1; }
mkdir -p "${OUT}" || exit 1

REGISTRY="${REGISTRY:-}"
[ -n "${REGISTRY}" ] || { echo "nightly: REGISTRY is not set" >&2; exit 1; }
REGISTRY_NAME="${REGISTRY_NAME:-rocm-pytorch}"

# Scope this run's cache away from whatever a human last pushed. Two
# writers against one `*-cache:latest` ref overwrite each other, and
# the loser silently rebuilds from cold next time.
export CACHE_TAG_SUFFIX="${CACHE_TAG_SUFFIX:--nightly}"
export PYTORCH_ROCM_ARCH="${ARCH}"
export REGISTRY REGISTRY_NAME

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# sccache: WebDAV on the fleet, S3 off it. Empty SCCACHE_BUCKET leaves
# the Dockerfiles on WebDAV, which is what makes this inert on SNOC.
export SCCACHE_BUCKET="${SCCACHE_BUCKET:-}"
export SCCACHE_REGION="${SCCACHE_REGION:-}"
export SCCACHE_S3_KEY_PREFIX="${SCCACHE_S3_KEY_PREFIX:-rocm-pytorch}"

# Credentials travel as a BuildKit secret, never as a build arg: an
# arg is recorded in image history and would publish them with every
# push. The file is 0600, lives only for this run, and is shredded on
# exit however the script leaves.
SECRET_ARGS=()
CREDS_FILE=""
cleanup_creds() {
    [ -n "${CREDS_FILE}" ] && [ -f "${CREDS_FILE}" ] \
        && shred -u "${CREDS_FILE}" 2>/dev/null
    return 0
}
trap cleanup_creds EXIT INT TERM

if [ -n "${SCCACHE_BUCKET}" ]; then
    [ -n "${SCCACHE_REGION}" ] || {
        echo "nightly: SCCACHE_BUCKET is set but SCCACHE_REGION is not" >&2
        exit 1
    }
    CREDS_FILE="$(mktemp)"
    chmod 600 "${CREDS_FILE}"
    if aws configure export-credentials --format env-no-export \
         > "${CREDS_FILE}" 2>/dev/null && [ -s "${CREDS_FILE}" ]; then
        SECRET_ARGS=(--set "*.secrets=id=aws,src=${CREDS_FILE}")
        log "sccache: S3 ${SCCACHE_BUCKET} (${SCCACHE_REGION}), credentials via secret mount"
    else
        echo "nightly: SCCACHE_BUCKET is set but no AWS credentials resolved;" \
             "the build would fail at sccache server start" >&2
        exit 1
    fi
else
    log "sccache: WebDAV (no SCCACHE_BUCKET set)"
fi


# The default group, unless told otherwise. Read out of the bake file
# rather than listed here, so a target added there is built here.
if [ -n "${TARGETS_ARG}" ]; then
    read -r -a TARGETS <<< "${TARGETS_ARG}"
else
    mapfile -t TARGETS < <(docker buildx bake -f rocm-bake.hcl --print default 2>/dev/null \
        | jq -r '.group.default.targets[]?' )
fi
[ "${#TARGETS[@]}" -gt 0 ] || { echo "nightly: no targets resolved" >&2; exit 1; }
log "arch ${ARCH}, ${#TARGETS[@]} targets: ${TARGETS[*]}"

# A buildx builder on the docker-container driver. Not optional: the
# default `docker` driver has no shared cache and cannot export one —
# .builders/builder-create.sh says so in as many words — so on a fresh
# machine every `cache-to type=registry,mode=max` in rocm-bake.hcl
# fails. With ignore-error=true on all of them, that failure is silent
# and the warm build is secretly cold for ever.
#
# A named builder rather than --use, so running this on a workstation
# does not repoint that machine's default away from its fleet builder.
BUILDER_NAME="${BUILDER_NAME:-rocm-nightly}"
ensure_builder() {
    if docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
        log "builder ${BUILDER_NAME} exists"
    else
        log "creating builder ${BUILDER_NAME} (docker-container)"
        docker buildx create --name "${BUILDER_NAME}" \
            --driver docker-container --bootstrap >/dev/null || {
                echo "nightly: could not create a docker-container builder;" \
                     "cache export would silently fail" >&2
                exit 1
            }
    fi
}
ensure_builder

# The ECR repositories the build will actually push and cache to.
#
# NOT "<target>" and "<target>-cache": the repository name comes from
# the tag, not the target, and the two differ. `pytorch-base` publishes
# to rocm-pytorch/base and caches to base-cache; `pytorch-common` has no
# repository of its own and caches into pytorch-cache; `pytorch-wheel`
# shares pytorch-cache. Deriving names from the target list creates
# repositories nothing uses and misses the ones the push needs — and
# ECR, unlike Zot, will not create one on push, so the failure lands at
# the end of a long build.
ecr_repo_names() {
    docker buildx bake -f rocm-bake.hcl --print default 2>/dev/null \
        | python3 -I -c '
import json, re, sys
names = set()
doc = json.load(sys.stdin)
for spec in doc.get("target", {}).values():
    for tag in spec.get("tags") or []:
        m = re.search(r"/([^/:]+)(?::|$)", tag)
        if m:
            names.add(m.group(1))
    for key in ("cache-to", "cache-from"):
        for entry in spec.get(key) or []:
            ref = entry.get("ref", "") if isinstance(entry, dict) else str(entry)
            m = re.search(r"/([^/:,]+)(?::|,|$)", ref)
            if m:
                names.add(m.group(1))
print("\n".join(sorted(n for n in names if n)))
'
}

if [ "${ENSURE_ECR}" = 1 ]; then
    mapfile -t ECR_REPOS < <(ecr_repo_names)
    [ "${#ECR_REPOS[@]}" -gt 0 ] || {
        echo "nightly: could not derive ECR repository names from bake" >&2
        exit 1
    }
    log "ensuring ${#ECR_REPOS[@]} ECR repositories"
    for name in "${ECR_REPOS[@]}"; do
        repo="${REGISTRY_NAME}/${name}"
        aws ecr describe-repositories --repository-names "${repo}" >/dev/null 2>&1 \
            && continue
        aws ecr create-repository --repository-name "${repo}" \
            --image-tag-mutability MUTABLE >/dev/null 2>&1 \
            || log "could not create ECR repo ${repo}"
    done
    log "ECR repositories ensured"
fi

# Every cache-to in rocm-bake.hcl carries ignore-error=true, which is
# the right default — a registry that rejects a cache export should
# not fail a build that otherwise succeeded. The cost is that a night
# where every export failed exits 0 and looks healthy, while the next
# "warm" build is secretly cold. So count them and say so.
cache_errors() {
    grep -cE 'ERROR: (error writing layer blob|failed to (push|do request))' \
        "$1" 2>/dev/null || true
}

phase() {
    # phase <name> <extra bake args...>
    local name="$1"; shift
    local logf="${OUT}/${name}.log"
    local start end rc cerr
    log "${name}: starting"
    start=$(date +%s)
    docker buildx bake --builder "${BUILDER_NAME}" \
        "${SECRET_ARGS[@]+"${SECRET_ARGS[@]}"}" \
        -f rocm-bake.hcl "$@" "${TARGETS[@]}" >"${logf}" 2>&1
    rc=$?
    end=$(date +%s)
    cerr=$(cache_errors "${logf}")
    printf '%s %s %s %s\n' "${name}" "$((end - start))" "${rc}" "${cerr:-0}" \
        >> "${OUT}/phases"
    log "${name}: rc=${rc} in $((end - start))s, ${cerr:-0} cache error(s) (${logf})"
    return "${rc}"
}

: > "${OUT}/phases"
COLD_RC=skipped
WARM_RC=1

if [ "${SKIP_COLD}" = 0 ]; then
    # --no-cache stops BuildKit reusing its own local layers;
    # `*.cache-from=` clears the registry import so the previous
    # night's export cannot leak in. No --push: a cold build is a
    # measurement, and publishing it would race the warm one.
    phase cold --no-cache --set '*.cache-from=' --set '*.cache-to='
    COLD_RC=$?
fi

PUSH_FLAG=()
[ "${PUSH}" = 1 ] && PUSH_FLAG=(--push)
phase warm "${PUSH_FLAG[@]}"
WARM_RC=$?

# ── footprint ────────────────────────────────────────────────────
# Disk, BuildKit store and the anon/page-cache split, measured on the
# build machine right after the bake.
#
# WHY. CloudWatch's per-build metrics answer how hard the machine
# worked but not whether a smaller one would fit, and that is the
# question worth ~$5.60 a run: general1.xlarge is $0.0798/min against
# 2xlarge's $0.200. CPU is already settled — the 2026-11-12 run peaked
# at 66% of 72 vCPU and spent 16 of 35 minutes under 2%. The two open
# questions are the ones only the machine itself can answer:
#
#   DISK. xlarge cuts 824 GB -> 256 GB, a bigger cut than CPU (-50%)
#   or RAM (-50%). rocm-runtime alone extracts one 8.67 GB layer to
#   20.5 GB, and `cache-to mode=max` materialises export blobs on top
#   of the snapshots they came from. Nobody has ever run `df` here.
#
#   MEMORY. CloudWatch publishes MemoryUtilized with no definition of
#   whether it counts page cache, and the profile looks exactly like
#   page cache: it peaked at 116 GB on 2026-11-10, fell to 81.5 GB on
#   2026-11-12 when the layer-cache fix cut the export work, and it
#   plateaus while CPU sits at 0.6%. If `anon` is the small half then
#   a 72 GiB box reclaims the rest under pressure instead of OOMing.
#   Dockerfile.pytorch already derives MAX_JOBS from MemAvailable, so
#   the build self-throttles on a smaller machine either way.
#
# Non-fatal by construction: every command is `|| true` and the file
# is written whatever happens. A sizing measurement must never be the
# thing that fails a green build.
footprint() {
    local f="${OUT}/footprint.json"
    local docker_root avail_kb used_kb du_bytes anon file
    docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
    # POSIX -P: one line, 1K blocks, no wrapping on long device names.
    read -r _ _ used_kb avail_kb _ < <(df -Pk "${docker_root}" 2>/dev/null | tail -1) || true
    # The "Total:" trailer, as the human string buildx prints it
    # ("106.5GB"); converted below. NOT a sum of the Size column --
    # every size buildx emits is a formatted string, so summing it
    # needs the same conversion applied 200 times instead of once,
    # and the column omits the shared-blob accounting the trailer
    # does. Separator is a tab here and spaces on some versions.
    du_human="$(docker buildx du --builder "${BUILDER_NAME}" 2>/dev/null \
        | awk '/^Total:/ {print $NF; exit}')" || true
    # cgroup v2 first, v1 as the fallback. `anon` is the resident half;
    # `file` is page cache and is what a smaller box would reclaim.
    if [ -r /sys/fs/cgroup/memory.stat ]; then
        anon="$(awk '$1=="anon"{print $2}' /sys/fs/cgroup/memory.stat)"
        file="$(awk '$1=="file"{print $2}' /sys/fs/cgroup/memory.stat)"
    elif [ -r /sys/fs/cgroup/memory/memory.stat ]; then
        anon="$(awk '$1=="rss"{print $2}' /sys/fs/cgroup/memory/memory.stat)"
        file="$(awk '$1=="cache"{print $2}' /sys/fs/cgroup/memory/memory.stat)"
    fi
    python3 -I - "${f}" "${docker_root}" "${used_kb:-}" "${avail_kb:-}" \
        "${du_human:-}" "${anon:-}" "${file:-}" <<'PY'
import json, re, sys
path, root, used_kb, avail_kb, du_h, anon, file_ = sys.argv[1:8]
def num(x, mul=1):
    try:
        return int(x) * mul
    except (TypeError, ValueError):
        return None

# buildx formats with decimal units (GB = 1e9), via go-units
# HumanSize -- not GiB. Getting this wrong understates the store by
# 7% at TB scale, which is exactly the margin a 256 GB-vs-824 GB
# sizing decision turns on.
UNITS = {"B": 1, "KB": 10**3, "MB": 10**6, "GB": 10**9, "TB": 10**12,
         "KIB": 2**10, "MIB": 2**20, "GIB": 2**30, "TIB": 2**40}
def human(x):
    m = re.fullmatch(r"\s*([0-9.]+)\s*([A-Za-z]*)\s*", x or "")
    if not m:
        return None
    try:
        return int(float(m.group(1)) * UNITS[(m.group(2) or "B").upper()])
    except (KeyError, ValueError):
        return None

used, avail = num(used_kb, 1024), num(avail_kb, 1024)
du_b = human(du_h)
out = {
    "docker_root": root or None,
    "disk_used_bytes": used,
    "disk_avail_bytes": avail,
    # The number to compare against a compute type's disk, not just
    # "how full is the volume" -- a shared volume's used bytes include
    # things this build did not put there.
    "buildkit_store_bytes": du_b,
    "mem_anon_bytes": num(anon),
    "mem_file_bytes": num(file_),
}
open(path, "w").write(json.dumps(out, indent=2) + "\n")
PY
    return 0
}
footprint || true
log "footprint: $(tr -d ' \n' < "${OUT}/footprint.json" 2>/dev/null || echo unavailable)"

# ── report ───────────────────────────────────────────────────────
dur() { awk -v n="$1" '$1==n {print $2}' "${OUT}/phases" 2>/dev/null; }
rcof() { awk -v n="$1" '$1==n {print $3}' "${OUT}/phases" 2>/dev/null; }
cerrof() { awk -v n="$1" '$1==n {print $4+0}' "${OUT}/phases" 2>/dev/null; }
hms() { printf '%dm%02ds' "$(( $1 / 60 ))" "$(( $1 % 60 ))"; }

TOTAL_CACHE_ERR=$(( $(cerrof cold) + $(cerrof warm) ))

{
    printf '| phase | result | wall clock | cache errors |\n'
    printf '| --- | --- | --- | --- |\n'
    if [ "${SKIP_COLD}" = 0 ]; then
        printf '| cold | %s | %s | %s |\n' \
            "$([ "$(rcof cold)" = 0 ] && echo pass || echo FAIL)" \
            "$(hms "$(dur cold)")" "$(cerrof cold)"
    else
        printf '| cold | skipped | — | — |\n'
    fi
    printf '| warm | %s | %s | %s |\n' \
        "$([ "$(rcof warm)" = 0 ] && echo pass || echo FAIL)" \
        "$(hms "$(dur warm)")" "$(cerrof warm)"
    printf '\n'
    if [ "${TOTAL_CACHE_ERR}" -gt 0 ]; then
        printf '> **%d cache export/import error(s).** `ignore-error=true` keeps\n' \
            "${TOTAL_CACHE_ERR}"
        printf '> these from failing the build, so the exit code above does not\n'
        printf '> reflect them — but a run that cannot write its cache makes the\n'
        printf '> next warm build cold. Check the registry and its credentials.\n\n'
    fi
    printf 'arch `%s` · %d targets · registry `%s` · cache suffix `%s`\n' \
        "${ARCH}" "${#TARGETS[@]}" "${REGISTRY}" "${CACHE_TAG_SUFFIX}"

    # Cost and cache, read back out of the summary this run just wrote, so
    # the table and the JSON can never disagree. Printed only when there is
    # something to say: an unknown instance yields no cost line rather than
    # a zero, and a run with no compiler calls yields no sccache line.
    python3 -I - "${OUT}/summary.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
c, m = d.get("cost") or {}, d.get("metrics") or {}
sc, lc = m.get("sccache") or {}, m.get("layer_cache") or {}
out = []
if c.get("usd") is not None:
    note = "" if c.get("rate_verified") else " (rate unverified)"
    out.append(
        f"cost **${c['usd']:.2f}** · {c['instance']} at "
        f"${c['usd_per_min']:.3f}/min over {c['billed_seconds'] / 60:.1f} "
        f"build-minutes{note}"
    )
elif c.get("instance"):
    out.append(f"cost unknown — no rate for instance `{c['instance']}`")
if sc.get("hit_rate") is not None:
    out.append(
        f"sccache **{sc['hit_rate']:.1f}%** "
        f"({sc['hits']} hit / {sc['hits'] + sc['misses']} cacheable)"
    )
if lc:
    out.append(
        f"layer cache {lc['cached']}/{lc['done']} steps CACHED"
        + (f" · {lc['import_misses']} import miss(es)"
           if lc.get("import_misses") else "")
    )
# Footprint, so the "would a smaller machine fit?" question is answered
# in the nightly issue rather than by an investigation. xlarge is
# 36 vCPU / 72 GiB / 256 GB against 2xlarge's 72 / 144 / 824.
fp = d.get("footprint") or {}
GB = 1 << 30
if fp.get("buildkit_store_bytes") is not None:
    line = f"buildkit store {fp['buildkit_store_bytes'] / GB:.0f} GB"
    if fp.get("disk_avail_bytes") is not None:
        line += f" · {fp['disk_avail_bytes'] / GB:.0f} GB disk free"
    out.append(line)
if fp.get("mem_anon_bytes") is not None:
    anon = fp["mem_anon_bytes"] / GB
    line = f"mem {anon:.0f} GB anon"
    if fp.get("mem_file_bytes") is not None:
        line += f" + {fp['mem_file_bytes'] / GB:.0f} GB page cache"
    out.append(line)
if out:
    print("\n" + " · ".join(out))
PY
    if [ "${WARM_RC}" != 0 ] || { [ "${SKIP_COLD}" = 0 ] && [ "${COLD_RC}" != 0 ]; }; then
        printf '\n<details><summary>last 40 lines of the failing phase</summary>\n\n```\n'
        for n in cold warm; do
            [ -s "${OUT}/${n}.log" ] || continue
            [ "$(rcof "$n")" = 0 ] && continue
            printf -- '--- %s ---\n' "$n"
            tail -40 "${OUT}/${n}.log"
        done
        printf '```\n\n</details>\n'
    fi
} > "${OUT}/report.md"

# Metrics the phase logs already carried and nobody read: sccache hit
# rate, CACHED-vs-DONE, cache-import misses, and per-target
# vertex-seconds for the chart. See .builders/nightlymetrics.py.
#
# Both logs unconditionally; the script drops the one --skip-cold never
# wrote. A parse failure must not lose the run, so this falls back to an
# empty object rather than failing the build.
METRICS_JSON="$(python3 -I "${HERE}/nightlymetrics.py" \
    "${OUT}/cold.log" "${OUT}/warm.log" 2>/dev/null || echo '{}')"

python3 -I - "${OUT}" "${ARCH}" "${REGISTRY}" "${NIGHTLY_INSTANCE}" \
    "${METRICS_JSON}" <<'PY' > "${OUT}/summary.json"
import json, sys, pathlib
out, arch, registry, instance, metrics_raw = sys.argv[1:6]
phases = {}
for line in (pathlib.Path(out) / "phases").read_text().split("\n"):
    parts = line.split()
    if len(parts) == 4:
        phases[parts[0]] = {"seconds": int(parts[1]), "rc": int(parts[2]),
                            "cache_errors": int(parts[3])}

try:
    metrics = json.loads(metrics_raw) or {}
except ValueError:
    metrics = {}

# CodeBuild on-demand Linux, USD per build-minute. Only 2xlarge is
# measured here: $17.80 billed across 88.2 minutes on 2026-11-04 gives
# $0.2018/min, which matches AWS's published rate. The rest are AWS's
# published figures, carried so a resized project still reports a cost
# -- check one against a bill before trusting it.
# xlarge corrected from 0.080 to 0.0798 against the live Price List
# API on 2026-11-11: usagetype USW2-Build-Min:Linux:g1.xlarge. The
# ladder has five rungs and nothing between xlarge (36 vCPU / 72 GiB)
# and 2xlarge (72 / 144) -- the 48- and 64-core shapes exist only as
# reserved-capacity SKUs, which bill while idle and are ~29x worse at
# this cadence.
RATES = {"small": 0.005, "medium": 0.010, "large": 0.020,
         "xlarge": 0.0798, "2xlarge": 0.200}
VERIFIED = {"2xlarge"}

rate = RATES.get(instance)
billed = sum(p["seconds"] for p in phases.values())
cost = {
    "instance": instance or None,
    "usd_per_min": rate,
    "rate_verified": instance in VERIFIED,
    # Phase wall clock, which is the bake. It excludes CodeBuild's ~135s
    # PROVISIONING, so this is a floor on the bill, not the bill.
    "billed_seconds": billed,
    "usd": round(rate * billed / 60.0, 2) if rate else None,
}

# Written by footprint() above. Absent on a machine where every probe
# failed, which is a missing measurement and not a failed build -- so
# it is omitted rather than reported as zeros.
try:
    footprint = json.loads((pathlib.Path(out) / "footprint.json").read_text())
except (OSError, ValueError):
    footprint = None

doc = {"arch": arch, "registry": registry, "phases": phases,
       "cost": cost, "metrics": metrics}
if footprint and any(v is not None for v in footprint.values()):
    doc["footprint"] = footprint
print(json.dumps(doc, indent=2))
PY

cat "${OUT}/report.md" >&2

# The warm build is the one that publishes, so it decides the exit
# code. A cold failure is reported but does not fail the night: it is
# a measurement, and losing it should not stop the images shipping.
exit "${WARM_RC}"
