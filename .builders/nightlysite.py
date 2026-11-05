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


def cost_cache(summary):
    """The cost and cache cells for one arch, as (cost, sccache, layer).

    Every one can be absent. A run from before these were recorded has no
    `cost` key at all; an unknown instance has a null `usd`; a phase that
    compiled nothing has a null `hit_rate`. Each renders as an em dash
    rather than a zero, because zero is a measurement and these are not.
    """
    c = summary.get("cost") or {}
    m = summary.get("metrics") or {}
    sc = m.get("sccache") or {}
    lc = m.get("layer_cache") or {}

    cost = "—" if c.get("usd") is None else f"${c['usd']:.2f}"
    if c.get("usd") is not None and not c.get("rate_verified"):
        cost += "*"

    rate = sc.get("hit_rate")
    sccache = "—" if rate is None else f"{rate:.0f}%"

    if lc:
        layer = f"{lc.get('cached', 0)}/{lc.get('done', 0)}"
    else:
        layer = "—"
    return cost, sccache, layer


def write_chart(root, runs):
    """Warm wall clock per run, oldest left, one bar group per arch.

    Written as a file and referenced by <img>: GitHub strips inline <svg>
    from markdown, the same reason perfreport.py emits its charts this way.

    Returns the filename, or None when there is nothing worth drawing. One
    run is not a series -- the chart would be a single bar implying a trend
    that cannot exist -- so it takes two.
    """
    series = []
    for r in reversed(runs):            # oldest first, left to right
        for arch, s in sorted(r["arches"].items()):
            warm = (s.get("phases", {}).get("warm") or {}).get("seconds")
            if warm:
                series.append((r["stamp"], arch, warm))
    if len({stamp for stamp, _, _ in series}) < 2:
        return None

    arches = sorted({a for _, a, _ in series})
    colours = {a: c for a, c in zip(arches, (BLUE, ORANGE, GREEN))}
    stamps = sorted({s for s, _, _ in series})

    w, h, pad_l, pad_b, pad_t = 760, 260, 54, 46, 28
    plot_w, plot_h = w - pad_l - 16, h - pad_t - pad_b
    top = max(v for _, _, v in series)
    # Round the axis up to a whole minute so the gridline labels are not
    # 7m13s; a build-time chart is read for shape, not for its maximum.
    top = max(60, -(-top // 60) * 60)
    slot = plot_w / max(1, len(stamps))
    bw = min(34, slot / (len(arches) + 1))

    style = (
        "<style>"
        "  .s{fill:#fff} .i{fill:#1f2328} .i2{fill:#656d76}"
        "  .g{stroke:#d0d7de;stroke-width:1}"
        "  text{font-family:ui-sans-serif,-apple-system,Segoe UI,Helvetica,"
        "Arial,sans-serif}"
        "  .l{font-size:10px} .t{font-size:12px;font-weight:600}"
        "  @media (prefers-color-scheme: dark){"
        "    .s{fill:#0d1117} .i{fill:#e6edf3} .i2{fill:#8b949e}"
        "    .g{stroke:#30363d} }"
        "</style>"
    )
    opening = (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
        f'viewBox="0 0 {w} {h}" role="img" '
        f'aria-label="Nightly warm build time per run">'
    )
    out = [
        opening,
        style,
        f'<rect class="s" width="{w}" height="{h}"/>',
        '<text class="i t" x="12" y="18">Warm build time per night</text>',
    ]

    for frac in (0, 0.25, 0.5, 0.75, 1.0):
        y = pad_t + plot_h - plot_h * frac
        out.append(f'<line class="g" x1="{pad_l}" y1="{y:.1f}" '
                   f'x2="{w - 16}" y2="{y:.1f}"/>')
        out.append(f'<text class="i2 l" x="{pad_l - 6}" y="{y + 3:.1f}" '
                   f'text-anchor="end">{int(top * frac // 60)}m</text>')

    for si, stamp in enumerate(stamps):
        x0 = pad_l + si * slot
        for ai, arch in enumerate(arches):
            vals = [v for st, a, v in series if st == stamp and a == arch]
            if not vals:
                continue
            v = vals[0]
            bh = plot_h * v / top
            x = x0 + slot / 2 - (len(arches) * bw) / 2 + ai * bw
            y = pad_t + plot_h - bh
            out.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bw - 3:.1f}" '
                       f'height="{bh:.1f}" rx="2" fill="{colours[arch]}"/>')
        out.append(f'<text class="i2 l" x="{x0 + slot / 2:.1f}" '
                   f'y="{h - pad_b + 16}" text-anchor="middle">'
                   f"{html.escape(stamp[:8])}</text>")

    for ai, arch in enumerate(arches):
        x = pad_l + ai * 108
        out.append(f'<rect x="{x}" y="{h - 16}" width="9" height="9" rx="2" '
                   f'fill="{colours[arch]}"/>')
        out.append(f'<text class="i2 l" x="{x + 13}" y="{h - 8}">'
                   f"{html.escape(arch)}</text>")

    out.append("</svg>")
    (root / "build-time.svg").write_text("\n".join(out) + "\n")
    return "build-time.svg"


