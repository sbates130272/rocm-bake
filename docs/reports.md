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
    counts per run.

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

## What Each Publishes

| | Fleet runs | Nightly |
| --- | --- | --- |
| Where | `data/perf/<stamp>/` | `data/nightly/<stamp>/<arch>/` |
| Who runs it | an operator, on demand | `schedule:`, nightly |
| Machines | three, in parallel | one, sequential |
| Caches | both live (warm) or neither (cold) | registry + sccache on S3 |
| Reports | per-target spans, CPU/cache/registry traffic | phase wall clock, cache errors |
| Harness | `.builders/perfrun.sh` | `.builders/nightly.sh` |

The nightly skips itself when `main` has not moved since the last
successful scheduled run, so a gap in the table is usually a quiet week
rather than a failure.
