# Instrumented Fleet Runs

Every wheel built across the whole fleet at once, with CPU, memory,
compiler-cache and registry traffic sampled throughout. Published at
**[data/perf/](https://sbates130272.github.io/rocm-bake/data/perf/)**.

## Three Harnesses, Three Questions

| | `bench.sh` | `make perf-cold` | `make perf-warm` |
| --- | --- | --- | --- |
| runs targets | one at a time | across the fleet at once | across the fleet at once |
| caches | isolated | none | both, as normal |
| answers | what does *this* target cost | a full cold build | the build you actually run |
| numbers are | isolated per-target | throughput under contention | throughput under contention |

!!! danger "Do not quote a number from one as if it came from another"
    [`bench.sh`](index.md) serialises on purpose and isolates its
    compiler cache. The `perf-*` harnesses run the fleet flat out, so
    three builds share the sccache store and the registry — both on
    Strix, which is also a build node. The
    [nightly on AWS](../operations/aws.md) is a fourth lane again.

A warm run's cost is almost entirely export rather than compute.

## Running One

```bash
make perf-plan                      # placement only, builds nothing
make perf-cold PERF_ARCH=gfx1201    # cold: no caches, hours
make perf-warm PERF_ARCH=gfx1201    # warm: caches on, pushes
make perf-report                    # markdown + SVG from the newest run
make perf-serve                     # live chart on :8090
```

Cold means `--no-cache` **and** an sccache prefix of its own: a cold run
must not evict the fleet's working cache, and must not hit it either.
`PERF_ARCH`, `PERF_TARGETS` and `PERF_BIND` configure the rest.

!!! warning "`perf-serve` binds every interface"
    The usual viewer is a laptop on the LAN that is not on tailscale.
    What that exposes is build telemetry — hostnames, CPU figures, step
    names — with no credentials and no registry access.

### Bootstrapping, And The Cold Namespace

Neither harness builds the images its wheels sit on, so they bootstrap
themselves: `depgraph.py --missing-targets` names what the registry
lacks, and those are built and pushed before the measured run. That step
is **warm and pushed even under `perf-cold`**, and is not sampled — cold
is a claim about the wheels being measured, not their inputs.

`perf-cold` pushes into `${REGISTRY_NAME}-coldrun`. It used to pass
`--no-push` while `balance.sh` set `PUBLISHED_INPUTS=1` — which it must,
since `target:` contexts only resolve within one builder — so every
target resolved its inputs from the *previous* run. `REGISTRY_NAME`
moves tags, caches and `PUB_*` refs together, so a fresh namespace
builds the whole stack from nothing and the live one is never written
to. `PERF_COLD_NAMESPACE=` keeps two cold runs apart.

## What A Run Collects

Into `/var/tmp/rocm-perf/<stamp>/`:

| File | From | Answers |
| --- | --- | --- |
| `samples.jsonl` | node_exporter, polled | CPU, memory, disk and network over time |
| `trace-<target>.json` | the builder's build record | what ran, when, for how long |
| `sccache.log` | the WebDAV nginx log, sliced | what was written to the compiler cache |
| `zot.jsonl` | Zot's structured log, sliced | layer-cache and image writes, with sizes |
| `artifacts.txt` | `wheelhouse.py` | what ended up published |
| `index.html` + `data.json` | `perfreport.py` | the interactive chart and its sidecar |

The two cache logs are appended to *during* the run, then replaced by a
single authoritative slice at the end — without that a run in flight had
no cache data, and the chart drops the whole bar lane when `hits` is
missing. Appending beats re-slicing because `zot.jsonl` reached 294.6 MB
on one run, costing 6 s per `perf-serve` regen; that parse, not the
capture, sets the refresh floor.

`perf-report` writes `report.md` with SVG charts, plus an `index.html`
with overlaid CPU and memory lines, a legend filtering by builder *and*
target, and per-band hover showing the `RUN` commands a phase covers.
Both share one axis because both are percentages — a second y-scale
would make it a dual-axis chart, the form that misleads most reliably —
so memory is distinguished by dash and colour keeps following the
builder. `perf-serve` polls `data.json` rather than reloading, because
the legend *is* the filter.

`make perf-publish PUSH=1` puts that page on the web with a selector for
every earlier run.

## `build` And `total` Are Different Numbers

`build` is the span of the target's own steps; `total` is the whole
record. The gap is setup plus export, usually the larger.

**In cold mode the export is excluded.** `--no-push` suppresses the
image push but not the cache export, a separate registry write, so
`perfrun.sh` clears it with `--set *.cache-to=`:

> On one gfx1201 run `triton-wheel` reported 38m52s, of which the trace
> accounted for 15m48s. The other **23m04s — 59% of its headline
> duration — was uploading `mode=max` cache.**

**In warm mode the export is the point.** `perftrace.py` keeps
BuildKit's `HTTP PUT`/`POST` spans alongside the step spans, banded as
`upload`. They were discarded until a `triton-wheel` run showed 92 s of
steps inside a 430 s record — a node that looked idle was uploading
6.4 GB.

## Dependency Ordering, Not Stage Barriers

A target starts when every dependency *inside the run* has finished and
been pushed; everything else is resolved from Zot and checked by
[preflight](../architecture/build-graph.md#preflight). Stage barriers
ordered work correctly but idled whole nodes:

> On one gfx1201 run stage 1 took 44m16s of wall clock to do 77m09s of
> work, leaving **55m39s of idle builder time**, with the weakest node
> idle for 82% of it.

Flat per-node queues recovered that time but could not express a
dependency at all — which is how a gfx1250 run scheduled `vllm-wheel`
against a pytorch image nothing was building.

`PERF_TARGETS` defaults to the `wheels` group **plus `pytorch`**, which
is not a wheel but is the most expensive target in the graph and the
image every wheel builds `FROM`.

## What A Target Costs Depends On Which Node Runs It

Two terms from `.builders/target-costs`, which describes targets, and
one from the [fleet manifest](../architecture/fleet.md), which describes
machines:

```text
build <target> <seconds>   compile cost, roughly node-independent
cache <target> <bytes>     what the target transfers when it exports
link_mbps: <MB/s>          that node's upload throughput to the store
```

Cost is `build + cache/link_mbps`, and the packer picks the node that
finishes **soonest**, not the one least loaded. The second term is not a
refinement: uplinks span a factor of 25, so the same 6.4 GB export is
about a minute on one node and 28 on another.

> Ranking on build time alone sent `triton-wheel`, the largest export of
> any target, to the only node behind WiFi. Moving it to a wired node
> took it from 25m25s to 7m09s.

On a fleet whose nodes share one uplink speed the term cancels and
placement collapses to plain LPT.

Warm runs can invert which node is critical, since every `build` term
collapses towards zero while the `cache` terms stay:

> In one `perf-warm` run `pytorch-wheel` was a cache hit and freed its
> node after 55 s, leaving the WiFi node's four small targets — 2.8 GB
> between them — as the critical path of a 26-minute run.

Queues are fixed at plan time, so nothing migrates once packed.

!!! warning "Take the byte figures from a normal run"
    A cold run passes `--no-push`, so its export counts the cache but
    not the image — which under-counted `aiter-wheel` by 4.3×.

## Contracts

Several of those streams are produced by one file and parsed by another
with nothing but a comment connecting them: an nginx `log_format` and a
regex, the balancer's placement line and the report's parser,
`target-costs` and the packer. Every one fails the same way — the
producer changes, the consumer silently matches nothing, and the report
renders perfectly while saying `0`. `.builders/check-contracts.py`
asserts each pair still agrees, reading files only, in under a second.
