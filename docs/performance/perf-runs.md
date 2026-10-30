# Instrumented fleet runs

Every wheel built across the whole fleet at once, with CPU, memory,
compiler-cache and registry traffic sampled throughout, and a report
that explains where the time went.

## Three harnesses, three questions

| | `bench.sh` | `make perf-run` | `make perf-build` |
| --- | --- | --- | --- |
| runs targets | one at a time | across the fleet at once | across the fleet at once |
| caches | isolated | cold: none | both, as normal |
| answers | what does *this* target cost | what does a full cold build look like | what does a build I would actually run look like |
| numbers are | isolated per-target | throughput under contention | throughput under contention |

!!! danger "Do not quote a number from one as if it came from another"
    [`bench.sh`](index.md) serialises on purpose and isolates its
    compiler cache, so its per-target times are comparable run to run.
    The two `perf-*` harnesses run the fleet flat out, so three builds
    share the sccache store and the registry — both of which live on
    Strix, which is also a build node.

`perf-build` is the same instrumentation on an ordinary build: layer
cache and sccache both live, results pushed, the fleet's real sccache
prefix. It is the one to use when the question is about the build you
actually run rather than about a build from nothing — and the two
differ more than you would expect, because a warm build's cost is
almost entirely export rather than compute.

## Running one

```bash
make perf-plan                      # placement only, builds nothing
make perf-run PERF_ARCH=gfx1201     # cold: no caches, hours
make perf-build PERF_ARCH=gfx1201   # normal: caches on, pushes
make perf-report                    # markdown + SVG from the newest run
make perf-serve                     # live chart on :8090
make perf-runs                      # list collected runs
```

Cold here means `--no-cache` **and** an sccache prefix of its own — the
same isolation `bench.sh` uses. A cold run must not evict the fleet's
working cache, and it must not be allowed to hit it either.

!!! warning "`perf-serve` binds every interface"
    Not just the tailnet, because the usual viewer is a laptop on the
    LAN that is not on tailscale. What that exposes is build telemetry
    — hostnames, CPU and memory figures, build step names — with no
    credentials and no registry access. Narrow it with
    `PERF_BIND=<ip>`, and stop it when you are done.

    It regenerates every 30 s and re-resolves which run is newest each
    cycle, so it picks up a run that starts after the server did.

## What a run collects

Into `/var/tmp/rocm-perf/<stamp>/`, each from the cheapest source that
actually answers its question rather than from one general-purpose
collector:

| File | From | Answers |
| --- | --- | --- |
| `samples.jsonl` | node_exporter on all three nodes, polled | CPU, memory, disk and network over time |
| `trace-<target>.json` | the builder's own build record | what ran, when, for how long |
| `sccache.log` | the WebDAV vhost's nginx log, sliced to this run | what was written to the compiler cache, with sizes |
| `zot.jsonl` | Zot's structured log, sliced to this run | layer-cache and image writes, with sizes |
| `artifacts.txt` | `wheelhouse.py` | what ended up published |
| `index.html` + `data.json` | `perfreport.py` | the interactive chart, and the sidecar it polls |

`make perf-report` writes `report.md` with SVG charts beside it, plus
`index.html` for interrogating a run: overlaid CPU and memory lines, a
clickable legend that filters by builder *and* by target, and per-band
hover showing the actual `RUN` commands a phase covers.

CPU and memory share one axis because both are percentages. A second
y-scale would make it a dual-axis chart, which is the chart form that
misleads most reliably; memory is distinguished by dash instead, so
colour keeps following the builder.

`perf-serve` polls `data.json` rather than reloading, because the
legend *is* the filter: a reload would discard whichever builders and
targets the viewer had narrowed to, which is exactly the state someone
mid-question is in.

## `build` and `total` are different numbers

The per-target table carries both. `build` is the span of the target's
own steps; `total` is what the builder reported for the whole record.
The gap is setup plus export, and it is usually the larger of the two.

Transfers never widen the `build` column — that column exists to
exclude them. If the two disagree by minutes, the difference is the
export, and on a warm build it is nearly all of it.

### Cache export is not build time — in cold mode

`--no-push` suppresses the image push but **not** the cache export,
which is a separate registry write. In **cold** mode `perfrun.sh`
clears it with `--set *.cache-to=`, as `bench.sh` does, because the
cost is not small:

> On one gfx1201 run `triton-wheel` reported 38m52s, of which the trace
> accounted for 15m48s. The other **23m04s — 59% of its headline
> duration — was uploading `mode=max` cache.**

