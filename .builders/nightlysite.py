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

    # Distinct build steps where the run recorded them. `cached`/`done`
    # are raw progress-line counts -- BuildKit re-reports a vertex each
    # time another target resolves against it -- and are kept only for
    # runs from before build_steps existed.
    if lc.get("build_steps"):
        layer = f"{lc.get('build_steps_cached', 0)}/{lc['build_steps']}"
    elif lc:
        layer = f"{lc.get('cached', 0)}/{lc.get('done', 0)}"
    else:
        layer = "—"
    return cost, sccache, layer


# An architecture keeps its colour whichever others are on the chart.
#
# The colours used to be dealt out to whichever architectures a chart
# happened to contain, in sorted order, from a list of three. So the
# same architecture changed colour between charts, and the first run to
# publish a fourth -- the weekly of 2026-11-26, all four built for the
# first time -- had no colour for gfx950 and died on a KeyError. The
# report job failed there, before committing, and that run's data never
# reached the site.
#
# Slot 4 is the violet perfreport.py already carries as its fourth
# fallback. The four pass the palette validator on both surfaces; the
# aqua is under 3:1 against white, which the table under the chart
# relieves. An architecture not listed here takes the next unused slot
# and then a neutral grey: an unknown name is a reason to draw the bar
# plainly, never a reason to lose the report.
VIOLET, NEUTRAL = "#9456c9", "#8b949e"
ARCH_COLOURS = {"gfx1201": BLUE, "gfx1151": ORANGE,
                "gfx1250": GREEN, "gfx950": VIOLET}


def arch_colours(arches):
    spare = [c for c in (BLUE, ORANGE, GREEN, VIOLET)
             if c not in {ARCH_COLOURS[a] for a in arches if a in ARCH_COLOURS}]
    out = {}
    for a in arches:
        if a in ARCH_COLOURS:
            out[a] = ARCH_COLOURS[a]
        else:
            out[a] = spare.pop(0) if spare else NEUTRAL
    return out


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
    colours = arch_colours(arches)
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


RUN_CSS = """
h2 { font-size: 1.15rem; margin: 2.5rem 0 .25rem; }
h3 { font-size: .85rem; margin: 1.75rem 0 0; opacity: .7;
     text-transform: uppercase; letter-spacing: .03em; }
.tiles { display: grid; gap: .75rem; margin-top: 1rem;
         grid-template-columns: repeat(auto-fill, minmax(11rem, 1fr)); }
.tile { padding: .7rem .85rem; border-radius: 6px;
        border: 1px solid color-mix(in srgb, currentColor 15%, transparent); }
.tile .k { font-size: .78rem; opacity: .7; text-transform: uppercase;
           letter-spacing: .03em; }
.tile .v { font-size: 1.35rem; font-weight: 600; margin: .1rem 0;
           font-variant-numeric: tabular-nums; }
.tile .d { font-size: .82rem; opacity: .7; }
td.num, th.num { text-align: right; }
td.barcell { width: 40%; }
.track { height: 10px; }
.bar { height: 10px; min-width: 2px; border-radius: 0 4px 4px 0;
       background: BAR_COLOR; }
""".replace("BAR_COLOR", BLUE)


def hms(secs):
    secs = int(round(secs))
    return f"{secs // 60}m{secs % 60:02d}s"


def gb(n, unit=1e9):
    return "—" if n is None else f"{n / unit:.1f}"


def tile(key, value, detail="", cls=""):
    return (f'<div class="tile"><div class="k">{html.escape(key)}</div>'
            f'<div class="v {cls}">{value}</div>'
            f'<div class="d">{detail}</div></div>')


