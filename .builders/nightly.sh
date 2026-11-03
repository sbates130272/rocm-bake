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

# ECR will not create a repository on push the way Zot does, and the
# failure arrives at the end of a long build rather than the start.
if [ "${ENSURE_ECR}" = 1 ]; then
    for t in "${TARGETS[@]}" ; do
        for repo in "${REGISTRY_NAME}/${t}" "${REGISTRY_NAME}/${t}-cache"; do
            aws ecr describe-repositories --repository-names "${repo}" >/dev/null 2>&1 \
                || aws ecr create-repository --repository-name "${repo}" \
                     --image-tag-mutability MUTABLE >/dev/null 2>&1 \
                || log "could not create ECR repo ${repo} (may already exist)"
        done
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
    docker buildx bake -f rocm-bake.hcl "$@" "${TARGETS[@]}" >"${logf}" 2>&1
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

python3 -I - "${OUT}" "${ARCH}" "${REGISTRY}" <<'PY' > "${OUT}/summary.json"
import json, sys, pathlib
out, arch, registry = sys.argv[1], sys.argv[2], sys.argv[3]
phases = {}
for line in (pathlib.Path(out) / "phases").read_text().split("\n"):
    parts = line.split()
    if len(parts) == 4:
        phases[parts[0]] = {"seconds": int(parts[1]), "rc": int(parts[2]),
                            "cache_errors": int(parts[3])}
print(json.dumps({"arch": arch, "registry": registry, "phases": phases}, indent=2))
PY

cat "${OUT}/report.md" >&2

# The warm build is the one that publishes, so it decides the exit
# code. A cold failure is reported but does not fail the night: it is
# a measurement, and losing it should not stop the images shipping.
exit "${WARM_RC}"
