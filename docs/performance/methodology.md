# Methodology

`.builders/bench.sh` is the harness. It runs one `make build-*` per
measurement, parses the build log, and appends a JSON line. Everything
below is a correction to something that produced a wrong number first.

## What a run records

```json
{
  "ts": "2026-10-20T02:00:00+00:00",
  "scenario": "cold",
  "target": "pytorch",
  "builder": "snoc-think",
  "arch": "gfx950",
  "seconds": 2342,
  "rc": 0,
  "steps_cached": 0,
  "steps_total": 11,
  "sccache_requests": 5674,
  "sccache_hits": 0,
  "sccache_misses": 5674,
  "max_jobs": 10,
  "node_load_at_start": 0.4,
  "node_load_at_end": 12.0,
  "registry_evicted": null,
  "failure": null,
  "log": "/var/tmp/rocm-bench/logs/cold-pytorch-…​.log"
}
```

A failing build is a result, and recording it is the point — the harness
never aborts on one. `failure` carries the first line that looks like a
cause rather than the generic wrapper.

`log` is stripped before publication, along with nothing else: the
`json` mode emits every other field.

## Guards before a run

**Is the node busy?** The harness asks buildx what the *builder* is
actually solving, not the process table. `pgrep -f` matches a pattern
anywhere in a command line — including the command line of whatever
invoked the script, and of the check's own subshell — so an earlier
version reported busy against itself. It was also fleet-wide: a build on
any node blocked a benchmark on an idle one, and these builders are
shared with another project.

**Has memory settled?** `MAX_JOBS` is derived inside the build from
`MemAvailable`, sampled once when the compile step starts and fixed for
the whole build. Launching a benchmark straight after another one
samples it while BuildKit is still flushing the previous build's layers:
a cold PyTorch started that way derived `MAX_JOBS=3` on a 30 GB node
that reported 18 GB free two minutes later. Across slots that node has
produced 3, 4, 7 and 10 — mostly scheduling artefact, not node. The
harness polls until two consecutive readings agree, which keeps the
derivation (the thing being exercised) while removing the artefact.

Settling is necessary but not sufficient. The derivation happens when
the *compile* step starts, by which point the build's own earlier steps
— fetching the base image, the checkout, aotriton — have taken memory of
their own. A cold PyTorch that settled at 21 GB still derived 5, where
the same node gives a hot run 10. So cold and hot are measured at
different job counts **by construction**.

`BENCH_MAX_JOBS` pins it when the point is to compare scenarios. Leave
it unset when the point is to exercise the derivation itself.

## Parsing the log

Two numbers come out of the build log, and both were wrong at first in
instructive ways.

### Steps cached

A step here is a vertex BuildKit labels `[n/m]`, and cached means that
same vertex reported `CACHED`. Not the telemetry wrapper's count: that
counts loading the Dockerfile, the dockerignore, metadata and exporting
among the total — none of which can ever be cached — so a fully-cached
base build reports `5/12` while every one of its five actual steps was
`CACHED`.

The vertex name carries a bake-target prefix whenever the build has more
than one target, and `pytorch` always does now because it pulls
`triton-wheel` in as a named context. BuildKit emits
`[pytorch builder 4/11]` and `[triton-wheel builder 9/11]` where a
single-target build emits a bare `[builder 9/11]`. An earlier regex
allowed only the bare form, so a PyTorch benchmark counted zero steps
out of zero.

### sccache counters

Not from `^Cache hits`: the lines carry a BuildKit prefix
(`#32 178.7 Cache hits 5674`), so that anchor never matched and every
run recorded 0 hits.

And not from the telemetry summary either, which was the first fix and
was also wrong. A PyTorch build prints two stats blocks, its own and
Triton's, and the wrapper attributed Triton's numbers to both images: a
run whose PyTorch compile reported 5674 hits was summarised as 361
hits, which is Triton's figure.

BuildKit does carry the association, in the step number. The vertex
header `#32 [pytorch builder 10/11] RUN …` ties step 32 to `pytorch`,
and every stats line from that step is prefixed `#32 `. Mapping headers
to targets and then selecting that target's steps is exact, with no
heuristic about ordering or magnitude.

## Isolation

frozen and cold runs set `SCCACHE_WEBDAV_KEY_PREFIX` to a per-run value,
so they never pollute or evict the fleet's shared compiler cache. The
prefix is a directory in the WebDAV store and is deleted immediately
after the run — a cold run writes the whole compile output and these add
up fast.

`cache-to` is cleared for every benchmark run. The Docker credential
helper on this host fails with `gpg: public key decryption failed`
outside an interactive session, so registry writes are impossible
unattended. Reads are anonymous and still work, so cache *hits* are
measured faithfully; what these numbers exclude is push time, which is
not what is being timed.

## Forcing a recompile

