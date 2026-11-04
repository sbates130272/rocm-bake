#!/usr/bin/env python3
"""Assemble an index over the nightly runs published to gh-pages.

Deliberately separate from perfsite.py and from data/perf/. Those runs
come from perfrun.sh across the fleet — per-target timings, sampling,
registry and compiler-cache series. A nightly is two bake invocations
on one rented machine, and reports phase wall clock and cache-error
counts. docs/performance/ opens with a danger admonition about quoting
one harness's numbers as another's; merging the two into one index
would be that mistake made structural.

What this reads is the layout the workflow writes:

    data/nightly/<stamp>/index.md          the whole night's summary
    data/nightly/<stamp>/<arch>/report.md  per-arch markdown
    data/nightly/<stamp>/<arch>/summary.json

and what it writes beside them:

    data/nightly/runs.json   newest first, for a selector
    data/nightly/index.md    a table linking every run

Usage: nightlysite.py <data/nightly dir>
"""
import json
import sys
from pathlib import Path


def load_run(d):
    """One run's stamp, arches, and per-phase outcome."""
    arches = {}
    for sub in sorted(p for p in d.iterdir() if p.is_dir()):
        summary = sub / "summary.json"
        if not summary.is_file():
            continue
        try:
            arches[sub.name] = json.loads(summary.read_text())
        except (OSError, ValueError):
            continue
    return {"stamp": d.name, "arches": arches}


def phase_cell(spec):
    """A phase rendered for the table, or an em dash when absent."""
    if not spec:
        return "—"
    secs = spec.get("seconds", 0)
    rc = spec.get("rc", 1)
    errs = spec.get("cache_errors", 0)
    out = f"{secs // 60}m{secs % 60:02d}s"
    if rc != 0:
        out += " **FAIL**"
    if errs:
        out += f" ({errs} cache err)"
    return out


def main(argv):
    if len(argv) != 1:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    root = Path(argv[0])
    if not root.is_dir():
        print(f"nightlysite: {root} is not a directory", file=sys.stderr)
        return 1

    runs = [load_run(d) for d in root.iterdir()
            if d.is_dir() and d.name not in ("runs",)]
    runs = [r for r in runs if r["arches"]]
    runs.sort(key=lambda r: r["stamp"], reverse=True)

    (root / "runs.json").write_text(
        json.dumps([r["stamp"] for r in runs], indent=2) + "\n")

    md = ["# Nightly builds", ""]
    md.append("Cold and warm bake invocations on a rented CodeBuild "
              "machine, one job per architecture.")
    md.append("")
    md.append("> These are **not** comparable with the "
              "[instrumented fleet runs](../perf/). Those measure a "
              "parallel build across three nodes with a shared "
              "compiler cache; these measure two sequential bakes on "
              "one machine. The phase wall clock is the whole bake, "
              "not a per-target cost.")
    md.append("")
    md.append("| run | arch | cold | warm |")
    md.append("| --- | --- | --- | --- |")
    for r in runs:
        for arch, s in sorted(r["arches"].items()):
            phases = s.get("phases", {})
            md.append(
                f"| [{r['stamp']}]({r['stamp']}/index.md) | `{arch}` | "
                f"{phase_cell(phases.get('cold'))} | "
                f"{phase_cell(phases.get('warm'))} |")
    md.append("")
    (root / "index.md").write_text("\n".join(md) + "\n")

    print(f"nightlysite: {len(runs)} run(s) -> {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
