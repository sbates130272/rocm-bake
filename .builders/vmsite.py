#!/usr/bin/env python3
"""Assemble the index over the VM lane's runs published to gh-pages.

The VM lane (.github/workflows/vm.yml) installs the published wheels
into a QEMU guest with an emulated GPU and serves a model through
them. Each run leaves one summary.json, written in the guest by
.builders/vm-test.sh. This turns the set of them into pages.

A third index, beside perfsite.py and nightlysite.py, and separate for
the reason those two are separate from each other. Those time builds.
This times a served model on a GPU that is a program: every number
here is the emulator's speed on a four-core runner, and says nothing
about the card whose name it carries. What the series is good for is
its own shape -- a stage that stopped passing, a startup that doubled
-- which is a statement about our wheels or about the emulator, and
the page says which builds of each a run used.

HTML as well as markdown, as in nightlysite.py: gh-pages carries a
.nojekyll, so a directory with no index.html is a 404.

Reads:

    data/vm/<stamp>/summary.json

Writes beside them:

    data/vm/runs.json           newest first
    data/vm/index.md, index.html
    data/vm/<stamp>/index.html  one run, every check
    data/vm/*.svg               one chart per charted metric

Usage: vmsite.py <data/vm dir>
"""
import html
import json
import sys
from pathlib import Path

# The fleet palette, as in nightlysite.py and perfreport.py, so the
# three pages read as one site. One colour per stage, fixed, so a stage
# is the same colour on every chart and in every run.
STAGES = ["vllm", "lmcache", "nixl-nvme", "nixl-nvmeof"]
COLOURS = {
    "vllm": "#2a78d6",
    "lmcache": "#eb6834",
    "nixl-nvme": "#1baf7a",
    "nixl-nvmeof": "#8a63d2",
}
BLUE, ORANGE = COLOURS["vllm"], COLOURS["lmcache"]

CHECK_CLASS = {"pass": "", "skip": "skip"}

STAGE_TITLES = {
    "install": "Install",
    "vllm": "vLLM alone",
    "lmcache": "LMCache MP, L1",
    "nixl-nvme": "NIXL L2, NVMe",
    "nixl-nvmeof": "NIXL L2, NVMe-oF",
}

# (metric key, chart title, unit, file). Each is drawn only once two
# runs carry it: one bar is not a series.
CHARTS = [
    ("startup_s", "Time to /health", "s", "startup.svg"),
    ("decode_tps", "Decode rate", "tok/s", "decode.svg"),
    ("cached_s", "Repeated prompt, served from the cache", "s", "cached.svg"),
]

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
       max-width: 62rem; margin: 3rem auto; padding: 0 1.25rem; }
h1 { font-size: 1.5rem; margin-bottom: .25rem; }
h2 { font-size: 1.1rem; margin-top: 2.2rem; }
.sub { opacity: .7; margin-top: 0; }
.note { border-left: 3px solid %s; padding: .6rem 0 .6rem .9rem;
        margin: 1.5rem 0; opacity: .85; font-size: .93rem; }
table { border-collapse: collapse; width: 100%%; margin-top: 1rem;
        font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: .45rem .7rem; vertical-align: top;
         border-bottom: 1px solid color-mix(in srgb, currentColor 15%%, transparent); }
th { font-weight: 600; opacity: .7; font-size: .85rem;
     text-transform: uppercase; letter-spacing: .03em; }
code { font: 13px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
       padding: .1rem .3rem; border-radius: 3px;
       background: color-mix(in srgb, currentColor 8%%, transparent); }
