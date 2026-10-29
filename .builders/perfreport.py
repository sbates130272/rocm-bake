#!/usr/bin/env python3
"""Render a perfrun.sh run directory as a markdown report with SVG charts.

Joins the five streams perfrun.sh collects onto one timeline:

  samples.jsonl    node_exporter, polled   -> CPU/memory/network over time
  build-<t>.jsonl  buildx --progress=rawjson -> what ran where, and when
  sccache.log      the WebDAV vhost's log  -> compiler-cache writes
  zot.jsonl        Zot's structured log    -> layer-cache and image writes
  artifacts.txt    wheelhouse.py           -> what was published

Charts are standalone SVG files beside the markdown rather than inline:
GitHub strips inline <svg> from markdown, but renders an <img> pointing
at one, and an SVG loaded that way is its own document — so its
prefers-color-scheme block works and the charts follow the reader's
theme instead of being legible in only one of them.

Palette is the validated default, slots 1-3 (blue/orange/aqua) keyed to
the three builders. Both modes were checked with the dataviz
validator's all-pairs mode; light-mode aqua sits under 3:1 on the light
surface, so every series is also directly labelled rather than
identified by colour alone.

Usage: perfreport.py [RUN_DIR] [--out report.md]
       with no RUN_DIR, the newest under /var/tmp/rocm-perf.
"""
import argparse
import html
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

PERF_DIR = Path("/var/tmp/rocm-perf")

# Slots 1-3 of the validated categorical palette, light and dark. Keyed
# by builder so a target that moves between nodes keeps the node's
# colour — colour follows the entity, never its rank.
SERIES = {
    "snoc-strix":  ("#2a78d6", "#3987e5"),
    "snoc-think":  ("#eb6834", "#d95926"),
    "snoc-gaming": ("#1baf7a", "#199e70"),
}
INK = ("#0b0b0b", "#f0efec")
INK2 = ("#52514e", "#c3c2b7")
GRID = ("#e4e3df", "#2e2e2c")
SURFACE = ("#fcfcfb", "#1a1a19")


def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def load_jsonl(path):
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def load_trace(run_dir, target):
    """Per-step spans recovered from the builder's own history record.

    Preferred over the rawjson capture. The capture is a live stream
    redirected to a file, and on a real run all three target logs were
    truncated back to the 8-byte `{"v":1}` header partway through,
    losing every vertex for builds that were otherwise healthy. The
    trace is written by BuildKit and read back afterwards, so there is
    no stream to miss. See .builders/perftrace.py.
    """
    path = run_dir / f"trace-{target}.json"
    if not path.exists():
        return None
    try:
        blob = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return None
    # Older traces are a bare list of steps; newer ones carry the
    # builder's reported duration alongside them.
    rows = blob["steps"] if isinstance(blob, dict) else blob
    return {f"span:{i}": r for i, r in enumerate(rows)} or None


def load_build_events(run_dir):
    """Vertices and transfers per target, from the rawjson streams.

    rawjson repeats a vertex every time its state changes, so the same
    digest appears many times; the last mention carries the final
    start/complete/cached. Keeping the last write per digest is what
    turns the stream back into one row per build step.
    """
    builds = {}
    targets = {p.name[len("build-"):-len(".jsonl")]
               for p in run_dir.glob("build-*.jsonl")}
    targets |= {p.name[len("trace-"):-len(".json")]
                for p in run_dir.glob("trace-*.json")}
    for target in sorted(targets):
        path = run_dir / f"build-{target}.jsonl"
        verts, xfer = {}, {}
        traced = load_trace(run_dir, target)
        if traced:
            builds[target] = {"vertexes": traced, "transfers": {}}
            continue
        if not path.exists():
            continue
        for row in load_jsonl(path):
            for v in row.get("vertexes") or []:
                d = v.get("digest")
                if not d:
                    continue
                cur = verts.setdefault(d, {})
                cur["name"] = v.get("name", cur.get("name", "?"))
                for k in ("started", "completed", "cached", "error"):
                    if v.get(k) is not None:
                        cur[k] = v[k]
            for s in row.get("statuses") or []:
                # `current` only climbs, so the last value is the total
                # moved for that status id.
                key = (s.get("vertex"), s.get("id"))
                prev = xfer.get(key, {})
                xfer[key] = {
                    "id": s.get("id"),
                    "current": max(s.get("current") or 0,
                                   prev.get("current", 0)),
                    "total": s.get("total") or prev.get("total", 0),
                    "started": prev.get("started") or s.get("started"),
                }
        builds[target] = {"vertexes": verts, "transfers": xfer}
    return builds


SCCACHE_RE = re.compile(
    r"^(?P<ts>\S+)\s+(?P<ip>\S+)\s+(?P<method>\S+)\s+(?P<uri>\S+)\s+"
    r"(?P<status>\d+)\s+req=(?P<req>\d+)\s+resp=(?P<resp>\d+)\s+"
    r"secs=(?P<secs>[\d.]+)")


def load_sccache(run_dir):
    """Compiler-cache writes: one row per PUT, with the object's size.

    Only PUTs. A GET is a read and does not grow the store, and
    counting it as a write was the thing the old $body_bytes_sent log
    could not distinguish.
    """
    out = []
    path = run_dir / "sccache.log"
    if not path.exists():
        return out
    for line in path.read_text(errors="replace").splitlines():
        m = SCCACHE_RE.match(line.strip())
        if not m or m.group("method") != "PUT":
            continue
        ts = parse_ts(m.group("ts"))
        if ts:
            out.append({"ts": ts, "bytes": int(m.group("req")),
                        "secs": float(m.group("secs")),
                        "status": int(m.group("status"))})
    return sorted(out, key=lambda r: r["ts"])


