#!/usr/bin/env python3
"""Assemble the run-selector site from a directory of perf runs.

The interactive chart is self-contained — perfreport.py embeds the data
in index.html — so a single run renders anywhere it is copied to, with
no server. What it cannot do alone is offer the OTHER runs: the
selector reads `runs.json` and `runs/<stamp>.json`, both fetched
relative to the page's own URL.

This writes that pair, and it is used from two places that previously
had their own copies of the idea:

  perfserve.sh   runs-root /var/tmp/rocm-perf  ->  out .current
  make perf-publish  runs-root and out both the gh-pages data/perf dir

Hence --live: perfserve is watching a run that is still being written
and the page should keep polling; a published site is frozen and
polling it forever would hammer GitHub Pages for bytes that never
change. The flag lands in runs.json and the page decides from it.

Usage:
  perfsite.py <runs-root> <out-dir> [--live]
"""
import json
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path


def label(name, meta):
    """"30 Oct 05:12 · gfx1201 · cold" — enough to tell runs apart.

    The stamp alone is not: a day of runs differs in four characters
    buried mid-string, and the arch and mode are what someone is
    actually choosing between.
    """
    try:
        when = datetime.strptime(name, "%Y%m%dT%H%M%SZ")
        shown = (when.replace(tzinfo=timezone.utc).astimezone()
                 .strftime("%d %b %H:%M"))
    except ValueError:
        shown = name
    extra = [b for b in (meta.get("arch"), meta.get("mode")) if b]
    return " · ".join([shown] + extra)


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    root, out = Path(argv[0]), Path(argv[1])
    live = "--live" in argv[2:]
    if not root.is_dir():
        print(f"perfsite: no such directory: {root}", file=sys.stderr)
        return 2

    (out / "runs").mkdir(parents=True, exist_ok=True)

    runs = []
    for d in sorted((p for p in root.glob("2*/") if p.is_dir()),
                    key=lambda p: p.name, reverse=True):
        data = d / "data.json"
        if not data.is_file():
            continue        # never rendered, or still starting up
        try:
            meta = json.loads((d / "run.json").read_text())
        except Exception:
            meta = {}
        dest = out / "runs" / (d.name + ".json")
        # A finished run's data never changes, so copy it once. The
        # newest is still being written when --live, so refresh it.
        newest = not runs
        if (live and newest) or not dest.exists() \
                or dest.stat().st_mtime < data.stat().st_mtime:
            tmp = dest.with_name(dest.name + ".tmp")
            shutil.copyfile(data, tmp)
            tmp.replace(dest)
        runs.append({"stamp": d.name, "label": label(d.name, meta),
                     "arch": meta.get("arch"), "mode": meta.get("mode"),
                     # Only the newest can be in flight, and only when a
                     # server is watching it.
                     "live": bool(live and newest)})

    if not runs:
        print(f"perfsite: no rendered runs under {root}", file=sys.stderr)
        return 1

    # The landing page is the newest run's, so the directory root opens
    # on something useful rather than an index of files. Copied, not
    # symlinked: this tree gets committed to gh-pages.
    newest_dir = root / runs[0]["stamp"]
    for name in ("index.html", "data.json"):
        src = newest_dir / name
        if src.is_file() and src.resolve() != (out / name).resolve():
            tmp = out / (name + ".tmp")
            shutil.copyfile(src, tmp)
            tmp.replace(out / name)

    tmp = out / "runs.json.tmp"
    tmp.write_text(json.dumps(runs))
    tmp.replace(out / "runs.json")
    print(f"perfsite: {len(runs)} run(s) -> {out}"
          f"{' (newest live)' if live else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
