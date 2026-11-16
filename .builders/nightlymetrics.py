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

# "#123 [target stage 4/9] RUN ..." -- the vertex header.
#
# VERTEX IDS ARE NOT UNIQUE ACROSS A BAKE. Each target in the group is its
# own build request and numbers its vertices from #1, so in a 15-target
# bake "#8" is fifteen different vertices. The 2026-11-14 log has 574 DONE
# lines across 210 distinct ids; "#8" alone is claimed by ten targets, all
# of them "[<target> internal] load .dockerignore".
#
# This used to read `vertex_target.setdefault(id, target)`, which gives an
# id to its first claimant for ever and credits every later target's work
# to it. The per-target table was wrong by 2-5x as a result: on 2026-11-13
# it reported rocm-runtime at 1628 vertex-seconds against ~313 when
# re-attributed, and pytorch-wheel at 2106 against ~921. Two analyses were
# built on those numbers and both reached a wrong conclusion -- including
# "the same stage is rebuilt once per target", which is not happening at
# all: rocm-runtime is a named context (`rocm-img = "target:rocm-runtime"`),
# built once and fed in.
#
# So ownership is reassigned on every header rather than fixed on the
# first, and a DONE is credited to whoever last claimed that id. That
# reconciles exactly -- summed per-target seconds equal vertex_seconds to
# the decimal, with no unowned DONE lines, on every log tested.
#
# It is still not provably exact: an id re-headed by another target while
# a long vertex of the same number is in flight would be misattributed.
# BuildKit re-prints the header before each chunk of a vertex's output, so
# that window is small, but it is not zero. Keying on the header label
# including its target prefix, as bench.sh does, is the stronger fix and
# needs the full label carried through the duration lines, which the plain
# progress format does not give us.
VERTEX = re.compile(r"^#(\d+) \[([a-z0-9][a-z0-9 ./-]*)\]\s*(.*)")
DONE = re.compile(r"^#(\d+) DONE ([0-9.]+)s")
CACHED = re.compile(r"^#(\d+) CACHED")
IMPORT_MISS = re.compile(r"failed to configure registry cache importer")

# sccache --show-stats, as it appears once per compiling target:
#   #123 12.34 Compile requests                    2797
SCCACHE = re.compile(
    r"^#(\d+) [0-9.]+ (Compile requests|Compile requests executed"
    r"|Cache hits|Cache misses)\s+(\d+)\s*$"
)

# A vertex is a real build step only if its label carries a "n/m" stage
# position. Everything else -- loading the dockerfile, the dockerignore,
# metadata, credentials, and the export -- can never report CACHED, so
# counting it in the denominator makes a healthy cache look broken.
# bench.sh:415-422 documents the same trap and avoids it the same way.
STEP_POS = re.compile(r"\b\d+/\d+$")

NOT_A_TARGET = {"internal", "auth"}


def parse(paths: list[Path]) -> dict:
    # id -> (target, is_build_step). Reassigned on every header; see the
    # note above VERTEX for why first-claimant ownership was wrong.
    owner: dict[str, tuple[str | None, bool, str]] = {}
    seconds: Counter[str] = Counter()
    steps: Counter[str] = Counter()
    cached_by_target: Counter[str] = Counter()
    sccache_by_vertex: dict[tuple[str, str | None], dict[str, int]] = {}
    done = cached = import_misses = 0
    step_labels: set[str] = set()
    cached_labels: set[str] = set()
    unattributed = 0.0

    for path in paths:
        # errors="replace": a build log carries whatever a compiler printed,
        # and one invalid byte should not lose the whole run's metrics.
        with open(path, errors="replace") as fh:
            for line in fh:
                m = VERTEX.match(line)
                if m:
                    label = m.group(2)
                    words = label.split()
                    head = words[0]
                    # "[internal] load metadata" in a single-target build has
                    # no target; "[pytorch-src internal] load .dockerignore"
                    # in a bake does, and the old NOT_A_TARGET check never
                    # fired on it because it only looked at the first word.
                    target = None if head in NOT_A_TARGET else head
                    is_step = (
                        target is not None
                        and not any(w in NOT_A_TARGET for w in words)
                        and bool(STEP_POS.search(label))
                    )
                    owner[m.group(1)] = (target, is_step, label)
                    continue

                m = DONE.match(line)
                if m:
                    done += 1
                    target, is_step, label = owner.get(
                        m.group(1), (None, False, "")
                    )
                    if target:
                        seconds[target] += float(m.group(2))
                        steps[target] += 1
                    else:
                        # A bare "[internal]" or "[auth]" label, which a
                        # single-target build emits and a bake rarely does.
                        # Held separately rather than dropped, so
                        # vertex_seconds keeps meaning "all vertex time" and
                        # stays comparable with the runs already in
                        # runs.json -- 1150s of the 2026-11-13 log, 8.6%.
                        unattributed += float(m.group(2))
                    if is_step:
                        # By LABEL, not by line. A vertex shared between
                        # build requests is re-reported once per requester,
                        # which would inflate the denominator the same way
                        # the old per-target split was inflated.
                        step_labels.add(label)
                    continue

                m = CACHED.match(line)
                if m:
                    cached += 1
                    target, is_step, label = owner.get(
                        m.group(1), (None, False, "")
                    )
                    if target:
                        cached_by_target[target] += 1
                    if is_step:
                        step_labels.add(label)
                        cached_labels.add(label)
                    continue

                if IMPORT_MISS.search(line):
                    import_misses += 1
                    continue

                m = SCCACHE.match(line)
                if m:
                    # Keyed by (id, current owner), not id alone. Five of the
                    # six stats-printing ids in the 2026-11-07 log were headed
                    # by more than one target -- #79 by five of them -- so a
                    # bare id would let one target's block overwrite another's
                    # and silently drop it from the totals.
                    key = (m.group(1), owner.get(m.group(1), (None, False, ""))[0])
                    sccache_by_vertex.setdefault(key, {})[m.group(2)] = int(
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
            # done/cached count every vertex, export and internal included.
            # Kept because four months of runs.json are expressed in them and
            # a redefinition would silently break the series.
            "done": done,
            "cached": cached,
            "import_misses": import_misses,
            # The pair that actually means something. Only vertices carrying
            # a "n/m" stage position can report CACHED at all, so this is
            # the real hit rate: on 2026-11-13 it was 59 of 318 build steps
            # (18.6%), where cached/done reads 59 of 617 (9.6%) because the
            # denominator is half things that can never be cached.
            "build_steps": len(step_labels),
            "build_steps_cached": len(cached_labels),
        },
        "targets": {
            t: {
                "seconds": round(seconds[t], 1),
                "steps": steps[t],
                "cached": cached_by_target[t],
            }
            for t in sorted(seconds, key=lambda k: -seconds[k])
        },
        # All vertex time, attributed or not, so the series in
        # runs.json stays comparable across this change.
        "vertex_seconds": round(sum(seconds.values()) + unattributed, 1),
        "unattributed_seconds": round(unattributed, 1),
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