def load_zot(run_dir):
    """Registry writes: blob and manifest PUTs, with their sizes.

    This is the layer cache landing. cache-to pushes blobs here, so the
    size and timing of these is "what was written to the layer cache
    and when" — the counterpart to the sccache log for the other cache.
    """
    out = []
    for row in load_jsonl(run_dir / "zot.jsonl"):
        method = row.get("method")
        path = row.get("path") or ""
        if method not in ("PUT", "PATCH") or "/blobs/" not in path:
            continue
        ts = parse_ts(row.get("time") or row.get("ts") or "")
        size = row.get("bodySize") or 0
        hdrs = row.get("headers") or {}
        cl = (hdrs.get("Content-Length") or [None])[0]
        try:
            size = max(int(size or 0), int(cl or 0))
        except (TypeError, ValueError):
            pass
        if ts:
            out.append({"ts": ts, "bytes": size, "path": path})
    return sorted(out, key=lambda r: r["ts"])


# ── SVG ───────────────────────────────────────────────────────────
# Hand-built rather than pulled from a plotting library: there is no
# offline chart dependency available here, and these are two forms with
# fixed geometry. Every chart is a standalone document carrying its own
# light/dark rules.

def svg_open(w, h, title):
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
        f'viewBox="0 0 {w} {h}" role="img" '
        f'aria-label="{html.escape(title)}">',
        "<style>",
        f"  .surface{{fill:{SURFACE[0]}}} .ink{{fill:{INK[0]}}}",
        f"  .ink2{{fill:{INK2[0]}}} .grid{{stroke:{GRID[0]};stroke-width:1}}",
        "  text{font-family:ui-sans-serif,-apple-system,Segoe UI,Helvetica,"
        "Arial,sans-serif}",
        "  .t{font-size:13px;font-weight:600} .l{font-size:11px}",
        "  .v{font-size:11px;font-weight:600}",
        "  @media (prefers-color-scheme: dark){",
        f"    .surface{{fill:{SURFACE[1]}}} .ink{{fill:{INK[1]}}}",
        f"    .ink2{{fill:{INK2[1]}}} .grid{{stroke:{GRID[1]}}}",
    ] + [
        # Stroke-only and fill-only are separate classes on purpose. A
        # CSS `fill` wins over a `fill="none"` presentation attribute,
        # so a single class carrying both turned every line chart into
        # a stacked area and hid the series drawn first.
        f"    .s-{i}{{stroke:{d}}} .d-{i}{{fill:{d}}}"
        for i, (_, (_, d)) in enumerate(SERIES.items())
    ] + [
        "  }",
        "  .s-0,.s-1,.s-2{fill:none;stroke-width:2}",
        "  .d-0,.d-1,.d-2{stroke:none}",
    ] + [
        f"  .s-{i}{{stroke:{li}}} .d-{i}{{fill:{li}}}"
        for i, (_, (li, _)) in enumerate(SERIES.items())
    ] + [
        "</style>",
        f'<rect width="{w}" height="{h}" class="surface"/>',
        f'<text x="16" y="24" class="t ink">{html.escape(title)}</text>',
    ]


def fmt_bytes(n):
    n = float(n or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}TB"


def fmt_dur(s):
    s = int(s or 0)
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m{s % 60:02d}s"
    return f"{s // 3600}h{(s % 3600) // 60:02d}m"


def line_chart(path, title, series, y_label, y_max=None, fmt=lambda v: f"{v:.0f}"):
    """Multi-line over time. series: {name: [(seconds, value), ...]}.

    Legend plus a direct label at each line's end: two series or more
    always carry a legend, and the light-mode contrast WARN on aqua
    makes the direct label obligatory rather than optional.
    """
    w, h = 900, 300
    pad_l, pad_r, pad_t, pad_b = 54, 112, 40, 34
    pts = [p for v in series.values() for p in v]
    if not pts:
        return False
    x_max = max(p[0] for p in pts) or 1
    y_max = y_max or (max(p[1] for p in pts) or 1) * 1.1
    pw, ph = w - pad_l - pad_r, h - pad_t - pad_b

    def X(t):
        return pad_l + pw * (t / x_max)

    def Y(v):
        return pad_t + ph * (1 - min(v, y_max) / y_max)

    out = svg_open(w, h, title)
    for i in range(5):
        v = y_max * i / 4
        y = Y(v)
        out.append(f'<line x1="{pad_l}" y1="{y:.1f}" x2="{pad_l + pw}" '
                   f'y2="{y:.1f}" class="grid"/>')
        out.append(f'<text x="{pad_l - 8}" y="{y + 4:.1f}" text-anchor="end" '
                   f'class="l ink2">{fmt(v)}</text>')
    out.append(f'<text x="16" y="{h - 8}" class="l ink2">'
               f'{html.escape(y_label)} · elapsed {fmt_dur(x_max)}</text>')
    ends = []
    for idx, (name, vals) in enumerate(series.items()):
        if not vals:
            continue
        slot = list(SERIES).index(name) if name in SERIES else idx
        cls, dcls = f"s-{slot}", f"d-{slot}"
        d = " ".join(f"{'M' if i == 0 else 'L'}{X(t):.1f},{Y(v):.1f}"
                     for i, (t, v) in enumerate(sorted(vals)))
        out.append(f'<path d="{d}" class="{cls}" '
                   f'stroke-linejoin="round" stroke-linecap="round"/>')
        lt, lv = sorted(vals)[-1]
        out.append(f'<circle cx="{X(lt):.1f}" cy="{Y(lv):.1f}" r="4" '
                   f'class="{dcls}"/>')
        ends.append((Y(lv), name, dcls))

    # Direct labels, pushed apart so they stay readable. Series that
    # finish at the same value land on the same y and overprint into an
    # unreadable smear — three idle builders all ending near 0% did
    # exactly that. Nudging is better than dropping one: the label is
    # what carries identity for the series whose colour sits under 3:1
    # on the light surface.
    GAP = 14
    placed = []
    for y, name, dcls in sorted(ends):
        if placed and y - placed[-1] < GAP:
            y = placed[-1] + GAP
        placed.append(y)
        out.append(f'<text x="{pad_l + pw + 10}" y="{y + 4:.1f}" '
                   f'class="v {dcls}">{html.escape(name)}</text>')
    out.append("</svg>")
    path.write_text("\n".join(out) + "\n")
    return True