A harness measuring a build from nothing must not also time its own
uploads.

### In normal mode the export is the point

`make perf-build` reports the upload rather than suppressing it.
`perftrace.py` keeps BuildKit's `HTTP PUT`/`POST` spans alongside the
step spans, so the chart bands them as `upload` and the hover names the
blob and its size.

Those spans were discarded until a `triton-wheel` run showed 92 s of
steps inside a 430 s record, with the missing 336 s invisible: a node
that looked idle for most of its build was in fact uploading 6.4 GB.

## Dependency ordering, not stage barriers

Perf runs schedule from the bake graph. A target starts when every
dependency *inside the run* has finished and been pushed, and not
before; everything else it needs is resolved from Zot and checked by
[preflight](../architecture/build-graph.md#preflight) before any build
begins.

This replaced two earlier modes, and it is worth knowing why both
failed.

Stage barriers ordered work correctly but idled whole nodes waiting on
unrelated targets:

> On one gfx1201 run stage 1 took 44m16s of wall clock to do 77m09s of
> work, leaving **55m39s of idle builder time**, with the weakest node
> idle for 82% of it.

Flat per-node queues dropped the barrier and recovered that time, but
could not express a dependency at all. That was safe only while every
wheel was self-contained — and stopped being true the moment a run
included a target that builds `FROM` another, which is how a gfx1250
run scheduled `vllm-wheel` against a pytorch image nothing was
building.

Within the ordering constraint the packing is unchanged: longest-first
onto the node that would finish it soonest, one build per node at a
time, because several concurrent builds on one box each derive
`MAX_JOBS` from `MemAvailable` as though they were alone and
oversubscribe it.

### What a perf run measures

`PERF_TARGETS` defaults to bake's `wheels` group **plus `pytorch`**.

`pytorch` is not a wheel, so the group alone omitted it — and it is the
most expensive target in the graph as well as the image every other
wheel builds `FROM`. Leaving it out measured the cheap half of a build,
and on an arch nobody had built before it scheduled wheels against an
image that did not exist.

Including it costs little on a normal run, where the layer cache serves
it in seconds. On a cold run it genuinely rebuilds, which is what cold
means.


## What a target costs depends on which node runs it

`.builders/target-costs` is the input to that packing, and it has two
terms because a target's cost is not one number:

```text
build <target> <seconds>   compile cost, roughly node-independent
cache <target> <bytes>     what the target transfers when it exports
netmb <node>   <MB/s>      that node's upload throughput to the store
```

The cost of running a target on a node is `build + cache/netmb`, and
the packer picks the node that finishes it **soonest** rather than the
one that is least loaded.

The second term is not a refinement. The fleet's upload speeds span a
factor of 25 — 3000 MB/s on the store host itself, 90 wired, 3.7 over
WiFi — so the same 6.4 GB export is about a minute on one node and
about 28 on another.

> Ranking on build time alone sent `triton-wheel`, the largest export
> of any target, to the only node behind WiFi. Moving it to a wired
> node took it from 25m25s to 7m09s.

Re-measure after anything that moves the build materially, and
re-measure `netmb` if the fleet is rewired, since that is the term that
now dominates.

!!! warning "Take the byte figures from a normal run"
    A cold run passes `--no-push`, so its export counts the cache but
    not the image — which under-counted `aiter-wheel` by 4.3×.

A stale table degrades the schedule, never the build, and
`check-contracts.py` fails if a wheel or a node is missing from it —
because the fallback for a missing entry is to cost it at one second.

### Warm runs can invert which node is critical

These are cold-build costs. On a warm build every `build` term
collapses towards zero while the `cache` terms stay:

> In one `perf-build` run `pytorch-wheel` was a cache hit and freed its
> node after 55 s, leaving the WiFi node's four small targets — 2.8 GB
> between them — as the critical path of a 26-minute run.

Queues are fixed at plan time, so nothing migrates once packed.

## Contracts

Several of those streams are produced by one file and parsed by
another, with nothing but a comment connecting them — an nginx
`log_format` and a regex, the balancer's placement line and the
report's parser, the sampler's fields and the report's readers,
`target-costs` and the packer.

Every one has the same failure mode: the producer changes, the consumer
silently matches nothing, and the report renders perfectly while saying
`0` where it should say something.

`.builders/check-contracts.py` asserts each pair still agrees. It reads
files only — no registry, no GPU, no builders, no sudo — so it runs on
a bare CI runner in under a second, and `ci.yml` runs it alongside a
synthetic render of a perf report.
