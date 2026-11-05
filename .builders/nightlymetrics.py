#!/usr/bin/env python3
"""Pull the numbers a nightly phase log already contains but never reported.

Usage:  nightlymetrics.py <phase.log> [...]

Emits one JSON object on stdout, merging every log given. nightly.sh folds it
into summary.json; nightlysite.py renders it.

Four things, all of which were sitting in warm.log unread:

  sccache         hits, misses and requests, summed across every target that
                  ran a compiler. The 2026-11-05 run was 87.8% (2902 of 3304
                  cacheable) and nothing surfaced it.

  layer cache     CACHED vs DONE BuildKit steps. That run had 0 CACHED
                  against 526 DONE -- a "warm" build that re-executed every
                  vertex -- and the report called it clean.

  import misses   `failed to configure registry cache importer` lines. These
                  are NOT errors: CACHE_TAG_SUFFIX scopes this lane's cache
                  away from the fleet's, so a tag that does not exist yet is
                  expected. They are counted separately precisely so they
                  stop being mistaken for either an error or a non-event --
                  38 of them is how 0 CACHED happens. (38 was also every
                  `#N ERROR` line in that log; the only other ERROR text is
                  pip's resolver notice, which is not a build error either.)

  per-target      vertex-seconds per bake target, for the build-time chart.
                  These are not wall clock: 525 steps summing to 17672s
                  finished in 2585s, because BuildKit runs targets in
                  parallel. The ratio is the useful part.

`nightly.sh` already counts cache *errors* with its own grep, and
deliberately keeps a narrow definition (write/push failures only). This does
not change that; it adds the things that definition was never meant to cover.
"""

from __future__ import annotations

import json
import re
import sys
from collections import Counter
from pathlib import Path

# "#123 [target stage 4/9] RUN ..." -- the vertex-to-target map. The label can
# be "[internal]" or "[auth]", which are not targets and are dropped.
VERTEX = re.compile(r"^#(\d+) \[([a-z0-9][a-z0-9 /-]*)\]")
DONE = re.compile(r"^#(\d+) DONE ([0-9.]+)s")
CACHED = re.compile(r"^#(\d+) CACHED")
IMPORT_MISS = re.compile(r"failed to configure registry cache importer")

# sccache --show-stats, as it appears once per compiling target:
#   #123 12.34 Compile requests                    2797
SCCACHE = re.compile(
    r"^#(\d+) [0-9.]+ (Compile requests|Compile requests executed"
    r"|Cache hits|Cache misses)\s+(\d+)\s*$"
)

NOT_A_TARGET = {"internal", "auth"}


def parse(paths: list[Path]) -> dict:
    vertex_target: dict[str, str] = {}
    seconds: Counter[str] = Counter()
    steps: Counter[str] = Counter()
    sccache_by_vertex: dict[str, dict[str, int]] = {}
    done = cached = import_misses = 0

    for path in paths:
        # errors="replace": a build log carries whatever a compiler printed,
        # and one invalid byte should not lose the whole run's metrics.
        with open(path, errors="replace") as fh:
            for line in fh:
                m = VERTEX.match(line)
                if m:
                    target = m.group(2).split()[0]
                    if target not in NOT_A_TARGET:
                        vertex_target.setdefault(m.group(1), target)

                m = DONE.match(line)
                if m:
                    done += 1
                    target = vertex_target.get(m.group(1))
                    if target:
                        seconds[target] += float(m.group(2))
                        steps[target] += 1
                    continue

                if CACHED.match(line):
                    cached += 1
                    continue

                if IMPORT_MISS.search(line):
                    import_misses += 1
                    continue

                m = SCCACHE.match(line)
                if m:
                    sccache_by_vertex.setdefault(m.group(1), {})[m.group(2)] = int(
                        m.group(3)
                    )

    # Sum sccache across vertices. Keyed by vertex because each compiling
    # target prints its own block and they interleave in a parallel build.
    requests = executed = hits = misses = 0
    for stats in sccache_by_vertex.values():
        if "Compile requests" not in stats:
            continue
        requests += stats.get("Compile requests", 0)
        executed += stats.get("Compile requests executed", 0)
        hits += stats.get("Cache hits", 0)
        misses += stats.get("Cache misses", 0)

    cacheable = hits + misses
    return {
        "sccache": {
            "requests": requests,
            "executed": executed,
            "hits": hits,
            "misses": misses,
            # None rather than 0 when nothing compiled: a run with no
            # compiler calls has no hit rate, and 0.0 would read as a miss
            # storm on the chart.
            "hit_rate": round(100.0 * hits / cacheable, 1) if cacheable else None,
        },
        "layer_cache": {
            "done": done,
            "cached": cached,
            "import_misses": import_misses,
        },
        "targets": {
            t: {"seconds": round(seconds[t], 1), "steps": steps[t]}
            for t in sorted(seconds, key=lambda k: -seconds[k])
        },
        "vertex_seconds": round(sum(seconds.values()), 1),
    }


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    paths = [Path(a) for a in argv]
    missing = [p for p in paths if not p.is_file()]
    if missing:
        # Not fatal: --skip-cold means cold.log never exists, and the caller
        # passes both unconditionally.
        paths = [p for p in paths if p.is_file()]
    if not paths:
        print(json.dumps({}))
        return 0
    print(json.dumps(parse(paths), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