NOTE = ("These are <strong>not</strong> comparable with the "
        '<a href="../perf/">instrumented fleet runs</a>. Those measure a '
        "parallel build across three nodes with a shared compiler cache; "
        "these measure sequential bakes on one rented machine. The phase "
        "wall clock is the whole bake, not a per-target cost.")


def write_html(root, runs):
    rows = []
    unverified = False
    for r in runs:
        for arch, s in sorted(r["arches"].items()):
            ph = s.get("phases", {})
            cold, cold_cls = fmt(ph.get("cold"))
            warm, warm_cls = fmt(ph.get("warm"))
            cost, sccache, layer = cost_cache(s)
            unverified = unverified or cost.endswith("*")
            stamp = html.escape(r["stamp"])
            rows.append(
                f'<tr><td><a href="{stamp}/">{stamp}</a></td>'
                f"<td><code>{html.escape(arch)}</code></td>"
                f'<td class="{cold_cls}">{cold}</td>'
                f'<td class="{warm_cls}">{warm}</td>'
                f"<td>{cost}</td><td>{sccache}</td><td>{layer}</td></tr>")

    body = "\n".join(rows) or (
        '<tr><td colspan="7" class="skip">No runs published yet.</td></tr>')

    chart = write_chart(root, runs)
    chart_html = (f'<p><img src="{chart}" alt="Warm build time per night" '
                  f'width="760"></p>') if chart else ""
    foot = ('<p class="sub">* cost used an unverified rate for that '
            "instance size.</p>") if unverified else ""

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
{chart_html}
<table>
<thead><tr><th>Run</th><th>Arch</th><th>Cold</th><th>Warm</th>
<th>Cost</th><th>sccache</th><th>Layer cache</th></tr></thead>
<tbody>
{body}
</tbody></table>
{foot}
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
          "| run | arch | cold | warm | cost | sccache | layer cache |",
          "| --- | --- | --- | --- | --- | --- | --- |"]
    for r in runs:
        for arch, s in sorted(r["arches"].items()):
            ph = s.get("phases", {})
            cost, sccache, layer = cost_cache(s)
            md.append(f"| [{r['stamp']}]({r['stamp']}/) | `{arch}` | "
                      f"{fmt(ph.get('cold'))[0]} | {fmt(ph.get('warm'))[0]} | "
                      f"{cost} | {sccache} | {layer} |")
    md.append("")
    (root / "index.md").write_text("\n".join(md) + "\n")

    write_html(root, runs)
    for r in runs:
        write_run_html(root / r["stamp"], r["arches"])

    print(f"nightlysite: {len(runs)} run(s) -> {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
