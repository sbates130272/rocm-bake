#!/usr/bin/env python3
"""Sample the fleet while a build runs, one JSON line per node per tick.

node_exporter is already running on all three builders, and nothing
scrapes it. Standing up Prometheus would give a real TSDB, but it is a
persistent service to deploy and retain, and what a build report needs
is a few minutes of a handful of series bounded by one run. So this
polls the exporters directly and appends JSONL, the same shape
bench.sh writes its results in.

The cost of that choice is resolution: everything here is a point
sample at --interval, so a spike shorter than the interval is invisible
and a counter that wraps between ticks is lost. Five seconds over a
build measured in hours is fine; do not use this to chase a stall.

Counters (CPU seconds, disk bytes, network bytes) are reported as
deltas against the previous tick rather than raw, because the raw value
is "since boot" and says nothing about the build. The first tick of
each node therefore has no deltas and is written with nulls — the
report drops it.

Usage:
  perfsample.py --out samples.jsonl [--interval 5] [--nodes "a b c"]

Stops on SIGTERM/SIGINT, flushing what it has.
"""
import argparse
import json
import signal
import sys
import time
import urllib.request
from datetime import datetime, timezone

# Mapped to the builder names the rest of the repo uses. node_exporter
# answers on the host, but `snoc-think` is a buildx builder name and
# `snoc-thinkstation` is the host it runs on — the same split bench.sh
# works around when it samples load.
DEFAULT_NODES = {
    "snoc-strix": "snoc-strix.fold-leaffish.ts.net",
    "snoc-think": "snoc-thinkstation",
    "snoc-gaming": "snoc-gaming",
}

# Only the series the report actually plots. Scraping is cheap but
# parsing a full exporter payload every few seconds across three nodes
# is not, and an unused series is a column nobody reads.
WANTED = (
    "node_cpu_seconds_total",
    "node_memory_MemAvailable_bytes",
    "node_memory_MemTotal_bytes",
    "node_disk_read_bytes_total",
    "node_disk_written_bytes_total",
    "node_network_receive_bytes_total",
    "node_network_transmit_bytes_total",
    "node_load1",
    "node_filesystem_avail_bytes",
)

running = True

# Every exporter here is on the tailnet or this host, and the corporate
# proxy cannot reach any of them — it answers "500 Unable to connect"
# for the local one and times out for the others. An empty ProxyHandler
# disables proxying for this opener outright, which is sturdier than
# relying on no_proxy being exported: the Makefile sets it, but this
# script is also run directly.
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def stop(_sig, _frm):
    global running
    running = False


def scrape(host, timeout=4):
    """Parse the wanted series out of one exporter's text exposition."""
    url = f"http://{host}:9100/metrics"
    out = {}
    try:
        with OPENER.open(url, timeout=timeout) as r:
            for raw in r:
                line = raw.decode("utf-8", "replace")
                if line.startswith("#"):
                    continue
                name = line.split("{", 1)[0].split(" ", 1)[0]
                if name not in WANTED:
                    continue
                try:
                    value = float(line.rsplit(" ", 1)[1])
                except (IndexError, ValueError):
                    continue
                labels = line[len(name):line.rfind(" ")].strip()
                out.setdefault(name, []).append((labels, value))
    except Exception as exc:                      # noqa: BLE001
        return None, str(exc)
    return out, None


def fold(series):
    """Collapse the label dimension into the few scalars we report.

    CPU is summed across every core except idle, so one number means
    "core-seconds of work". Disk and network are summed across devices;
    per-device detail is a level of granularity this report does not
    use, and keeping it would make the JSONL wide for nothing.

    Loopback and virtual interfaces are excluded from the network sum.
    They carry the build's own traffic to a local registry and would
    double-count anything already measured as a download.
    """
    cpu_busy = cpu_total = 0.0
    for labels, v in series.get("node_cpu_seconds_total", []):
        cpu_total += v
        if 'mode="idle"' not in labels:
            cpu_busy += v

    def total(metric, skip=()):
        s = 0.0
        for labels, v in series.get(metric, []):
            if any(f'"{p}' in labels or f'="{p}' in labels for p in skip):
                continue
            s += v
        return s

    # dm-/loop devices are views onto a real device already counted.
    disk_skip = ("loop", "dm-", "ram")
    net_skip = ("lo", "docker", "veth", "br-", "tailscale")
    fs = series.get("node_filesystem_avail_bytes", [])
    return {
        "cpu_busy_seconds": cpu_busy,
        "cpu_total_seconds": cpu_total,
        "mem_available_bytes": (series.get("node_memory_MemAvailable_bytes")
                                or [(None, None)])[0][1],
        "mem_total_bytes": (series.get("node_memory_MemTotal_bytes")
                            or [(None, None)])[0][1],
        "disk_read_bytes": total("node_disk_read_bytes_total", disk_skip),
        "disk_written_bytes": total("node_disk_written_bytes_total", disk_skip),
        "net_rx_bytes": total("node_network_receive_bytes_total", net_skip),
        "net_tx_bytes": total("node_network_transmit_bytes_total", net_skip),
        "load1": (series.get("node_load1") or [(None, None)])[0][1],
        "fs_avail_bytes": max((v for _, v in fs), default=None),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True)
    ap.add_argument("--interval", type=float, default=5.0)
    ap.add_argument("--nodes", default="",
                    help="space-separated builder names; default all three")
    args = ap.parse_args()

    nodes = dict(DEFAULT_NODES)
    if args.nodes.strip():
        want = args.nodes.split()
        nodes = {k: v for k, v in DEFAULT_NODES.items() if k in want}
        for name in want:
            nodes.setdefault(name, name)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    prev = {}
    # Line-buffered and flushed every tick: the run this samples can be
    # killed at any point, and a block-buffered file would lose the
    # last few minutes — which is usually the interesting part.
    with open(args.out, "a", buffering=1) as fh:
        while running:
            tick = time.time()
            for builder, host in nodes.items():
                series, err = scrape(host)
                now = datetime.now(timezone.utc).isoformat(timespec="seconds")
                if err:
                    fh.write(json.dumps({"ts": now, "builder": builder,
                                         "error": err}) + "\n")
                    continue
                cur = fold(series)
                row = {"ts": now, "t": tick, "builder": builder, **cur}
                p = prev.get(builder)
                if p:
                    dt = tick - p["t"]
                    row["interval_seconds"] = round(dt, 2)
                    # Percentages and rates, which is what the report
                    # plots; the cumulative counters stay in the row so
                    # a different question can still be asked of it.
                    cpu_d = cur["cpu_busy_seconds"] - p["cpu_busy_seconds"]
                    tot_d = cur["cpu_total_seconds"] - p["cpu_total_seconds"]
                    row["cpu_busy_pct"] = (round(100 * cpu_d / tot_d, 2)
                                           if tot_d > 0 else None)
                    for k, out in (("disk_read_bytes", "disk_read_bps"),
                                   ("disk_written_bytes", "disk_write_bps"),
                                   ("net_rx_bytes", "net_rx_bps"),
                                   ("net_tx_bytes", "net_tx_bps")):
                        row[out] = (round((cur[k] - p[k]) / dt)
                                    if dt > 0 else None)
                prev[builder] = {**cur, "t": tick}
                fh.write(json.dumps(row) + "\n")
            fh.flush()
            # Sleep the remainder of the interval, not the whole of it,
            # so scrape latency does not make the series drift.
            time.sleep(max(0.0, args.interval - (time.time() - tick)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