Until recently the only way to make a hot build actually compile was to
give `MAX_JOBS` a value it had not had before, since changing a build
arg changes the layer key. That conflated the cache-buster with the
variable under test: each job count was usable exactly once per tree
state.

`BENCH_FORCE_COMPILE=1` instead writes an HCL override setting
`no-cache-filter = ["builder"]`, which asks BuildKit to ignore cache for
one stage and nothing else, so the same width can be measured
repeatedly. It has to arrive as an override file — bake accepts the
attribute there, but `--set target.no-cache-filter=` is silently dropped
(tested on buildx 0.30.1; it does not appear in `--print`).

Note it invalidates every step in the stage, not just the compile: the
git clone, the sccache download and the pip installs all re-run.

Whether it changes the *timing* enough to matter is not established. It
looked that way from two samples — 403 s and 429 s against a 267 s
pin-change run — but with every converged run counted, the pin-change
method spans 203–617 s and contains the forced range entirely. PyTorch's
hot time varies about threefold run to run whatever forces the compile,
and that swamps any method effect this data could show. Treat the two as
interchangeable until something separates them.

## How the ratios are computed

Three pools, keyed by `(target, builder, arch, max_jobs)`:

| Pool | Which rows |
| --- | --- |
| frozen | `scenario == "frozen"` **and** the registry eviction succeeded |
| cold | `scenario == "cold"` |
| compiled | `scenario == "hot"` where under half the steps were cached |
| skipped | `scenario == "hot"` where at least half were cached |

and three ratios:

- **registry** — frozen ÷ cold. What Zot's pull-through is worth.
- **compiler cache** — cold ÷ compiled. sccache served the requests
  instead of the compiler.
- **layer cache** — compiled ÷ skipped. BuildKit skipped the compile
  step outright, so sccache saw no requests at all.

Dividing cold by whichever hot run came last conflated the last two and
once printed "2297.3x" — a cold run against a 3 s layer-cache hit that
compiled nothing.

Whether the compile ran is judged on steps cached rather than on sccache
having reported anything. Rows written before the sccache parser was
fixed carry `requests=0` because nothing was recorded, not because
nothing was compiled; two Triton rows at 529 s and 218 s have
`requests=0` and steps `0/3`, so they plainly compiled, and counting
them as layer-cache hits produced "layer cache a further 0x".

### Which sample

The markdown report quotes the **most recent** run at a key, not the
best and not the median. Each of the others was tried and each is wrong
here.

The minimum picks an outlier, and picking it on both sides biases the
ratio in opposite directions: cold runs vary far more than hot ones, so
`min(cold)` picks a sample that shrinks the ratio while `min(hot)` picks
one that inflates it.

The median assumes the samples are drawn from one population, and they
are not — this pipeline changed underneath its own measurements. The
compiler cache converged partway through, and rows written before the
sccache parser was fixed record no hit data at all. Averaging a run from
before a fix with one from after describes a system that never existed.

The question a ratio answers is what the cache buys *now*, so the newest
sample is the right estimator, and `n` with the observed range is
printed beside it so the spread stays visible.

The **charts** on the [results page](index.md) use medians instead, and
deliberately. A chart is showing a distribution over time; there the
newest point belongs in the series, not in the summary.

## Why job count and architecture are in the key

Both are dominant parameters, not nuisance ones.

The same cold PyTorch is 6892 s at 5 jobs and 2342 s at 32. An earlier
version pooled runs across widths and reported "pytorch hot, n=12,
244–1366s", which spans pins 5 to 15 plus runs taken before the compiler
cache had converged. No average over that means anything.

Architecture is the same mistake in a different coordinate. vLLM's
kernel prebuild is about 50 minutes on `gfx950` and hours on `gfx1201`,
and AITER drops to `PREBUILD_KERNELS=0` on RDNA entirely — so cold on one
architecture divided by hot on another is not a ratio either.

The harness resolves the architecture through make rather than
defaulting to a literal, so it is exactly what a real build would use
and `gfx950` is not duplicated out of `rocm-bake.hcl`. Rows written
before the field existed are read as `gfx950`: the harness never set
`PYTORCH_ROCM_ARCH` then, so they used the bake default, which has been
`gfx950` since before the oldest result on file.

A ratio is printed only when cold and hot were measured at the same
width and architecture. Anything measured at one only is still shown,
just not as a ratio.

## Contamination

The builders are shared with another project, and a concurrent build
skewed the first timings taken here. The node's one-minute load average
is recorded at the start **and** at the end, because one sample at
*t*=0 does not characterise a run lasting ten to twenty minutes: the
slowest cold Triton on record, 1168 s against a 432–669 s cluster,
*began* at load 0.99 — the lowest of its group — and the node's
fifteen-minute average reached 41 on 32 cores by the time it finished.
Contention arriving after the start was invisible, and it is the best
candidate for the spread these numbers carry.
