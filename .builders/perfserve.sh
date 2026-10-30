#!/bin/bash
# perfserve.sh - serve a perf run's interactive chart, kept current.
#
# perfreport.py writes index.html and a data.json sidecar into the run
# directory; this serves that directory and regenerates on an interval
# so a run still in progress stays watchable. The page polls data.json
# rather than reloading itself, so a refresh does not discard whichever
# builders and targets the viewer had filtered down to.
#
# Defaults to the newest run and re-resolves it each cycle, so it
# follows a run that starts after the server did. Pin an older one
# with PERF_RUN=<dir>.
#
# Binds 0.0.0.0 by default: the usual viewer is a laptop on the LAN
# that is not on tailscale, and a tailnet-only bind locked it out.
# What this exposes is build telemetry - hostnames, CPU and memory
# figures, build step names. No credentials and no registry access.
# Narrow it with PERF_BIND=<ip>, and stop it when you are done.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PORT="${PERF_PORT:-8090}"
BIND="${PERF_BIND:-0.0.0.0}"
EVERY="${PERF_REFRESH:-30}"
PINNED="${PERF_RUN:-}"
PERF_DIR="${PERF_DIR:-/var/tmp/rocm-perf}"

newest() {
    if [ -n "${PINNED}" ]; then echo "${PINNED}"; return; fi
    ls -1d "${PERF_DIR}"/*/ 2>/dev/null | sort -r | head -1 | sed 's#/$##'
}

run=$(newest)
if [ -z "${run}" ]; then
    echo "no runs under ${PERF_DIR} — run 'make perf-run' first" >&2
    exit 1
fi

# Errors are kept, not sent to /dev/null. A regeneration loop that
# fails silently leaves a page frozen on stale data while looking
# perfectly healthy, which has happened here before.
LOG="${PERF_DIR}/.perfserve.log"
# A target's trace exists on its builder as soon as that target
# finishes, but perfrun.sh only collects at the end of the whole run -
# so a live viewer showed CPU lines and no phase bands for however
# long the run had left. This picks each one up as it lands.
#
# Captured once per target, never re-fetched: `history export` on a
# builder that is saturating its uplink has been measured at 9s
# against an idle node's 0.08s, and polling that every cycle would be
# a tax on the very run being watched.
catch_traces() {
    local d="$1" arch node name t
    arch=$(python3 -c "import json;print(json.load(open('${d}/run.json'))['arch'])" \
           2>/dev/null) || return 0
    [ -n "${arch}" ] || return 0
    # Errors to the log, not /dev/null. If this stops parsing, no
    # trace is ever captured and the page shows CPU lines with no
    # bands for the whole run — silently, which is how it failed
    # before placement.py existed.
    local pairs; pairs=$(python3 .builders/placement.py "${d}" 2>> "${LOG}")
    for t in $(echo "${pairs}" | awk '{print $1}'); do
        [ -f "${d}/trace-${t}.json" ] && continue
        node=$(echo "${pairs}" | awk -v t="${t}" '$1 == t {print $2; exit}')
        [ -n "${node}" ] || continue
        name=$(PYTORCH_ROCM_ARCH="${arch}" timeout 60 docker buildx bake \
               -f rocm-bake.hcl --print "${t}" 2>/dev/null \
               | jq -r ".target[\"${t}\"].args.BUILDKIT_BUILD_NAME // empty")
        [ -n "${name}" ] || continue
        # Only once it has actually completed; an in-flight record has
        # no final spans to read.
        timeout 90 docker buildx history ls --builder "${node}" \
            --format '{{.Name}}|{{.Status}}' 2>/dev/null \
            | grep -qE "^${name}\|Completed" || continue
        timeout 300 python3 .builders/perftrace.py --builder "${node}" \
            --name "${name}" --out "${d}/trace-${t}.json" >> "${LOG}" 2>&1 \
            || true
    done
}

# python -m http.server fixes --directory at startup, so a server
# started before the current run keeps serving the previous one - which
# is what happened: the page looked stale because it was a different
# run. Serve a stable directory instead and refresh its contents, so
# the viewer follows whichever run is newest without a restart.
SERVE_DIR="${PERF_DIR}/.current"
mkdir -p "${SERVE_DIR}"

# What the page's run selector reads: runs.json, newest first, and one
# runs/<stamp>.json per run so an older run can be plotted without
# restarting the server against it.
#
# Only data.json is republished per run, never index.html — the page is
# the same for every run, and the one already being served is the one
# doing the asking.
publish_runs() {
    python3 -I - "${PERF_DIR}" "${SERVE_DIR}" "$1" <<'PY'
import json, shutil, sys
from datetime import datetime, timezone
from pathlib import Path

perf, serve, newest = (Path(a) for a in sys.argv[1:4])
(serve / "runs").mkdir(parents=True, exist_ok=True)


def label(name, meta):
    """"30 Oct 05:12 · gfx1201 · cold" — enough to tell runs apart.

    The stamp alone is not: a day of runs differs in four characters
    buried mid-string, and the arch and mode are what someone is
    actually choosing between.
    """
    try:
        when = datetime.strptime(name, "%Y%m%dT%H%M%SZ")
        shown = (when.replace(tzinfo=timezone.utc).astimezone()
                 .strftime("%d %b %H:%M"))
    except ValueError:
        shown = name
    extra = [b for b in (meta.get("arch"), meta.get("mode")) if b]
    return " · ".join([shown] + extra)


runs = []
for d in sorted((p for p in perf.glob("2*/") if p.is_dir()),
                key=lambda p: p.name, reverse=True):
    data = d / "data.json"
    if not data.is_file():
        continue            # never rendered, or still starting up
    try:
        meta = json.loads((d / "run.json").read_text())
    except Exception:
        meta = {}
    dest = serve / "runs" / (d.name + ".json")
    # A finished run's data never changes, so copy it once. The newest
    # is still being written, so it is refreshed every cycle.
    if (d.name == newest.name or not dest.exists()
            or dest.stat().st_mtime < data.stat().st_mtime):
        tmp = dest.with_name(dest.name + ".tmp")
        shutil.copyfile(data, tmp)
        tmp.replace(dest)
    runs.append({"stamp": d.name, "label": label(d.name, meta),
                 "arch": meta.get("arch"), "mode": meta.get("mode")})

