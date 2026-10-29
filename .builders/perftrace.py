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
# The rest are gRPC plumbing (ListWorkers, Solve) that says nothing
# about what the build was doing.
STEP_RE = re.compile(r"^\[")


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
                     if STEP_RE.match(s.get("Name") or "")
                     and s.get("StartTime") and s.get("EndTime")]
            if len(steps) > len(best):
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
    rows = [{"name": s["Name"],
             "started": s["StartTime"],
             "completed": s["EndTime"],
             "cached": bool((s.get("Attributes") or {}) and False)}
            for s in spans]
    Path(args.out).write_text(json.dumps(rows, indent=1) + "\n")
    print(f"  {len(rows)} steps -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