def arch_section(arch, s):
    """Everything one architecture's summary.json records, drilled down.

    Every figure can be absent -- older runs recorded less, and a failed
    run records less still -- and an absent one is left out or shown as
    an em dash, never as a zero. Zero is a measurement.
    """
    ph = s.get("phases") or {}
    m = s.get("metrics") or {}
    lc = m.get("layer_cache") or {}
    sc = m.get("sccache") or {}
    c = s.get("cost") or {}
    fp = s.get("footprint") or {}
    name = html.escape(arch)
    out = [f"<h2><code>{name}</code></h2>"]

    tiles = []
    for phase in ("cold", "warm"):
        spec = ph.get(phase)
        if not spec:
            continue
        ok = spec.get("rc", 1) == 0
        tiles.append(tile(f"{phase} build", hms(spec.get("seconds", 0)),
                          "passed" if ok else f"FAILED, exit {spec.get('rc')}",
                          "" if ok else "fail"))
    if c.get("usd") is not None:
        rate = c.get("usd_per_min")
        detail = str(c.get("instance", "?"))
        if rate:
            detail += f" at ${rate:.4f}/min"
        if not c.get("rate_verified"):
            detail += ", rate unverified"
        tiles.append(tile("cost", f"${c['usd']:.2f}", html.escape(detail)))
    if lc.get("build_steps"):
        n, d = lc.get("build_steps_cached", 0), lc["build_steps"]
        tiles.append(tile("layer cache", f"{n}/{d}",
                          f"{100 * n / d:.0f}% of build steps cached"))
    if sc.get("hit_rate") is not None:
        tiles.append(tile(
            "sccache", f"{sc['hit_rate']:.1f}%",
            f"{sc.get('hits', 0):,} hits, {sc.get('misses', 0):,} misses"))
    elif sc and not sc.get("requests"):
        tiles.append(tile("sccache", "—", "no compiler ran"))
    if "import_misses" in lc:
        tiles.append(tile("cache imports missed", str(lc["import_misses"]),
                          "refs that do not exist in this registry"))
    if ph:
        errs = sum((ph.get(k) or {}).get("cache_errors", 0)
                   for k in ("cold", "warm"))
        tiles.append(tile("cache export errors", str(errs),
                          "layers that failed to push", "warn" if errs else ""))
    if fp.get("buildkit_store_bytes") is not None:
        tiles.append(tile("BuildKit store",
                          f"{gb(fp['buildkit_store_bytes'])} GB",
                          "what this build materialised"))
    if fp.get("disk_used_bytes") is not None:
        free = fp.get("disk_avail_bytes")
        tiles.append(tile("disk used",
                          f"{gb(fp['disk_used_bytes'], 2**30)} GiB",
                          "" if free is None
                          else f"{gb(free, 2**30)} GiB free"))
    # Two generations of memory figure. Runs that sampled memory while
    # the build ran show the peak. Older runs only have one reading
    # taken after the build from the driver's own cgroup, which does
    # not cover the compilers; it is shown for what it is.
    if fp.get("mem_anon_peak_bytes") is not None:
        low, total = fp.get("mem_available_min_bytes"), fp.get("mem_total_bytes")
        detail = f"sampled {fp.get('mem_samples', 0)} times during the build"
        if low is not None:
            detail = (f"lowest available {gb(low, 2**30)} GiB"
                      + ("" if total is None else f" of {gb(total, 2**30)}"))
        tiles.append(tile("peak memory in use",
                          f"{gb(fp['mem_anon_peak_bytes'], 2**30)} GiB", detail))
        if fp.get("cores"):
            limit = fp.get("cgroup_memory_max")
            limit = ("no memory limit" if limit in (None, "max")
                     else f"limit {gb(int(limit), 2**30)} GiB"
                     if str(limit).isdigit() else "")
            tiles.append(tile("machine", f"{fp['cores']} cores",
                              html.escape(limit)))
    elif fp.get("mem_anon_bytes") is not None:
        tiles.append(tile(
            "memory after build", f"{gb(fp['mem_anon_bytes'], 2**30)} GiB",
            "driver process only, not the compilers"))
    if tiles:
        out.append(f'<div class="tiles">{"".join(tiles)}</div>')

    targets = m.get("targets") or {}
    if targets:
        top = max((t.get("seconds", 0) for t in targets.values()),
                  default=0) or 1
        rows = []
        for tname, t in sorted(targets.items(),
                               key=lambda kv: -kv[1].get("seconds", 0)):
            secs = t.get("seconds", 0)
            label = f"{html.escape(tname)}: {hms(secs)}"
            rows.append(
                f"<tr><td><code>{html.escape(tname)}</code></td>"
                f'<td class="barcell"><div class="track" title="{label}">'
                f'<div class="bar" style="width:{100 * secs / top:.1f}%">'
                f"</div></div></td>"
                f'<td class="num">{hms(secs)}</td>'
                f'<td class="num">{t.get("steps", "—")}</td>'
                f'<td class="num">{t.get("cached", "—")}</td></tr>')
        # A target cannot take longer than the build it is part of. Where
        # one does, the split is wrong and the page says so instead of
        # drawing it as fact: summaries written before the per-target
        # accounting was fixed (2026-11-19) counted a step once for every
        # time BuildKit re-reported it, and those files are still served.
        wall = sum((ph.get(k) or {}).get("seconds", 0) for k in ("cold", "warm"))
        if wall and top > wall * 1.02:
            out.append(
                '<div class="note"><strong>The per-target times below are '
                "not reliable.</strong> The largest is longer than the whole "
                f"build ({hms(top)} against {hms(wall)}), which cannot be "
                "true. Per-target time is known to have been over-counted "
                "in runs recorded before 2026-11-19, and this run shows the "
                "same sign whatever its date. The totals above are "
                "unaffected.</div>")
        out.append(
            "<h3>Where the time went</h3>"
            "<table><thead><tr><th>Target</th><th></th>"
            '<th class="num">Time</th><th class="num">Steps run</th>'
            '<th class="num">Steps cached</th></tr></thead>'
            f'<tbody>{"".join(rows)}</tbody></table>'
            '<p class="sub">Targets build concurrently and a stage shared '
            "by two targets is counted under each, so these times overlap "
            "and add up to more than the wall clock. The sccache figure "
            "covers only the targets that print their statistics.</p>")

    out.append(f'<p class="sub"><a href="{name}/report.md">report.md</a> · '
               f'<a href="{name}/summary.json">summary.json</a></p>')
    return "\n".join(out)


def write_run_html(d, summaries):
    """A per-run page: the drilldown for every architecture in the run."""
    sections = "\n".join(arch_section(a, s)
                         for a, s in sorted(summaries.items()))
    stamp = html.escape(d.name)
    (d / "index.html").write_text(f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Nightly {stamp} — rocm-bake</title>
<link rel="icon" href="{FAVICON}">
<style>{CSS}{RUN_CSS}</style>
</head><body>
<h1>Nightly {stamp}</h1>
<p class="sub"><a href="../">All nightly runs</a></p>
{sections}
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
