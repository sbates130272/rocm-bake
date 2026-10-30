# Build performance

Two harnesses, answering different questions.

**This page** is `bench.sh`: one target at a time, four cache
conditions, an isolated compiler cache. It answers *what does this
target cost*, and its numbers are comparable run to run.

**[Instrumented fleet runs](perf-runs.md)** is `make perf-run`: every
wheel at once, across all three nodes, with CPU, cache and registry
traffic sampled throughout. It answers *what does a full cold build
look like*, and its numbers are throughput under contention.

Do not quote a number from one as if it came from the other.

## The four cache conditions

Measured rather than estimated. They nest: each one is the one below it
with a further cache taken away.

```mermaid
flowchart LR
    frozen["<b>frozen</b><br/>nothing, anywhere"] --> cold["<b>cold</b><br/>base image local"]
    cold --> warm["<b>warm</b><br/>caches populated,<br/>new commit"]
    warm --> hot["<b>hot</b><br/>same commit,<br/>everything cached"]
```

## The scenarios

### frozen

Cold, **and** Zot holds no pull-through copy of the upstream base image
either, so its layers egress from Docker Hub.

What a brand-new site costs, before any of this fleet's infrastructure
has warmed up. The ROCm base is a single 8.67 GB layer, so the
difference between frozen and cold is essentially WAN bandwidth — and it
is the number to quote when someone asks what the local registry is
worth.

```bash
make bench BENCH_SCENARIO=frozen BUILDER=snoc-think
```

!!! warning "frozen is destructive and is not in the nightly rotation"
    It deletes Zot's cached manifest for the upstream base, and it runs
    `docker buildx prune -af` on the target node — which empties that
    node's BuildKit content store, including any other project's
    layers. These builders are shared. `BENCH_FROZEN_PRUNE=0` skips the
    prune, at the cost of only re-pulling whatever BuildKit happened to
    drop.

    If Zot refuses the delete, the run is recorded with
    `registry_evicted: "partial"` and shown as `frozen*`. It is a cold
    run wearing a frozen label, and it is excluded from every published
    ratio rather than averaged in — counting it would quietly drive the
    registry's apparent value towards nothing.

### cold

No layer cache, no compiler cache, but the base image is resident in
Zot. What a new build node, or a changed base image, costs. The upper
bound on compile cost.

`--no-cache` alone is **not** cold: sccache would still serve every
object from the shared store and the build would finish in minutes while
measuring nothing. The harness also sets `FORCE_RECACHE` and isolates
the run under its own `SCCACHE_WEBDAV_KEY_PREFIX`.

```bash
make bench BENCH_SCENARIO=cold
make cold-build COLD_TARGET=pytorch   # the same conditions, outside the harness
```

### warm

Layer and compiler caches are populated, but `SOURCE_DATE_EPOCH` moved —
which is what every new commit does, including commits that touch
nothing the image depends on. The case that matters day to day.

Under the current design that costs nothing, and **the result is the
assertion rather than the number**: warm builds exactly what hot builds,
so if warm ever diverges from hot, some per-commit value has found its
way back into an image digest. That has happened twice — once when the
epoch came from HEAD's timestamp, and once when a squash collapsed the
per-image timestamps. See
[Reproducibility](../architecture/reproducibility.md).

### hot

Same commit, everything cached. The lower bound, and mostly a check that
the caches are being read at all.

Note that the harness distinguishes two kinds of hot run when it
computes ratios: one where the compile step ran and sccache served every
object, and one where BuildKit skipped the step outright. They answer
different questions and are reported separately.

## Measured results

<p id="bench-generated"></p>

<div class="bench-chart" markdown="0">
  <canvas id="bench-bars"></canvas>
</div>

<div id="bench-summary"></div>

Medians, keyed by target, builder, **architecture** and job count. Both
architecture and job count are in the key because both are dominant
variables rather than nuisance ones: the same cold PyTorch is 6892 s at
5 jobs and 2342 s at 32, and vLLM's kernel prebuild is about 50 minutes
on `gfx950` against hours on `gfx1201` — AITER drops to
`PREBUILD_KERNELS=0` on RDNA entirely. Cold on one architecture over hot
on another is not a ratio. See [Methodology](methodology.md).

`PYTORCH_ROCM_ARCH=gfx1201 make bench BENCH_SCENARIO=cold` measures that
architecture; the harness resolves the value through make, so it is
always the one a real build would have used.

### Every run

<div class="bench-chart" markdown="0">
  <canvas id="bench-history"></canvas>
</div>

Each point is one build. The spread is real and large — PyTorch's hot
time varies about threefold run to run — which is why the tables above
quote medians and print `n` beside them.

## Reproducing this

```bash
make bench BENCH_SCENARIO=cold BUILDER=snoc-think   # one scenario
make bench BENCH_SCENARIO=all                       # cold, warm, hot
make bench BENCH_SCENARIO=everything                # and frozen first
make bench-report                                   # render as markdown
```

The harness refuses to run while a real build is in flight on the target
builder: two builds on one node contend for cores and memory, and every
timing would be meaningless. It exits 0 in that case rather than
failing, so it is safe to drive from cron.

Results accumulate as JSON lines in `/var/tmp/rocm-bench/results.jsonl`,
one per build, so a partial run is still usable and successive nights
add to the record rather than overwriting it.

## Publishing

The numbers on this page come from a file on the `gh-pages` branch, not
from the repository. Nothing in `main` carries benchmark data.

```bash
make bench-data              # aggregate into dist/bench/bench.json
make bench-publish           # commit it onto gh-pages
make bench-publish PUSH=1    # and push
```

This runs from a build node because that is the only place the data
exists — a GitHub-hosted runner can neither reproduce the builds nor
read the results. The docs workflow preserves `data/` when it deploys
the site, so the two writers do not clobber each other.