a { color: %s; text-decoration-thickness: 1px; text-underline-offset: 2px; }
.fail { color: %s; font-weight: 600; }
.skip { opacity: .45; }
.num { opacity: .7; font-size: .88rem; }
""" % (BLUE, BLUE, ORANGE)

NOTE = ("The GPU here is <strong>emulated</strong>: rocjitsu executes "
        "the card's instructions on the runner's CPU. Every time on this "
        "page is the emulator's on four shared cores and is not a "
        "measurement of any card, or comparable with the "
        '<a href="../perf/">fleet runs</a> or the '
        '<a href="../nightly/">nightly builds</a>, which time builds. '
        "Read a column down, not across: what it shows is a stage that "
        "stopped passing or a time that moved between two builds.")


def load_run(d):
    """One run's summary, or None when the directory holds none."""
    try:
        s = json.loads((d / "summary.json").read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(s, dict) or not isinstance(s.get("stages"), list):
        return None
    s["stamp"] = d.name
    return s


def stage(run, name):
    for st in run["stages"]:
        if st.get("name") == name:
            return st
    return None


def num(value, unit=""):
    """A measurement, or an em dash: absent is not zero."""
    if value is None:
        return "—"
    if isinstance(value, float):
        value = f"{value:.2f}" if value < 10 else f"{value:.1f}"
    return f"{value}{unit}"


def cell(st):
    """(text, css class) for one stage of one run."""
    if st is None:
        return "—", "skip"
    result = st.get("result", "?")
    m = st.get("metrics") or {}
    if result == "skip":
        return "not run", "skip"
    bits = []
    if m.get("startup_s") is not None:
        bits.append(f"up {num(m['startup_s'], 's')}")
    if m.get("decode_tps") is not None:
        bits.append(f"{num(m['decode_tps'])} tok/s")
    if m.get("cached_s") is not None and m.get("computed_s") is not None:
        bits.append(f"{num(m['computed_s'], 's')} → {num(m['cached_s'], 's')}")
    if m.get("seconds") is not None and not bits:
        bits.append(num(m["seconds"], "s"))
    text = "pass" if result == "pass" else result.upper()
    if bits:
        text += " · " + ", ".join(bits)
    return text, "" if result == "pass" else "fail"


def write_chart(root, runs, key, title, unit, name):
    """One metric per run, oldest left, one bar per stage that has it.

    A file referenced by <img>, as in nightlysite.py: GitHub strips
    inline <svg> from markdown. Returns the filename, or None with
    fewer than two runs to compare, in which case a stale file is
    removed so a page never shows a chart its table does not back.
    """
    series = []
    for r in reversed(runs):
        for sname in STAGES:
            st = stage(r, sname)
            v = ((st or {}).get("metrics") or {}).get(key)
            if isinstance(v, (int, float)) and v > 0:
                series.append((r["stamp"], sname, float(v)))
    stamps = sorted({s for s, _, _ in series})
    if len(stamps) < 2:
        (root / name).unlink(missing_ok=True)
        return None
    # The newest that fit: a year of weekly runs is fifty bar groups,
    # and the table below still lists every one.
    stamps = stamps[-24:]
    series = [x for x in series if x[0] in stamps]
    stages = [s for s in STAGES if any(a == s for _, a, _ in series)]

    w, h, pad_l, pad_b, pad_t = 860, 260, 54, 46, 28
    plot_w, plot_h = w - pad_l - 16, h - pad_t - pad_b
    top = max(v for _, _, v in series)
    # A round axis top, so the gridline labels are not 7.13.
    step = 10 ** (len(str(int(top))) - 1) if top >= 1 else 0.1
    top = -(-top // step) * step
    slot = plot_w / len(stamps)
    bw = min(26, slot / (len(stages) + 1))

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
        f'viewBox="0 0 {w} {h}" role="img" '
        f'aria-label="{html.escape(title)} per run">',
        "<style>"
        "  .s{fill:#fff} .i{fill:#1f2328} .i2{fill:#656d76}"
        "  .g{stroke:#d0d7de;stroke-width:1}"
        "  text{font-family:ui-sans-serif,-apple-system,Segoe UI,Helvetica,"
        "Arial,sans-serif}"
        "  .l{font-size:10px} .t{font-size:12px;font-weight:600}"
        "  @media (prefers-color-scheme: dark){"
        "    .s{fill:#0d1117} .i{fill:#e6edf3} .i2{fill:#8b949e}"
        "    .g{stroke:#30363d} }"
        "</style>",
        f'<rect class="s" width="{w}" height="{h}"/>',
        f'<text class="i t" x="12" y="18">{html.escape(title)} '
        f"({html.escape(unit)}), emulated GPU</text>",
    ]
    for frac in (0, 0.25, 0.5, 0.75, 1.0):
        y = pad_t + plot_h - plot_h * frac
        label = top * frac
        label = f"{label:.0f}" if top >= 4 else f"{label:.2f}"
        out.append(f'<line class="g" x1="{pad_l}" y1="{y:.1f}" '
                   f'x2="{w - 16}" y2="{y:.1f}"/>')
        out.append(f'<text class="i2 l" x="{pad_l - 6}" y="{y + 3:.1f}" '
                   f'text-anchor="end">{label}</text>')
    for si, stamp in enumerate(stamps):
        x0 = pad_l + si * slot
        for ai, sname in enumerate(stages):
            vals = [v for st, a, v in series if st == stamp and a == sname]
            if not vals:
                continue
            bh = plot_h * vals[0] / top
            x = x0 + slot / 2 - (len(stages) * bw) / 2 + ai * bw
            out.append(f'<rect x="{x:.1f}" y="{pad_t + plot_h - bh:.1f}" '
                       f'width="{max(1.0, bw - 3):.1f}" height="{bh:.1f}" '
                       f'rx="2" fill="{COLOURS[sname]}"/>')
        # Every label when they fit, else every other one.
        if len(stamps) <= 12 or si % 2 == 0:
            out.append(f'<text class="i2 l" x="{x0 + slot / 2:.1f}" '
                       f'y="{h - pad_b + 16}" text-anchor="middle">'
                       f"{html.escape(stamp[:8])}</text>")
    for ai, sname in enumerate(stages):
        x = pad_l + ai * 150
        out.append(f'<rect x="{x}" y="{h - 16}" width="9" height="9" rx="2" '
                   f'fill="{COLOURS[sname]}"/>')
        out.append(f'<text class="i2 l" x="{x + 13}" y="{h - 8}">'
                   f"{html.escape(STAGE_TITLES[sname])}</text>")
    out.append("</svg>")
    (root / name).write_text("\n".join(out) + "\n")
    return name


def build_of(run):
    """What a run tested: the metapackage version names the whole set."""
    return run.get("rocm_torch") or "?"


def page(title, body):
    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)} — rocm-bake</title>
