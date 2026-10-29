#!/usr/bin/env python3
"""Recover a build's per-step timing from its buildx history record.

perfrun.sh originally took the timeline from `buildx bake
--progress=rawjson`, captured by redirecting the build's output to a
file. That turned out to be fragile: on a real run all three target
logs were truncated back to the 8-byte `{"v":1}` stream header partway
through and never grew again, losing every vertex for builds that were
still running fine. A capture you only discover failed after a
multi-hour build is not a capture.

BuildKit keeps the same information itself. Each build record carries
an OpenTelemetry trace, one span per step with StartTime and EndTime,
and it survives on the builder independently of whether anyone was
listening at the time. So this asks the builder after the fact instead
of tapping the stream as it goes.

`buildx history export` emits an OCI layout tarball; the trace is the
blob holding concatenated (not array-wrapped) JSON span objects.

Usage:
  perftrace.py --builder snoc-think --name rocm-pytorch-build/vllm/... \
               --out trace-vllm-wheel.json
"""
import argparse
import json
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

# Step spans are the ones BuildKit names "[stage n/m] COMMAND ...".
STEP_RE = re.compile(r"^\[")

# Transfer spans are the registry writes: the cache and image export.
# They were discarded with the rest of the non-step spans, and they are
# the single largest thing a build does here — triton-wheel reported
# 430s against 92s of steps, and the 336s after its last step was this.
# A chart that omits them shows a node idle while it is uploading 6GB,
# which is exactly the cost the scheduler's network term exists to
# avoid, so the report could not show the problem it was built to find.
#
# Only the HTTP spans. `remotes.docker.resolver.HTTPRequest` wraps each
# one with identical timings and would double every transfer, and HEAD
# is existence-probing, not payload. The gRPC plumbing
# (Control/Solve, Control/Session) is dropped as before: those span the
# whole build by construction and would swamp every other band.
TRANSFER_RE = re.compile(r"^HTTP (PUT|POST)$")


def attrs(span):
    """OTEL attributes as a plain dict."""
    out = {}
    for a in span.get("Attributes") or []:
        key, val = a.get("Key"), (a.get("Value") or {}).get("Value")
        if key is not None:
            out[key] = val
    return out


def transfer_name(span):
    """A registry write as "PUT <repo>/<kind> (<size>)".

    The span is called just "HTTP PUT"; what it was writing is in
    url.full, and how much is in the request's content-length. Both
    matter on hover — "upload 5m35s" invites the question of what, and
    a 6GB cache export and a 2KB manifest look identical without it.
    """
    a = attrs(span)
    method = a.get("http.request.method") or "PUT"
    path = re.sub(r"^.*?/v2/", "", str(a.get("url.full") or ""))
    path = re.sub(r"\?.*$", "", path)[:70] or "registry"
    try:
        size = int(a.get("http.request.header.content-length") or 0)
    except (TypeError, ValueError):
        size = 0
    if size >= 1 << 20:
        return f"{method} {path} ({size / (1 << 20):.0f}MB)", size
    if size:
        return f"{method} {path} ({size / 1024:.0f}KB)", size
    return f"{method} {path}", 0


def run(cmd, timeout=120):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.stdout if p.returncode == 0 else ""
    except (subprocess.TimeoutExpired, OSError):
        return ""


def find_ref(builder, name):
    """The newest history ref whose record name matches `name`."""
    out = run(["docker", "buildx", "history", "ls", "--builder", builder,
               "--format", "{{.Ref}}\t{{.Name}}"], timeout=60)
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 2 and parts[1].strip() == name:
            return parts[0].strip()
    return None


def stream_json(text):
    """Parse concatenated JSON documents.

    The trace blob is pretty-printed objects written back to back, not
    a JSON array, so json.load() stops at the first one and reports
    "Extra data".
    """
    dec, i, out = json.JSONDecoder(), 0, []
    while i < len(text):
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            break
        try:
            obj, i = dec.raw_decode(text, i)
        except ValueError:
            break
        out.append(obj)
    return out