# Coarse phases, in match order. A build is 16-27 vertices and most
# are sub-second, so drawing one bar each gives a row of slivers with
# no room for a label. Collapsing to the handful of phases anyone
# reasons about ("it spent 38 minutes compiling") is the useful
# granularity; per-step detail stays in the tables.
#
# The patterns are matched against real step text from this repo's
# builds, not guessed. The compile pattern keys on the MAX_JOBS
# preamble (nproc / MemAvailable / njobs) that every compile step here
# shares — without it pytorch's 2316-second build, the single longest
# thing in the run, fell into the catch-all and was labelled "build".
PHASES = (
    ("context",  r"^\[internal\] load"),
    # Anchored. An unanchored, case-insensitive "FROM" matches the
    # word "from" anywhere in a shell command, which swallowed both
    # compile steps - the two longest in the run - and called them
    # image pulls.
    ("pull",     r"^FROM "),
    ("clone",    r"git clone"),
    ("download", r"^ADD |curl -|wget "),
    ("toolchain", r"rustup|tar xzf|sccache --version"),
    ("deps",     r"pip install|apt-get|apt install|requirements/"),
    ("compile",  r"MemAvailable|\bnproc\b|njobs|cmake|ninja|bdist_wheel|"
                 r"setup\.py|make -j"),
    ("verify",   r"python -c|--show-stats|import torch|import triton"),
    ("export",   r"^export|exporting"),
)

# Shell noise that says nothing about what the step did.
_LEAD = re.compile(r"^(RUN|ADD|COPY)\s+|^(if|then|else|fi|set|cd)\s+")


def phase_of(name):
    """A coarse phase for a build step, or a short label from its text.

    The fallback is the step's first couple of meaningful words rather
    than a constant. A catch-all bucket called "build" absorbed
    git clone, tar, and the torch compile alike, so a third of every
    chart said "build" and meant nothing.
    """
    for label, pat in PHASES:
        if re.search(pat, name, re.I):
            return label
    text = _LEAD.sub("", name.strip())
    words = [w for w in re.split(r"\s+", text) if w and not w.startswith("-")]
    return " ".join(words[:2])[:18] or "step"


def group_steps(steps, min_frac=0.0, span=None):
    """Merge consecutive same-phase steps into one band.

    Consecutive by start time, so a compile split across several RUNs
    reads as one compile. Bands are not merged across a gap in phase:
    pull -> compile -> pull stays three bands, because collapsing it
    would claim the node was compiling while it was fetching.
    """
    out = []
    for st in sorted(steps, key=lambda r: r["start"]):
        ph = phase_of(st["label"])
        end = st["start"] + st["dur"]
        # Keep the raw command and its duration. A band that says
        # "compile 38m" is the headline; the question straight after
        # is always "compiling what", and the answer is already here.
        detail = {"cmd": re.sub(r"\s+", " ", st["label"]).strip()[:300],
                  "dur": round(st["dur"], 1),
                  "start": round(st["start"], 1)}
        if out and out[-1]["label"] == ph and st["start"] <= out[-1]["end"] + 2:
            out[-1]["end"] = max(out[-1]["end"], end)
            out[-1]["n"] += 1
            out[-1]["steps"].append(detail)
        else:
            out.append({"label": ph, "start": st["start"], "end": end,
                        "n": 1, "steps": [detail]})
    bands = []
    for b in out:
        dur = b["end"] - b["start"]
        if span and min_frac and dur < span * min_frac:
            continue
        bands.append({"start": b["start"], "dur": dur,
                      "phase": b["label"], "steps": b["steps"],
                      "label": f'{b["label"]} ({b["n"]})' if b["n"] > 1
                               else b["label"]})
    return bands