<link rel="icon" href="{FAVICON}">
<style>{CSS}</style>
</head><body>
{body}
</body></html>
"""


def write_index(root, runs):
    charts = [(t, write_chart(root, runs, k, t, u, n))
              for k, t, u, n in CHARTS]
    chart_html = "\n".join(
        f'<p><img src="{n}" alt="{html.escape(t)} per run" width="860"></p>'
        for t, n in charts if n)

    head = "".join(f"<th>{html.escape(STAGE_TITLES[s])}</th>"
                   for s in ["install"] + STAGES)
    rows = []
    for r in runs:
        stamp = html.escape(r["stamp"])
        cells = ""
        for s in ["install"] + STAGES:
            text, cls = cell(stage(r, s))
            cells += f'<td class="{cls}">{html.escape(text)}</td>'
        rows.append(
            f'<tr><td><a href="{stamp}/">{stamp}</a></td>'
            f"<td><code>{html.escape(build_of(r))}</code></td>{cells}</tr>")
    body = "\n".join(rows) or (
        f'<tr><td colspan="{len(STAGES) + 3}" class="skip">'
        "No runs published yet.</td></tr>")

    (root / "index.html").write_text(page("VM runs", f"""<h1>VM runs</h1>
<p class="sub">The published wheels, installed with pip into a
QEMU guest and serving a model on an emulated GPU, on a GitHub-hosted
runner.</p>
<div class="note">{NOTE}</div>
{chart_html}
<table>
<thead><tr><th>Run</th><th>Build</th>{head}</tr></thead>
<tbody>
{body}
</tbody></table>
<p class="sub">Each stage cell: result, seconds until <code>/health</code>
answered, decode rate, and for the cache stages the same prompt
computed → served from the cache.</p>"""))

    md = ["# VM runs", "",
          "The published wheels, installed with pip into a QEMU "
          "guest and serving a model on an emulated GPU.", "",
          "> The GPU is emulated. These times are the emulator's on a "
          "four-core runner, not a card's, and are comparable only with "
          "each other.", "",
          "| run | build | " + " | ".join(
              STAGE_TITLES[s] for s in ["install"] + STAGES) + " |",
          "| --- | --- |" + " --- |" * (len(STAGES) + 1)]
    for r in runs:
        cells = " | ".join(cell(stage(r, s))[0] for s in ["install"] + STAGES)
        md.append(f"| [{r['stamp']}]({r['stamp']}/) | `{build_of(r)}` | "
                  f"{cells} |")
    (root / "index.md").write_text("\n".join(md) + "\n")


def write_run(root, r):
    """One run: what it ran on, then every check of every stage."""
    e = html.escape
    guest = r.get("guest") or {}
    versions = r.get("versions") or {}
    run = r.get("run") or {}
    facts = [
        ("Build", build_of(r)),
        ("Index", r.get("index")),
        ("Model", r.get("model")),
        ("GPU", guest.get("gpu")),
        ("VRAM", num(guest.get("vram_mb"), " MiB")),
        ("Guest", ", ".join(str(x) for x in (
            guest.get("kernel"),
            f"{guest.get('vcpus')} vCPU" if guest.get("vcpus") else None,
            f"{guest.get('mem_mb')} MiB" if guest.get("mem_mb") else None,
        ) if x)),
        ("Packages", ", ".join(f"{k} {v}" for k, v in sorted(versions.items()))),
        ("qemu-tool", r.get("qemu_tool")),
        ("Commit", run.get("sha")),
    ]
    rows = "\n".join(f"<tr><th>{e(k)}</th><td>{e(str(v))}</td></tr>"
                     for k, v in facts if v not in (None, "", "—"))
    link = (f' · <a href="{e(run["url"])}">workflow run</a>'
            if run.get("url") else "")

    parts = []
    for st in r["stages"]:
        name = st.get("name", "?")
        text, cls = cell(st)
        m = st.get("metrics") or {}
        metrics = ", ".join(f"{k} {num(v)}" for k, v in sorted(m.items()))
        checks = "\n".join(
            f'<tr><td class="{CHECK_CLASS.get(c.get("result"), "fail")}">'
            f'{e(str(c.get("result", "?")))}</td>'
            f'<td>{e(str(c.get("name", "")))}</td>'
            f'<td class="num">{e(str(c.get("detail", "")))}</td></tr>'
            for c in st.get("checks") or [])
        parts.append(
            f'<h2>{e(STAGE_TITLES.get(name, name))} '
            f'<span class="num {cls}">{e(text)}</span></h2>'
            + (f'<p class="num">{e(metrics)}</p>' if metrics else "")
            + (f"<table><tbody>\n{checks}\n</tbody></table>" if checks else ""))

    stamp = e(r["stamp"])
    (root / r["stamp"] / "index.html").write_text(page(
        f"VM run {r['stamp']}",
        f"""<h1>VM run {stamp}</h1>
<p class="sub"><a href="../">All VM runs</a>{link}</p>
<div class="note">{NOTE}</div>
<table><tbody>
{rows}
</tbody></table>
{chr(10).join(parts)}"""))


def main(argv):
    if len(argv) != 1:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    root = Path(argv[0])
    if not root.is_dir():
        print(f"vmsite: {root} is not a directory", file=sys.stderr)
        return 1

    runs = [load_run(d) for d in root.iterdir() if d.is_dir()]
    runs = sorted((r for r in runs if r), key=lambda r: r["stamp"],
                  reverse=True)

    (root / "runs.json").write_text(
        json.dumps([r["stamp"] for r in runs], indent=2) + "\n")
    write_index(root, runs)
    for r in runs:
        write_run(root, r)

    print(f"vmsite: {len(runs)} run(s) -> {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
