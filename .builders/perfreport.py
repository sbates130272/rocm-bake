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


def load_build_events(run_dir):
    """Vertices and transfers per target, from the rawjson streams.

    rawjson repeats a vertex every time its state changes, so the same
    digest appears many times; the last mention carries the final
    start/complete/cached. Keeping the last write per digest is what
    turns the stream back into one row per build step.
    """
    builds = {}
    for path in sorted(run_dir.glob("build-*.jsonl")):
        target = path.name[len("build-"):-len(".jsonl")]
        verts, xfer = {}, {}
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
        out.append(f'<text x="{pad_l + pw + 10}" y="{Y(lv) + 4:.1f}" '
                   f'class="v {dcls}">{html.escape(name)}</text>')
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
    placement = {}
    blog = run / "balance.log"
    if blog.exists():
        for line in blog.read_text(errors="replace").splitlines():
            m = re.search(r"^\s+(\S+) -> (\S+)\s", line)
            if m:
                placement[m.group(1)] = m.group(2)

    rows, span_end = [], 0.0
    for target, data in builds.items():
        builder = placement.get(target, "unknown")
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
    if timeline_chart(run / "timeline.svg", "Build steps by builder", rows,
                      span_end or result.get("seconds")):
        charts.append(("timeline.svg", "Build steps by builder"))

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

    md += ["## Per-target build steps", "",
           "| target | builder | steps | cached | ran | buildkit transfer |",
           "|---|---|---|---|---|---|"]
    for target, data in sorted(builds.items()):
        vs = list(data["vertexes"].values())
        cached = sum(1 for v in vs if v.get("cached"))
        dl = sum(x["current"] for x in data["transfers"].values())
        ran = sum((parse_ts(v["completed"]) - parse_ts(v["started"])).total_seconds()
                  for v in vs
                  if v.get("started") and v.get("completed")
                  and parse_ts(v["started"]) and parse_ts(v["completed"]))
        md.append(f"| {target} | {placement.get(target, '?')} | {len(vs)} "
                  f"| {cached} | {fmt_dur(ran)} | {fmt_bytes(dl)} |")
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
