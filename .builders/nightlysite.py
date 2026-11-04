#!/usr/bin/env python3
"""Assemble an index over the nightly runs published to gh-pages.

Deliberately separate from perfsite.py and from data/perf/. Those runs
come from perfrun.sh across the fleet — per-target timings, sampling,
registry and compiler-cache series. A nightly is two bake invocations
on one rented machine, and reports phase wall clock and cache-error
counts. docs/performance/ opens with a danger admonition about quoting
one harness's numbers as another's; merging the two into one index
would be that mistake made structural.

HTML, not just markdown. gh-pages carries a `.nojekyll`, so markdown is
served as a file rather than rendered, and a directory with no
index.html is a 404 — which is exactly what the first published
nightly was. data/perf/ works because perfreport.py emits an
index.html beside its charts. The markdown is written too: it is what
reads well in a diff and in the repository.

Reads the layout the workflow writes:

    data/nightly/<stamp>/index.md          the whole night's summary
    data/nightly/<stamp>/<arch>/report.md  per-arch markdown
    data/nightly/<stamp>/<arch>/summary.json

Writes beside them:

    data/nightly/runs.json    newest first, for a selector
    data/nightly/index.md     a table linking every run
    data/nightly/index.html   the same, served

Usage: nightlysite.py <data/nightly dir>
"""
import html
import json
import sys
from pathlib import Path

# Slots 1-3 of the fleet palette, the same three perfreport.py uses for
# its builders, so the two pages read as one site.
BLUE, ORANGE, GREEN = "#2a78d6", "#eb6834", "#1baf7a"

FAVICON = (
    "data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'"
    "%20viewBox='0%200%2016%2016'%3E%3Crect%20x='2'%20y='9'%20width='3'"
    "%20height='5'%20rx='1'%20fill='%232a78d6'/%3E%3Crect%20x='6.5'%20y='5'"
    "%20width='3'%20height='9'%20rx='1'%20fill='%23eb6834'/%3E%3Crect"
    "%20x='11'%20y='2'%20width='3'%20height='12'%20rx='1'"
    "%20fill='%231baf7a'/%3E%3C/svg%3E"
)

CSS = """
:root { color-scheme: light dark; }
body { font: 15px/1.55 ui-sans-serif, system-ui, -apple-system, sans-serif;
       max-width: 52rem; margin: 3rem auto; padding: 0 1.25rem; }
h1 { font-size: 1.5rem; margin-bottom: .25rem; }
.sub { opacity: .7; margin-top: 0; }
.note { border-left: 3px solid %s; padding: .6rem 0 .6rem .9rem;
        margin: 1.5rem 0; opacity: .85; font-size: .93rem; }
table { border-collapse: collapse; width: 100%%; margin-top: 1.5rem;
        font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: .45rem .7rem;
         border-bottom: 1px solid color-mix(in srgb, currentColor 15%%, transparent); }
th { font-weight: 600; opacity: .7; font-size: .85rem;
     text-transform: uppercase; letter-spacing: .03em; }
code { font: 13px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
       padding: .1rem .3rem; border-radius: 3px;
       background: color-mix(in srgb, currentColor 8%%, transparent); }
a { color: %s; text-decoration-thickness: 1px; text-underline-offset: 2px; }
.fail { color: %s; font-weight: 600; }
.warn { color: %s; }
.skip { opacity: .45; }
""" % (BLUE, BLUE, ORANGE, ORANGE)


def load_run(d):
    """One run's stamp and its per-arch summaries."""
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


def fmt(spec):
    """(text, css class) for one phase, or an em dash when absent."""
    if not spec:
        return "—", "skip"
    secs = spec.get("seconds", 0)
    rc = spec.get("rc", 1)
    errs = spec.get("cache_errors", 0)
    text = f"{secs // 60}m{secs % 60:02d}s"
    cls = ""
    if rc != 0:
        text += " FAIL"
        cls = "fail"
    if errs:
        text += f" · {errs} cache err"
        cls = cls or "warn"
    return text, cls