out = serve / "runs.json"
tmp = out.with_name("runs.json.tmp")
tmp.write_text(json.dumps(runs))
tmp.replace(out)
PY
}

regen() {
    local d; d=$(newest)
    [ -n "${d}" ] || return 0
    catch_traces "${d}"
    python3 .builders/perfreport.py "${d}" >> "${LOG}" 2>&1 || true
    # Copy rather than symlink the directory: a symlink swap races
    # with an in-flight request, and these are two small files.
    for f in index.html data.json; do
        [ -f "${d}/${f}" ] && cp "${d}/${f}" "${SERVE_DIR}/${f}.tmp" \
            && mv "${SERVE_DIR}/${f}.tmp" "${SERVE_DIR}/${f}"
    done
    publish_runs "${d}" >> "${LOG}" 2>&1 || true
    echo "${d}"
}

# Claim the port before starting the worker. The worker used to be
# spawned first and the bind attempted after, so every invocation that
# lost the port — the common case, because the usual reason to run this
# is that a server is already up — left its regen loop behind with
# nothing to stop it. Five had accumulated, each still rewriting
# .current every ${EVERY}s.
if ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
    echo "port ${PORT} is already in use — another perfserve is running." >&2
    echo "  stop it first, or pick another with PERF_PORT=<n>." >&2
    exit 1
fi

regen > /dev/null
( while sleep "${EVERY}"; do regen > /dev/null; done ) &
WORKER=$!
trap 'kill "${WORKER}" 2>/dev/null || true' EXIT INT TERM

lan=$(hostname -I 2>/dev/null | awk '{print $1}')
ts=$(tailscale ip -4 2>/dev/null | head -1)
echo "serving ${run}"
echo "  regenerating every ${EVERY}s · log ${LOG}"
[ -n "${lan}" ] && echo "  lan:     http://${lan}:${PORT}/"
[ -n "${ts}" ]  && echo "  tailnet: http://${ts}:${PORT}/"
echo "  stop with Ctrl-C"

# Deliberately not exec. exec replaces this shell, and the trap above
# goes with it — there is no longer a shell to run it — so Ctrl-C
# killed the server and orphaned the regen loop every single time. The
# `wait` keeps the shell alive to own the trap; the orphans that
# behaviour produced are what prompted this.
python3 -m http.server "${PORT}" --bind "${BIND}" --directory "${SERVE_DIR}" &
SERVER=$!
trap 'kill "${WORKER}" "${SERVER}" 2>/dev/null || true' EXIT INT TERM
wait "${SERVER}"
