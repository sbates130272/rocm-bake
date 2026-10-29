#!/usr/bin/env python3
"""builder-health.py - report whether each buildx builder can take work.

BuildKit already tracks this, so nothing here invents a health check:
`docker buildx ls` probes every node and reports running / inactive /
error per node. This only aggregates that to the builder level and makes
it available to the Makefile and the balancer, which until now picked
nodes purely on cores, load and free memory — all of which look fine on
a node whose buildkitd is wedged. snoc-gaming has sat in `error` while
scoring well on all three.

A builder is:
  running   at least one node is up and can accept a build
  error     nodes answered, and none is usable — buildkitd is down,
            the container is gone, or the ssh endpoint is refusing
  inactive  the builder exists but its container has never started;
            a build against it would bootstrap it first
  missing   not registered with buildx at all

`docker buildx ls --format '{{json .}}'` would be the obvious way to
read this. It hangs on buildx 0.30.1 (the Ubuntu package), so this
parses the table instead:

    NAME/NODE          DRIVER/ENDPOINT                 STATUS   ...
    snoc-strix*        docker-container
     \\_ snoc-strix0     \\_ unix:///var/run/docker.sock  running  ...

Builder rows start in column 0; node rows are indented and carry the
status. The trailing "*" marks the default builder and is not part of
the name.

Usage:
  ./builder-health.py                 table of every snoc-* builder
  ./builder-health.py --all           every builder, not just snoc-*
  ./builder-health.py --status NAME   print one status word
  ./builder-health.py --check NAME    exit 0 if it can take work
  ./builder-health.py --list          builder names, one line, for make
  ./builder-health.py --refresh       probe now and update the cache
  ./builder-health.py --cached-only   never probe; use whatever is cached

--cached-only exists for `make watch`, which repaints every few seconds
and must never block. A probe costs as long as the slowest dead node
takes to time out — 20s here with one node down — so watch warms the
cache once up front and then reads it, accepting that a status can be a
minute stale. Staleness is the right trade for a display: the number it
shows was true a moment ago, rather than the display freezing.
"""

import json
import os
import re
import subprocess
import sys
import time

# `docker buildx ls` contacts every endpoint, so it costs whatever the
# slowest one costs — and the node most worth knowing about is the
# broken one, whose ssh connect has to time out before buildx can call
# it `error`. Measured over 20s here with snoc-gaming down.
TIMEOUT = 45

# Which makes it far too slow to call from `watch` on a 5s refresh, so
# the result is cached, the same way builder-load already caches per-node
# load in /tmp/.rocm-load. Health changes on the scale of a daemon
# restart, not a build step, so a minute of staleness costs nothing and
# a stale-but-instant answer beats a 20s stall in every caller.
CACHE = "/tmp/.rocm-builder-health.json"
MAX_AGE = 60

COLOUR = {
    "running": "\033[32m",
    "error": "\033[31m",
    "inactive": "\033[33m",
    "missing": "\033[31m",
}
RESET = "\033[0m"


def builder_table(max_age=MAX_AGE):
    """{builder: [(node, status), ...]}, from the cache when it is fresh.

    A failed or timed-out probe returns the stale cache rather than {}:
    "I could not ask just now" and "there are no builders" are different
    answers, and treating the first as the second would have callers
    refuse to build on a node that is perfectly fine.
    """
    cached, cached_age = None, None
    try:
        cached_age = time.time() - os.path.getmtime(CACHE)
        with open(CACHE) as fh:
            cached = json.load(fh)
    except Exception:
        pass
    if cached is not None and cached_age is not None and cached_age < max_age:
        return {k: [tuple(n) for n in v] for k, v in cached.items()}

    # --cached-only passes max_age=inf and means it: with no cache at
    # all, report nothing rather than probing. A caller that asked not
    # to block must not be made to block by a missing file.
    if max_age == float("inf"):
        return {}

    try:
        out = subprocess.run(
            ["docker", "buildx", "ls"],
            capture_output=True, text=True, timeout=TIMEOUT,
        ).stdout
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return {k: [tuple(n) for n in v] for k, v in (cached or {}).items()}

    builders, current = {}, None
    for line in out.splitlines()[1:]:          # skip the header
        if not line.strip():
            continue
        if not line[0].isspace():
            current = line.split()[0].rstrip("*")
            builders[current] = []
            continue
        if current is None:
            continue
        # " \_ snoc-strix0     \_ unix://...   running   v0.33.1  ..."
        fields = re.sub(r"\\_", " ", line).split()
        if not fields:
            continue
        node = fields[0]
        status = next(
            (f for f in fields if f in ("running", "inactive", "error")),
            "unknown",
        )
        builders[current].append((node, status))

    # Written via a temporary file so a `watch` reading it concurrently
    # never sees a half-written one.
    try:
        tmp = f"{CACHE}.{os.getpid()}"
        with open(tmp, "w") as fh:
            json.dump(builders, fh)
        os.replace(tmp, CACHE)
    except OSError:
        pass
    return builders


def status_of(builder, table=None):
    """One word for the whole builder, worst-case-but-usable."""
    table = builder_table() if table is None else table
    # An empty table is "I could not look", not "there are no builders".
    # Saying `missing` there would paint every builder red in watch the
    # moment a probe failed.
    if not table:
        return "unknown"
    if builder not in table:
        return "missing"
    nodes = table[builder]
    if not nodes:
        return "inactive"
    states = [s for _, s in nodes]
    if "running" in states:
        return "running"
    if "error" in states:
        return "error"
    if "inactive" in states:
        return "inactive"
    return "unknown"


def healthy(builder, table=None):
    """Can a build be sent here right now?

    `inactive` counts as healthy: buildx bootstraps the container on
    first use, which is normal for a builder nobody has used since the
    daemon restarted. `error` does not — that is a node that answered
    and said no.
    """
    return status_of(builder, table) in ("running", "inactive")


def main():
    args = sys.argv[1:]

    # --cached-only pins max_age to infinity, so builder_table returns
    # the cache whatever its age and never shells out.
    max_age = float("inf") if "--cached-only" in args else MAX_AGE
    if "--refresh" in args:
        max_age = 0

    if "--list" in args:
        table = builder_table(max_age)
        names = sorted(table)
        if "--all" not in args:
            names = [n for n in names if n.startswith("snoc-")]
        print(" ".join(names))
        return 0

    if "--status" in args:
        print(status_of(args[args.index("--status") + 1],
                        builder_table(max_age)))
        return 0

    if "--check" in args:
        name = args[args.index("--check") + 1]
        state = status_of(name)
        if healthy(name):
            return 0
        print(f"builder '{name}' is {state}", file=sys.stderr)
        if state == "missing":
            print(f"  create it with: make builder-{name}", file=sys.stderr)
        elif state == "error":
            print(f"  its buildkitd is not answering; try: "
                  f"make builder-restart BUILDER={name}", file=sys.stderr)
        return 1

    table = builder_table(max_age)
    names = sorted(table)
    if "--all" not in args:
        names = [n for n in names if n.startswith("snoc-")]
    if not names:
        print("  no builders registered")
        return 0

    for name in names:
        state = status_of(name, table)
        colour = COLOUR.get(state, "")
        nodes = ", ".join(f"{n}:{s}" for n, s in table[name]) or "no nodes"
        print(f"  {name:<16} {colour}{state:<9}{RESET} \033[2m{nodes}{RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