def extract_spans(bundle):
    """Step spans from an exported .dockerbuild bundle."""
    with tempfile.TemporaryDirectory() as td:
        try:
            with tarfile.open(bundle) as tf:
                # filter="data" refuses absolute paths and symlinks
                # escaping the destination; the bundle is machine
                # generated, but it is still an archive from elsewhere.
                tf.extractall(td, filter="data")
        except (tarfile.TarError, OSError) as exc:
            print(f"  cannot read bundle: {exc}", file=sys.stderr)
            return []
        best = []
        for blob in (Path(td) / "blobs" / "sha256").glob("*"):
            try:
                head = blob.open("rb").read(4096).decode("utf-8", "replace")
            except OSError:
                continue
            if "SpanContext" not in head:
                continue
            spans = stream_json(blob.read_text(errors="replace"))
            steps = [s for s in spans
                     if (STEP_RE.match(s.get("Name") or "")
                         or TRANSFER_RE.match(s.get("Name") or ""))
                     and s.get("StartTime") and s.get("EndTime")]
            # Compared on step count alone: a blob full of transfers
            # and no steps is the wrong trace, and picking it by raw
            # span count would lose the build.
            if sum(1 for s in steps
                   if STEP_RE.match(s.get("Name") or "")) > sum(
                       1 for s in best
                       if STEP_RE.match(s.get("Name") or "")):
                best = steps
    return best


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--builder", required=True)
    ap.add_argument("--name", required=True,
                    help="exact BUILDKIT_BUILD_NAME of the record")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    ref = find_ref(args.builder, args.name)
    if not ref:
        print(f"  no history record named {args.name} on {args.builder}",
              file=sys.stderr)
        return 1

    with tempfile.NamedTemporaryFile(suffix=".dockerbuild") as tmp:
        if not run(["docker", "buildx", "history", "export", ref,
                    "--builder", args.builder, "-o", tmp.name], timeout=300) \
                and not Path(tmp.name).stat().st_size:
            print(f"  export failed for {ref}", file=sys.stderr)
            return 1
        spans = extract_spans(tmp.name)

    if not spans:
        print(f"  no step spans in {ref}", file=sys.stderr)
        return 1

    # Normalised to the shape perfreport wants, so the report does not
    # need to know this came from a trace rather than a progress stream.
    # No per-step cached flag: the exported spans carry no attribute
    # that distinguishes a cache hit, and a vertex resolved from cache
    # usually emits no span at all. This field was once an expression
    # that evaluated to False for every step, which is worse than
    # absent — it made every target read as 0 cached. The record-level
    # NumCachedSteps below is the authoritative count.
    rows = []
    for s in spans:
        if TRANSFER_RE.match(s.get("Name") or ""):
            name, size = transfer_name(s)
            # kind, not a name convention. The reader needs to tell a
            # transfer from a step without pattern-matching the label,
            # because `build` in the report means compute and must not
            # silently start including the export.
            rows.append({"name": name, "started": s["StartTime"],
                         "completed": s["EndTime"], "kind": "transfer",
                         "bytes": size})
        else:
            rows.append({"name": s["Name"], "started": s["StartTime"],
                         "completed": s["EndTime"], "kind": "step"})

    # The record's own duration alongside the spans. The spans cover
    # work; the record covers everything the builder spent on this
    # target, and the gap between them is setup plus cache export. A
    # report that only ever showed the spans would have subtracted
    # precisely the cost the cache-to fix removed, and shown no change.
    meta = {}
    detail = run(["docker", "buildx", "history", "inspect", ref,
                  "--builder", args.builder, "--format", "json"], timeout=90)
    if detail:
        try:
            d = json.loads(detail)
            meta = {"reported_seconds": (d.get("Duration") or 0) / 1e9,
                    "status": d.get("Status"),
                    "steps_total": d.get("NumTotalSteps"),
                    "steps_cached": d.get("NumCachedSteps")}
        except (json.JSONDecodeError, TypeError):
            pass

    # An object, not a bare list. perfreport accepts both: traces
    # written before this change are still lists.
    Path(args.out).write_text(
        json.dumps({"meta": meta, "steps": rows}, indent=1) + "\n")
    nx = sum(1 for r in rows if r["kind"] == "transfer")
    print(f"  {len(rows) - nx} steps, {nx} transfers "
          f"({sum(r.get('bytes', 0) for r in rows) / (1 << 20):.0f}MB) "
          f"-> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
