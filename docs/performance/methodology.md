# Methodology

`.builders/bench.sh` is the harness. It runs one `make build-*` per
measurement, parses the build log, and appends a JSON line. Everything
below is a correction to something that produced a wrong number first.

## What A Run Records

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
  "max_jobs": 10,
  "node_load_at_start": 0.4,
  "node_load_at_end": 12.0,
  "registry_evicted": null,
  "failure": null
}
```

A failing build is a result and the harness never aborts on one;
`failure` carries the first line that looks like a cause rather than the
generic wrapper. `log` is stripped before publication.

## Guards Before A Run

**Is the node busy?** The harness asks buildx what the *builder* is
solving, not the process table — `pgrep -f` matched the script's own
invoker, and was fleet-wide besides.

**Has memory settled?** `MAX_JOBS` is derived from `MemAvailable` when
the compile step starts. Launching straight after another benchmark
samples it while BuildKit is still flushing layers: one cold PyTorch
derived `MAX_JOBS=3` on a node that reported 18 GB free two minutes
later. The harness polls until two readings agree.

That is necessary but not sufficient, because the build's own earlier
steps have taken memory by then — a cold PyTorch that settled at 21 GB
derived 5, where the same node gives a hot run 10. So cold and hot are
measured at different job counts **by construction**. `BENCH_MAX_JOBS`
pins it when the point is to compare scenarios.

## Parsing The Log

Two numbers come out of the build log, and both were wrong at first.

### Steps Cached

A step is a vertex BuildKit labels `[n/m]`, and cached means that vertex
reported `CACHED` — not the telemetry wrapper's count, which includes
loading the Dockerfile, metadata and exporting among the total, none of
which can ever be cached.

The vertex name carries a bake-target prefix whenever the build has more
than one target, and `pytorch` always does now: `[pytorch builder 4/11]`
against a single-target build's bare `[builder 9/11]`. An earlier regex
allowed only the bare form, so a PyTorch benchmark counted zero of zero.

### sccache Counters

Not from `^Cache hits` — the lines carry a BuildKit prefix
(`#32 178.7 Cache hits 5674`), so that anchor never matched. And not
from the telemetry summary, the first fix and also wrong: a PyTorch
build prints two stats blocks, its own and Triton's, and the wrapper
attributed Triton's to both.

BuildKit carries the association in the step number: `#32 [pytorch
builder 10/11] RUN …` ties step 32 to `pytorch`, and every stats line
from that step is prefixed `#32 `.

## Isolation

frozen and cold runs set `SCCACHE_WEBDAV_KEY_PREFIX` to a per-run value
and delete it afterwards, so they never pollute the shared cache.

`cache-to` is cleared for every run: the credential helper fails outside
an interactive session. Reads are anonymous and still work, so cache
*hits* are faithful; what these numbers exclude is push time.

## Forcing A Recompile

`BENCH_FORCE_COMPILE=1` writes an HCL override setting `no-cache-filter
= ["builder"]`. It must arrive as an override file: bake accepts the
attribute there, but `--set target.no-cache-filter=` is silently dropped
(buildx 0.30.1). The older method — bumping `MAX_JOBS` to a value it had
not had — conflated the cache-buster with the variable under test.

It invalidates every step in the stage, not just the compile. Whether
that changes the *timing* is **not established**: the pin-change method
spans 203–617 s and contains the forced range entirely.

## How The Ratios Are Computed

Three pools, keyed by `(target, builder, arch, max_jobs)`:

| Pool | Which Rows |
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
compiled nothing. Whether the compile ran is judged on steps cached, not
on sccache having reported anything: rows from before the parser was
fixed carry `requests=0` because nothing was recorded.

### Which Sample

The markdown report quotes the **most recent** run at a key. The minimum
picks an outlier and biases the ratio in opposite directions on each
side; the median assumes one population, and this pipeline changed
underneath its own measurements. A ratio answers what the cache buys
*now*, so the newest sample is the right estimator, with `n` and the
observed range beside it. The **charts** use medians, because a chart
shows a distribution over time.

## Why Job Count And Architecture Are In The Key

Both are dominant parameters, not nuisance ones. The same cold PyTorch
is 6892 s at 5 jobs and 2342 s at 32, and vLLM's kernel prebuild is
about 50 minutes on `gfx950` against hours on `gfx1201`. Pooling across
either coordinate produces an average of nothing.

The harness resolves the architecture through make rather than a
literal. Rows from before the field existed read as `gfx950`. A ratio is
printed only when both sides were measured at the same width and
architecture.

## Contamination

The builders are shared with another project. Load average is recorded
at the start **and** the end, because one sample at *t*=0 does not
characterise a twenty-minute run: the slowest cold Triton on record,
1168 s against a 432–669 s cluster, *began* at load 0.99 and finished
with the node at 41 on 32 cores. Contention arriving after the start is
the best candidate for the spread these numbers carry.
