# Live Reports

Two lanes publish measurements continuously, to two pages on the
`gh-pages` branch. Neither is committed to `main` — the data only
exists where it was produced.

<div class="grid cards" markdown>

-   __[Fleet Runs — data/perf/](https://sbates130272.github.io/rocm-bake/data/perf/)__

    Every wheel built across all three SNOC nodes at once, with CPU,
    memory, compiler-cache and registry traffic sampled throughout.
    Opens on the newest run, with a selector for every earlier one.

    Driven by hand with `make perf-cold` or `make perf-warm`, published
    with `make perf-publish PUSH=1` from a build node.
    [How it works](performance/perf-runs.md).

-   __[Nightly Builds — data/nightly/](https://sbates130272.github.io/rocm-bake/data/nightly/)__

    One warm bake per architecture on a rented AWS CodeBuild machine,
    02:17 UTC, published to ECR. Phase wall clock and cache-error
    counts, every run kept. A table, not a chart — see below.

    Fully automated, and it files a comment on one `nightly`-labelled
    issue as well. [How it works](operations/runners.md#the-nightly),
    [what it costs](operations/aws.md).

</div>

!!! danger "The two are not comparable"
    A fleet run is a parallel build across three nodes sharing a
    compiler cache. A nightly is sequential bakes on one rented
    machine, and its phase wall clock is the whole bake rather than a
    per-target cost. Quoting one as the other is the mistake both pages
    open by warning about.

    A third set of numbers — isolated per-target costs under four cache
    conditions — lives on [Performance](performance/index.md), and is
    not comparable with either.

## Browsing Older Runs

Both pages keep everything ever published, and both open on the newest
run — but they are not the same page, and only one of them charts.

**`data/perf/` is the interactive chart.** `perfsite.py` writes a
`runs.json` and a `runs/<stamp>.json` beside it, which the page fetches
relative to its own URL to populate a selector; every run also keeps a
`data/perf/<stamp>/` permalink. Pick any past run from the dropdown and
you get its full chart — overlaid CPU and memory, a legend that filters
by builder and target, per-band hover.

**`data/nightly/` is a table.** `nightlysite.py` writes a row per run
and architecture — cold, warm, cache errors — with a
`data/nightly/<stamp>/` permalink and its own `runs.json`. No chart, no
legend, no per-target spans.

!!! note "The chart does not cover the AWS runs, and cannot"
    Not an oversight. `nightly.sh` writes two files, `report.md` and
    `summary.json`, because a rented CodeBuild machine has none of what
    the chart is drawn from: there is no node_exporter on three nodes
    to sample into `samples.jsonl`, no per-target `trace-<target>.json`,
    and no Zot or nginx log to slice. A nightly times bake invocations
    and claims nothing it cannot see.

    `nightlysite.py` is deliberately a separate index for the same
    reason the admonition above gives. Merging the two selectors would
    put a parallel three-node run and a sequential one-machine run in
    the same dropdown, which is the not-comparable mistake made
    structural.

## Watching A Run Live

For fleet runs, the published page is not a different tool from the
local one — `perf-publish` puts the chart `perf-serve` renders onto
`gh-pages` and adds the cross-run selector. So the same interface works
on a run that is still going:

```bash
make perf-serve             # newest run, http://<host>:8090
make perf-serve-status      # whether one is up, and where
make perf-serve-stop        # stop it, free PERF_PORT
```

It regenerates every 30 s and re-resolves which run is newest each
cycle, so it picks up a run that starts after the server did. The page
polls `data.json` rather than reloading, because the legend *is* the
filter — a reload would discard whichever builders and targets you had
narrowed to. A published run is frozen and stops polling.

!!! warning "`perf-serve` binds every interface"
    `0.0.0.0` by default, because the usual viewer is a laptop on the
    LAN rather than on the tailnet. What that exposes is build
    telemetry — hostnames, CPU and memory figures, build step names —
    with no credentials and no registry access. Narrow it with
    `PERF_BIND=<ip>`, and `make perf-serve-stop` when you are done.

## What Each Publishes

| | Fleet runs | Nightly |
| --- | --- | --- |
| Where | `data/perf/<stamp>/` | `data/nightly/<stamp>/<arch>/` |
| Who runs it | an operator, on demand | `schedule:`, nightly |
| Machines | three, in parallel | one, sequential |
| Caches | both live (warm) or neither (cold) | registry + sccache on S3 |
| Reports | per-target spans, CPU/cache/registry traffic | phase wall clock, cache errors |
| Harness | `.builders/perfrun.sh` | `.builders/nightly.sh` |
| Index | `perfsite.py` — selector over every run | `nightlysite.py` — one table of every run |
| Older runs | dropdown, plus `<stamp>/` permalinks | table rows, plus `<stamp>/` permalinks |
| Charted | yes — CPU, memory, per-target spans | no |
| Live view | `make perf-serve` | — |

The nightly skips itself when `main` has not moved since the last
successful scheduled run, so a gap in the table is usually a quiet week
rather than a failure.