def faceted_steps_chart(path, title, series, steps, y_label,
                        y_max=None, fmt=lambda v: f"{v:.0f}"):
    """One panel per builder: a metric line over a strip of build steps.

    Small multiples rather than one overlaid plot. Three CPU traces and
    three sets of build steps on shared axes is unreadable, and putting
    steps on a second y-scale would be a dual-axis chart — the thing
    that misleads most reliably. Faceting keeps one scale, and the
    panels share an x-axis so a spike in one can be read against what
    another node was doing at that instant.

    The step strip sits under its own panel's line, so "what was this
    node running when it hit 100%" is a vertical glance rather than a
    cross-reference.
    """
    builders = sorted(set(series) | set(steps))
    if not builders:
        return False
    pts = [p for v in series.values() for p in v]
    if not pts:
        return False
    x_max = max(p[0] for p in pts) or 1
    y_max = y_max or (max(p[1] for p in pts) or 1) * 1.1

    # pad_t leaves room for the title and the legend beneath it.
    w, pad_l, pad_r, pad_t = 900, 54, 112, 64
    line_h, strip_h, gap = 96, 26, 26
    panel = line_h + strip_h
    h = pad_t + len(builders) * (panel + gap) + 44
    pw = w - pad_l - pad_r

    def X(t):
        return pad_l + pw * (max(0.0, min(t, x_max)) / x_max)

    out = svg_open(w, h, title)

    # A legend as well as the per-panel direct labels. Two or more
    # series always carry one, and here it doubles as the key for the
    # step strips, which are the same hue as their line.
    lx = pad_l
    for i, b in enumerate(builders):
        slot = list(SERIES).index(b) if b in SERIES else i
        out.append(f'<rect x="{lx}" y="{pad_t-30}" width="10" height="10" '
                   f'rx="2" class="d-{slot}"/>')
        out.append(f'<text x="{lx+16}" y="{pad_t-21}" class="l ink">'
                   f'{html.escape(b)}</text>')
        lx += 26 + len(b) * 6.4

    # Wall-clock ticks along the time axis, zeroed at the start of the
    # run. Without them the only time reference was a total in the
    # footer, so a feature in the trace could not be placed.
    step = 300 if x_max > 1500 else (120 if x_max > 600 else 60)
    t = 0
    while t <= x_max:
        tx = X(t)
        out.append(f'<line x1="{tx:.1f}" y1="{pad_t-6}" x2="{tx:.1f}" '
                   f'y2="{h-30}" class="grid" opacity="0.5"/>')
        out.append(f'<text x="{tx:.1f}" y="{h-18}" text-anchor="middle" '
                   f'class="l ink2">{fmt_dur(t) if t else "0"}</text>')
        t += step

    y = pad_t
    for i, b in enumerate(builders):
        slot = list(SERIES).index(b) if b in SERIES else i
        cls, dcls = f"s-{slot}", f"d-{slot}"

        def Y(v, top=y):
            return top + line_h * (1 - min(max(v, 0), y_max) / y_max)

        for frac in (0, 0.5, 1):
            gy = Y(y_max * frac)
            out.append(f'<line x1="{pad_l}" y1="{gy:.1f}" x2="{pad_l+pw}" '
                       f'y2="{gy:.1f}" class="grid"/>')
            out.append(f'<text x="{pad_l-8}" y="{gy+4:.1f}" text-anchor="end" '
                       f'class="l ink2">{fmt(y_max*frac)}</text>')
        out.append(f'<text x="{pad_l+pw+10}" y="{y+14:.0f}" '
                   f'class="v {dcls}">{html.escape(b)}</text>')

        vals = sorted(series.get(b) or [])
        if vals:
            d = " ".join(f"{'M' if j == 0 else 'L'}{X(t):.1f},{Y(v):.1f}"
                         for j, (t, v) in enumerate(vals))
            out.append(f'<path d="{d}" class="{cls}" stroke-linejoin="round"/>')

        # The strip. Steps are packed greedily into rows so concurrent
        # ones do not overdraw, same as the standalone timeline.
        sy = y + line_h + 6
        rows, ends = [], []
        # Drop bands under 1% of the run: at 900px wide they are
        # sub-pixel and only add noise.
        banded = group_steps(steps.get(b) or [], min_frac=0.01, span=x_max)
        for st in sorted(banded, key=lambda r: r["start"]):
            for li, e in enumerate(ends):
                if st["start"] >= e - 1e-9:
                    ends[li] = st["start"] + st["dur"]
                    rows.append((li, st))
                    break
            else:
                ends.append(st["start"] + st["dur"])
                rows.append((len(ends) - 1, st))
        rh = max(6, strip_h // max(1, len(ends)))
        for li, st in rows:
            x0 = X(st["start"])
            bw = max(1.5, X(st["start"] + st["dur"]) - x0)
            out.append(f'<rect x="{x0:.1f}" y="{sy + li*rh:.0f}" '
                       f'width="{bw:.1f}" height="{max(4, rh-2)}" rx="2" '
                       f'class="{dcls}"/>')
            room = int((bw - 8) / 5.6)
            if room >= 5 and rh >= 10:
                out.append(f'<text x="{x0+4:.1f}" y="{sy + li*rh + rh - 4:.0f}" '
                           f'class="l" fill="{SURFACE[0]}" stroke="none">'
                           f'{html.escape(st["label"][:room])}</text>')
        if not rows:
            out.append(f'<text x="{pad_l+4}" y="{sy+12:.0f}" class="l ink2">'
                       f'(no step trace recovered)</text>')
        y += panel + gap

    out.append(f'<text x="16" y="{h-4}" class="l ink2">'
               f'{html.escape(y_label)} · time from run start · '
               f'bars below each line are that node\u2019s build steps</text>')
    out.append("</svg>")
    path.write_text("\n".join(out) + "\n")
    return True


def timeline_chart(path, title, rows, total):
    """One row per builder; a span per build step, coloured by builder.

    This is the "what was each builder doing at 14:32" view. Steps are
    drawn in the builder's own colour so a glance across a column says
    which machines were busy; cached steps are hollow, because a step
    that took no time is not the same event as one that ran.
    """
    if not rows:
        return False
    builders = sorted({r["builder"] for r in rows})
    total = total or 1

    # Greedy sub-lane packing. A builder runs vertices concurrently —
    # that is the point of MAX_JOBS — so a single row per builder
    # overdraws them and two parallel steps read as one long one. Each
    # span goes in the first sub-lane free at its start time.
    packed, sub_count = {}, {}
    for b in builders:
        ends = []
        for r in sorted((r for r in rows if r["builder"] == b),
                        key=lambda r: r["start"]):
            for li, end in enumerate(ends):
                if r["start"] >= end - 1e-9:
                    ends[li] = r["start"] + r["dur"]
                    packed.setdefault(b, []).append((li, r))
                    break
            else:
                ends.append(r["start"] + r["dur"])
                packed.setdefault(b, []).append((len(ends) - 1, r))
        sub_count[b] = max(1, len(ends))

    row_h, w = 22, 900
    pad_l, pad_r, pad_t = 118, 20, 40
    lanes_total = sum(sub_count[b] for b in builders)
    h = pad_t + row_h * lanes_total + 10 * len(builders) + 34
    pw = w - pad_l - pad_r

    out = svg_open(w, h, title)
    y = pad_t
    for i, b in enumerate(builders):
        block_h = row_h * sub_count[b]
        out.append(f'<text x="16" y="{y + block_h / 2 + 4:.0f}" '
                   f'class="l ink">{html.escape(b)}</text>')
        out.append(f'<line x1="{pad_l}" y1="{y + block_h + 4:.0f}" '
                   f'x2="{pad_l + pw}" y2="{y + block_h + 4:.0f}" '
                   f'class="grid"/>')
        slot = list(SERIES).index(b) if b in SERIES else i
        cls, dcls = f"s-{slot}", f"d-{slot}"
        for li, r in packed.get(b, []):
            x0 = pad_l + pw * (r["start"] / total)
            bw = max(1.5, pw * (r["dur"] / total))
            # 2px of surface between stacked spans, so adjacent fills
            # stay distinguishable rather than merging into one block.
            y0 = y + li * row_h + 2
            bh = row_h - 4
            if r.get("cached"):
                out.append(f'<rect x="{x0:.1f}" y="{y0}" width="{bw:.1f}" '
                           f'height="{bh}" rx="3" class="{cls}" '
                           f'stroke-width="1.5" opacity="0.6"/>')
            else:
                out.append(f'<rect x="{x0:.1f}" y="{y0}" width="{bw:.1f}" '
                           f'height="{bh}" rx="3" class="{dcls}"/>')
            # Truncated to what the bar can actually hold, not a fixed
            # character count: a label sized for the widest bar spills
            # across its neighbours on every narrower one, which is
            # what made adjacent steps read as a single run.
            room = int((bw - 10) / 6.2)
            if room >= 6:
                # A filled bar needs surface-coloured text to be legible
                # on it; a hollow one has the surface behind it, so the
                # same colour would be invisible — which is exactly how
                # every cached step lost its label.
                tc = (f'class="l {dcls}"' if r.get("cached")
                      else f'class="l" fill="{SURFACE[0]}" stroke="none"')
                out.append(
                    f'<text x="{x0 + 5:.1f}" y="{y0 + bh - 5}" {tc}>'
                    f'{html.escape(r["label"][:room])}</text>')
        y += block_h + 10
    out.append(f'<text x="16" y="{h - 8}" class="l ink2">'
               f'elapsed {fmt_dur(total)} · hollow = cached step · '
               f'stacked rows are concurrent steps</text>')
    out.append("</svg>")
    path.write_text("\n".join(out) + "\n")
    return True


def cumulative(events, t0):
    """(elapsed_seconds, cumulative_bytes) from timestamped write events."""
    total, out = 0, []
    for e in events:
        total += e["bytes"]
        out.append(((e["ts"] - t0).total_seconds(), total))
    return out


# ── interactive ───────────────────────────────────────────────────
# The SVGs stay: they embed in markdown and need no runtime. This is
# the companion for interrogating a run. A static chart answers "what
# was the shape"; the next questions are always "which node, and what
# was it doing then", which wants a cursor and a way to drop the
# series you are not asking about.

TEMPLATE = Path(__file__).with_name("perfreport.html.tmpl")


def interactive_chart(path, title, sub, metrics, targets,
                      unit="%", y_max=None,
                      x_label="Wall Clock Time (s)", y_label="CPU Load"):
    """Standalone interactive HTML: overlaid lines, two filter groups.

    Two dimensions, because they answer different questions. The lines
    are per builder — "was this machine busy". The bands are per
    target — "what was it building, and for how long". Earlier the
    bands were grouped by builder and labelled only with a phase, so a
    node running three targets over a run showed one anonymous strip
    and the chart could not answer the question people actually bring
    to it, which is which target is slow.

    `targets` is a list of dicts: name, builder, steps (start/dur/label).
    Band colour follows the builder that ran it, so the two groups stay
    visually tied; the label carries the target.
    """
    if not TEMPLATE.exists():
        return False

    def colour_for(name, i):
        slot = list(SERIES).index(name) if name in SERIES else i
        return list(SERIES.values())[slot % len(SERIES)][0]

    # Several metrics on one axis, which is legal because they are all
    # percentages. A second y-scale would not be: two scales on one
    # plot is the chart form that misleads most reliably, so a metric
    # in different units gets its own chart instead.
    rows, xmax, peak_all = [], 0.0, 0.0
    builders = sorted({b for m in metrics.values() for b in m})
    for m in metrics.values():
        for pts in m.values():
            if pts:
                xmax = max(xmax, max(p[0] for p in pts))
    for mi, (metric, by_builder) in enumerate(metrics.items()):
        for i, name in enumerate(builders):
            pts = sorted(by_builder.get(name) or [])
            if not pts:
                continue
            vals = [p[1] for p in pts]
            peak_all = max(peak_all, max(vals))
            rows.append({
                "id": f"s{mi}_{i}", "name": name, "metric": metric,
                "color": colour_for(name, i),
                "dash": "6 4" if mi else "",
                "points": [[round(t, 1), round(v, 2)] for t, v in pts],
                "peak": max(vals), "mean": sum(vals) / len(vals)})
    if not rows:
        return False

    builder_slot = {b: j for j, b in enumerate(builders)}
    tgts = []
    for k, t in enumerate(sorted(targets, key=lambda d: d.get("start", 0))):
        bands = group_steps(t.get("steps") or [], min_frac=0.005,
                            span=xmax or 1)
        if not bands:
            continue
        b = t.get("builder", "unknown")
        tgts.append({
            "id": f"t{k}", "name": t["name"], "builder": b,
            "running": bool(t.get("running")),
            "color": colour_for(b, builder_slot.get(b, k)),
            "start": round(min(x["start"] for x in bands), 1),
            "dur": round(max(x["start"] + x["dur"] for x in bands)
                         - min(x["start"] for x in bands), 1),
            "bands": [{"start": round(x["start"], 1),
                       "dur": round(x["dur"], 1), "label": x["label"],
                       "phase": x.get("phase", x["label"]),
                       "steps": x.get("steps", [])}
                      for x in bands],
        })

    data = {"series": rows, "targets": tgts, "xmax": xmax or 1,
            "metrics": list(metrics), "builders": builders,
            "ymax": y_max or max(10.0, peak_all * 1.1), "unit": unit}
    # Also as a sidecar, so a live page can poll the data alone and
    # redraw in place. A full reload would work too, and would also
    # throw away whichever builders and targets the viewer had
    # filtered down to - which is exactly what they were looking at.
    (path.parent / "data.json").write_text(json.dumps(data))

    doc = TEMPLATE.read_text()
    for token, value in (("__DATA__", json.dumps(data)),
                         ("__TITLE__", html.escape(title)),
                         ("__SUB__", html.escape(sub)),
                         ("__XLABEL__", html.escape(x_label)),
                         ("__YLABEL__", html.escape(y_label))):
        doc = doc.replace(token, value)
    path.write_text(doc)
    return True


def fmt_clock(seconds):
    """Elapsed as HH:MM:SS from the start of the run.

    Not the absolute time of day. The point of this column is to line
    targets up against each other and against a previous run, and two
    runs started hours apart share no wall-clock origin — whereas
    "00:39:00" means the same thing in both.
    """
    s = int(max(0, seconds or 0))
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"


def target_spans(run_dir):
    """{target: (start, end)} as datetimes, from a run's recovered traces.

    Reads the traces rather than the build records: a record's duration
    includes setup and export outside the steps, and after the
    cache-to fix the two differ by seconds rather than minutes — but
    the trace is the one that only ever counts work.
    """
    out = {}
    for path in sorted(run_dir.glob("trace-*.json")):
        target = path.name[len("trace-"):-len(".json")]
        try:
            blob = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        rows = blob["steps"] if isinstance(blob, dict) else blob
        meta = blob.get("meta", {}) if isinstance(blob, dict) else {}
        starts = [parse_ts(r.get("started")) for r in rows]
        ends = [parse_ts(r.get("completed")) for r in rows]
        starts = [x for x in starts if x]
        ends = [x for x in ends if x]
        if starts and ends:
            out[target] = (min(starts), max(ends),
                           meta.get("reported_seconds") or 0.0)
    return out


def previous_run(run_dir):
    """The run immediately before this one, by stamped directory name.

    By name, not mtime: rendering a report into an older run touches
    it, and an mtime sort would then call it the newest.
    """
    sibs = sorted(p for p in run_dir.parent.glob("*/")
                  if p.is_dir() and p.name != run_dir.name)
    earlier = [p for p in sibs if p.name < run_dir.name]
    return earlier[-1] if earlier else None


def read_placement(run_dir):
    """{target: node} from balance.log, in either scheduling format.

    The balancer emits two shapes. Stage mode writes
    "   <target> -> <node>   (log: ...)"; queue mode writes
    "   <node>: starting <target>". Parsing only the first meant every
    target resolved to "unknown" under --queue — the timeline collapsed
    onto one lane and colour stopped following the builder.
    """
    out = {}
    path = run_dir / "balance.log"
    if not path.exists():
        return out
    for line in path.read_text(errors="replace").splitlines():
        m = re.search(r"^\s+(\S+) -> (\S+)\s", line)
        if m:
            out[m.group(1)] = m.group(2)
            continue
        m = re.search(r"^\s+(\S+): (?:starting|finished) (\S+)\s*$", line)
        if m:
            out[m.group(2)] = m.group(1)
    return out


def finished_targets(run_dir):
    """Targets the balancer has reported finishing.

    Authoritative, unlike "has no trace yet": trace capture can fail
    or lag, and treating its absence as "still running" marked four
    completed targets as in-flight.
    """
    out = set()
    path = run_dir / "balance.log"
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            m = re.search(r"^\s+\S+: finished (\S+)\s*$", line)
            if m:
                out.add(m.group(1))
    return out


def live_targets(run_dir, placement, done, t0):
    """Targets that have started but have no trace yet.

    A trace only exists once a target finishes, so mid-run the chart
    had nothing to show for whatever was actually building. The
    balancer truncates /tmp/balance-<target>.log when it starts a
    target, so that file's first write is the start and its continued
    growth is the proof it is still going.
    """
    out = []
    now = datetime.now(timezone.utc)
    done = set(done) | finished_targets(run_dir)
    for target, node in placement.items():
        if target in done:
            continue
        log = Path("/tmp") / f"balance-{target}.log"
        if not log.exists():
            continue
        try:
            stat = log.stat()
        except OSError:
            continue
        # Birth time, not mtime. The balancer truncates this file when
        # it starts a target, so birth is the start; mtime is the last
        # write, which for a live build is ~now — using it made every
        # in-flight band one second long and filtered as sub-pixel.
        born = getattr(stat, "st_birthtime", 0) or 0
        if not born:
            try:
                born = int(subprocess.run(
                    ["stat", "-c", "%W", str(log)], capture_output=True,
                    text=True, timeout=5).stdout.strip() or 0)
            except (OSError, ValueError, subprocess.SubprocessError):
                born = 0
        if not born:
            continue        # no reliable start; better absent than wrong
        st = datetime.fromtimestamp(born, timezone.utc)
        start = max(0.0, (st - t0).total_seconds())
        out.append({"name": target, "builder": node, "running": True,
                    "steps": [{"start": start, "label": "running",
                               "dur": max(1.0, (now - st).total_seconds())}],
                    "start": start})
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("run_dir", nargs="?", default=None)
    ap.add_argument("--out", default="report.md")
    args = ap.parse_args()

    if args.run_dir:
        run = Path(args.run_dir)
    else:
        runs = sorted(p for p in PERF_DIR.glob("*") if p.is_dir())
        if not runs:
            sys.exit(f"no runs under {PERF_DIR} — run `make perf-run` first")
        run = runs[-1]
    if not run.is_dir():
        sys.exit(f"not a directory: {run}")

    meta = {}
    if (run / "run.json").exists():
        meta = json.loads((run / "run.json").read_text())
    result = {}
    if (run / "result.json").exists():
        result = json.loads((run / "result.json").read_text())

    samples = [r for r in load_jsonl(run / "samples.jsonl") if "t" in r]
    builds = load_build_events(run)
    sccache = load_sccache(run)
    zot = load_zot(run)

    if not samples:
        sys.exit(f"{run}/samples.jsonl is empty — nothing to report")
    t0_epoch = min(r["t"] for r in samples)
    t0 = min((parse_ts(r["ts"]) for r in samples if parse_ts(r["ts"])),
             default=datetime.now(timezone.utc))

    # ── charts ───────────────────────────────────────────────────
    charts = []
    cpu = {}
    net = {}
    for r in samples:
        if r.get("cpu_busy_pct") is None:
            continue
        cpu.setdefault(r["builder"], []).append(
            (r["t"] - t0_epoch, r["cpu_busy_pct"]))
        if r.get("net_rx_bps") is not None:
            net.setdefault(r["builder"], []).append(
                (r["t"] - t0_epoch, r["net_rx_bps"] / 1048576))
    if line_chart(run / "cpu.svg", "CPU busy by builder", cpu,
                  "% of all cores busy", y_max=100,
                  fmt=lambda v: f"{v:.0f}%"):
        charts.append(("cpu.svg", "CPU busy by builder"))
    if line_chart(run / "net.svg", "Network receive by builder", net,
                  "MB/s received", fmt=lambda v: f"{v:.0f}"):
        charts.append(("net.svg", "Network receive by builder"))

    # Which builder ran which target: balance.sh logs the placement.
    placement = read_placement(run)

    rows, span_end, by_target = [], 0.0, []
    for target, data in builds.items():
        builder = placement.get(target, "unknown")
        steps = []
        for v in data["vertexes"].values():
            st, cp = parse_ts(v.get("started")), parse_ts(v.get("completed"))
            if not st or not cp:
                continue
            start = (st - t0).total_seconds()
            dur = (cp - st).total_seconds()
            if dur < 0.5 and v.get("cached"):
                continue        # cached no-ops would be invisible hairlines
            span_end = max(span_end, start + dur)
            name = re.sub(r"^\[[^\]]*\]\s*", "", v.get("name", "?"))
            rows.append({"builder": builder, "start": max(0.0, start),
                         "dur": dur, "cached": bool(v.get("cached")),
                         "label": f"{target} {name}"})
            steps.append({"start": max(0.0, start), "dur": dur,
                          "label": name})
        if steps:
            by_target.append({"name": target, "builder": builder,
                              "steps": steps,
                              "start": min(x["start"] for x in steps)})
    if timeline_chart(run / "timeline.svg", "Build steps by builder", rows,
                      span_end or result.get("seconds")):
        charts.append(("timeline.svg", "Build steps by builder"))

    # The interactive page, beside the static charts. The SVGs embed in
    # markdown and need no runtime; this is for interrogating a run —
    # filter by builder and by target, hover a band for the commands it
    # covers. `make perf-serve` serves the directory this lands in.
    # Memory as percent used, so it shares the CPU axis honestly —
    # both are percentages, which is what makes one plot legitimate
    # rather than a dual-axis chart.
    mem_pct = {}
    for r in samples:
        tot = r.get("mem_total_bytes") or 0
        avail = r.get("mem_available_bytes")
        if tot and avail is not None:
            mem_pct.setdefault(r["builder"], []).append(
                (r["t"] - t0_epoch, 100.0 * (tot - avail) / tot))
    # Targets that have started but not finished, so a run in flight
    # shows what each node is doing rather than an empty strip.
    by_target += live_targets(run, placement, {t["name"] for t in by_target}, t0)

    if interactive_chart(run / "index.html", "CPU Load and Memory",
                         f"{meta.get('arch', '?')} · "
                         f"{len(by_target)} targets · "
                         f"{fmt_dur(result.get('seconds'))}",
                         {"cpu": cpu, "memory": mem_pct},
                         by_target, unit="%", y_max=100):
        charts.append(("index.html", "Interactive chart"))

    writes = {}
    if sccache:
        writes["sccache"] = cumulative(sccache, t0)
    if zot:
        writes["layer cache (Zot)"] = cumulative(zot, t0)
    if writes:
        scaled = {k: [(t, v / 1073741824) for t, v in s]
                  for k, s in writes.items()}
        if line_chart(run / "writes.svg", "Cache bytes written (cumulative)",
                      scaled, "GB written", fmt=lambda v: f"{v:.1f}"):
            charts.append(("writes.svg", "Cache bytes written (cumulative)"))

    # ── markdown ─────────────────────────────────────────────────
    md = [f"# Cold parallel wheel build — {meta.get('stamp', run.name)}", ""]
    md.append(f"- **arch** `{meta.get('arch', '?')}` "
              f"· **commit** `{meta.get('vcs_ref', '?')}`"
              f"{' (dirty)' if meta.get('vcs_dirty') else ''}")
    md.append(f"- **wall clock** {fmt_dur(result.get('seconds'))} "
              f"· **exit** {result.get('rc', '?')}")
    md.append(f"- **sample interval** {meta.get('interval_seconds', '?')}s "
              f"· **sccache prefix** `{meta.get('sccache_key_prefix', '?')}`")
    md.append("")
    md.append("> Throughput, not isolated per-target cost: the builds ran "
              "concurrently and shared the sccache store and registry, both "
              "on Strix, which is also a build node. For clean per-wheel "
              "numbers use `bench.sh cold`, which serialises on purpose.")
    md.append("")

    for fname, title in charts:
        md += [f"## {title}", "", f"![{title}]({fname})", ""]

    md += ["## Per-builder totals", "",
           "| builder | peak CPU | mean CPU | min free mem | net received |",
           "|---|---|---|---|---|"]
    for b in sorted({r["builder"] for r in samples}):
        rs = [r for r in samples if r["builder"] == b
              and r.get("cpu_busy_pct") is not None]
        if not rs:
            continue
        cpus = [r["cpu_busy_pct"] for r in rs]
        mem = [r["mem_available_bytes"] for r in rs
               if r.get("mem_available_bytes")]
        rx = sum((r.get("net_rx_bps") or 0) * (r.get("interval_seconds") or 0)
                 for r in rs)
        md.append(f"| {b} | {max(cpus):.0f}% | {sum(cpus) / len(cpus):.0f}% "
                  f"| {fmt_bytes(min(mem)) if mem else '-'} "
                  f"| {fmt_bytes(rx)} |")
    md.append("")

    # Per-target, with where and when. The start column is what makes
    # a stage barrier visible: every target in a stage shares a start
    # to the second, and the gap to the next stage is the whole cost
    # of the slowest one in the previous.
    spans = target_spans(run)
    prev_dir = previous_run(run)
    prev_spans = target_spans(prev_dir) if prev_dir else {}

    md += ["## Per-target build steps", ""]
    head = "| target | node | start | build | total | cached |"
    sep = "|---|---|---|---|---|---|"
    if prev_spans:
        head = ("| target | node | start | build | total | prev total "
                "| change | cached |")
        sep = "|---|---|---|---|---|---|---|---|"
    md += [head, sep]

    for target, (st, en, rep) in sorted(spans.items(),
                                        key=lambda kv: kv[1][0]):
        data = builds.get(target, {"vertexes": {}})
        vs = list(data["vertexes"].values())
        cached = sum(1 for v in vs if v.get("cached"))
        dur = (en - st).total_seconds()
        # Both numbers. `build` is the span of the target's own steps;
        # `total` is what the builder reported for it. The gap is setup
        # plus cache export, and quoting only the first would hide
        # exactly what clearing cache-to was worth.
        cells = [target, placement.get(target, "?"),
                 fmt_clock((st - t0).total_seconds()), fmt_dur(dur),
                 fmt_dur(rep) if rep else "-"]
        if prev_spans:
            was = prev_spans.get(target)
            if was:
                pd = (was[1] - was[0]).total_seconds()
                prep = was[2] if len(was) > 2 else 0
                # Compare like with like. A run traced before the
                # reported duration was recorded has only spans, and
                # putting this run's total against that run's span
                # measures the difference in what is counted rather
                # than the difference in the build — it showed
                # aiter-wheel at -40% where total against total is
                # -85%. Fall back to span-vs-span and mark it.
                if prep:
                    base, now, mark = prep, (rep or dur), ""
                else:
                    base, now, mark = pd, dur, "*"
                delta = (now - base) / base * 100 if base else 0
                cells += [fmt_dur(base) + mark, f"{delta:+.0f}%{mark}"]
            else:
                cells += ["-", "-"]
        cells += [str(cached)]
        md.append("| " + " | ".join(cells) + " |")
    md.append("")
    md.append("*start* is elapsed from the beginning of this run, so it "
              "compares across runs. *build* is the span of the target's "
              "own steps; *total* is what the builder reported for it. "
              "The gap between them is setup plus cache export — which is "
              "why `change` is computed on *total*. A `*` marks a target "
              "whose previous run predates that measurement, so its "
              "comparison is build-vs-build and excludes the export on "
              "both sides.")
    if prev_dir:
        md.append(f"*previous* is `{prev_dir.name}`.")
    md.append("")
    md.append("*buildkit transfer* is what BuildKit itself moved — context, "
              "layer pulls and exports. Downloads made **inside** a RUN step "
              "(apt, pip, git) are invisible to it and show up only in the "
              "node's network series above, which is why the two disagree.")
    md.append("")

    md += ["## Cache writes", "",
           "| stream | objects | bytes | first | last |", "|---|---|---|---|---|"]
    for label, evs in (("sccache (compiler)", sccache),
                       ("Zot blobs (layer cache)", zot)):
        if not evs:
            md.append(f"| {label} | 0 | - | - | - |")
            continue
        md.append(f"| {label} | {len(evs)} "
                  f"| {fmt_bytes(sum(e['bytes'] for e in evs))} "
                  f"| +{fmt_dur((evs[0]['ts'] - t0).total_seconds())} "
                  f"| +{fmt_dur((evs[-1]['ts'] - t0).total_seconds())} |")
    md.append("")

    art = run / "artifacts.txt"
    if art.exists() and art.stat().st_size:
        md += ["## Published artifacts", "", "```",
               re.sub(r"\x1b\[[0-9;]*m", "", art.read_text(errors="replace")).rstrip(),
               "```", ""]

    out = run / args.out
    out.write_text("\n".join(md) + "\n")
    print(f"report: {out}")
    for fname, _ in charts:
        print(f"  chart: {run / fname}")
    if not sccache:
        log_path = run / "sccache.log"
        if not log_path.exists() or not log_path.stat().st_size:
            print("  note: no sccache log captured for this run")
        elif any(" PUT " in ln for ln in
                 log_path.read_text(errors="replace").splitlines()):
            # PUTs are there but none parsed, so the line shape is wrong
            # — that is the case the sized format actually fixes.
            print("  note: sccache log has PUTs but none parsed — the vhost")
            print("        is on the old format; re-run deploy-webdav.sh")
        else:
            print("  note: no sccache writes this run (nothing compiled)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