NOTE = ("These are <strong>not</strong> comparable with the "
        '<a href="../perf/">instrumented fleet runs</a>. Those measure a '
        "parallel build across three nodes with a shared compiler cache; "
        "these measure sequential bakes on one rented machine. The phase "
        "wall clock is the whole bake, not a per-target cost.")


def write_html(root, runs):
    rows = []
    for r in runs:
        for arch, s in sorted(r["arches"].items()):
            ph = s.get("phases", {})
            cold, cold_cls = fmt(ph.get("cold"))
            warm, warm_cls = fmt(ph.get("warm"))
            stamp = html.escape(r["stamp"])
            rows.append(
                f'<tr><td><a href="{stamp}/">{stamp}</a></td>'
                f"<td><code>{html.escape(arch)}</code></td>"
                f'<td class="{cold_cls}">{cold}</td>'
                f'<td class="{warm_cls}">{warm}</td></tr>')

    body = "\n".join(rows) or (
        '<tr><td colspan="4" class="skip">No runs published yet.</td></tr>')

    (root / "index.html").write_text(f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Nightly builds — rocm-bake</title>
<link rel="icon" href="{FAVICON}">
<style>{CSS}</style>
</head><body>
<h1>Nightly builds</h1>
<p class="sub">Cold and warm bake invocations on a rented CodeBuild
machine, one job per architecture.</p>
<div class="note">{NOTE}</div>
<table>
<thead><tr><th>Run</th><th>Arch</th><th>Cold</th><th>Warm</th></tr></thead>
<tbody>
{body}
</tbody></table>
</body></html>
""")


def write_run_html(d, summaries):
    """A per-run page, so <stamp>/ is not a 404 either."""
    rows = []
    for arch, s in sorted(summaries.items()):
        ph = s.get("phases", {})
        cold, cold_cls = fmt(ph.get("cold"))
        warm, warm_cls = fmt(ph.get("warm"))
        rows.append(f"<tr><td><code>{html.escape(arch)}</code></td>"
                    f'<td class="{cold_cls}">{cold}</td>'
                    f'<td class="{warm_cls}">{warm}</td>'
                    f'<td><a href="{html.escape(arch)}/report.md">report.md</a>'
                    f"</td></tr>")
    stamp = html.escape(d.name)
    (d / "index.html").write_text(f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Nightly {stamp} — rocm-bake</title>
<link rel="icon" href="{FAVICON}">
<style>{CSS}</style>
</head><body>
<h1>Nightly {stamp}</h1>
<p class="sub"><a href="../">All nightly runs</a></p>
<table>
<thead><tr><th>Arch</th><th>Cold</th><th>Warm</th><th></th></tr></thead>
<tbody>
{chr(10).join(rows)}
</tbody></table>
</body></html>
""")


def main(argv):
    if len(argv) != 1:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    root = Path(argv[0])
    if not root.is_dir():
        print(f"nightlysite: {root} is not a directory", file=sys.stderr)
        return 1

    runs = [load_run(d) for d in root.iterdir() if d.is_dir()]
    runs = [r for r in runs if r["arches"]]
    runs.sort(key=lambda r: r["stamp"], reverse=True)

    (root / "runs.json").write_text(
        json.dumps([r["stamp"] for r in runs], indent=2) + "\n")

    md = ["# Nightly builds", "",
          "Cold and warm bake invocations on a rented CodeBuild machine, "
          "one job per architecture.", "",
          "> These are **not** comparable with the "
          "[instrumented fleet runs](../perf/). Those measure a parallel "
          "build across three nodes with a shared compiler cache; these "
          "measure sequential bakes on one machine.", "",
          "| run | arch | cold | warm |", "| --- | --- | --- | --- |"]
    for r in runs:
        for arch, s in sorted(r["arches"].items()):
            ph = s.get("phases", {})
            md.append(f"| [{r['stamp']}]({r['stamp']}/) | `{arch}` | "
                      f"{fmt(ph.get('cold'))[0]} | {fmt(ph.get('warm'))[0]} |")
    md.append("")
    (root / "index.md").write_text("\n".join(md) + "\n")

    write_html(root, runs)
    for r in runs:
        write_run_html(root / r["stamp"], r["arches"])

    print(f"nightlysite: {len(runs)} run(s) -> {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
