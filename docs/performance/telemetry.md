# Telemetry

Every build records its own metrics. This is separate from
[the benchmark harness](methodology.md): telemetry runs on every build
including real ones, the harness runs deliberately under controlled
conditions.

`telemetry/build.sh` wraps a bake invocation, runs it, then writes
Prometheus metrics for each target it produced — and exits with the
bake's own status, so it is a drop-in replacement for a bare `bake`
call. The `make build-*` and `make push-*` targets already route through
it.

```bash
./telemetry/build.sh --builder snoc-think pytorch
make build-pytorch                   # the same thing
TELEMETRY=0 make build-pytorch       # a bare bake
```

Both data sources already exist, so nothing has to be instrumented and
no collector daemon runs:

- **BuildKit's history API** (`docker buildx history inspect`) records
  every build's duration, status, and how many steps came from the layer
  cache.
- **sccache's own stats**, printed at the end of the build step and
  scraped back out of the replayed build log. They cannot be queried
  afterwards: the sccache server lives and dies with the build
  container.

## Metrics

All eight per-target metrics are gauges, labelled
`{target="…",builder="…"}`:

| Metric | Meaning |
| --- | --- |
| `rocm_build_duration_seconds` | BuildKit-reported duration |
| `rocm_build_steps_total` | Steps in the build |
| `rocm_build_steps_cached` | How many came from the layer cache |
| `rocm_build_layer_cache_hit_ratio` | Cached steps over total |
| `rocm_build_target_success` | 1 if the target completed |
| `rocm_build_sccache_hits` | Compiler-cache hits for that build |
| `rocm_build_sccache_misses` | Compiler-cache misses |
| `rocm_build_sccache_hit_ratio` | Hits over hits plus misses |

Three more describe the invocation as a whole, labelled `{builder="…"}`:

| Metric | Meaning |
| --- | --- |
| `rocm_build_invocation_duration_seconds` | Wall-clock for the whole bake |
| `rocm_build_invocation_success` | 1 if the bake exited 0 |
| `rocm_build_last_run_timestamp_seconds` | When the invocation finished |

A `HELP`/`TYPE` block is emitted only when at least one sample exists for
that name, so a scrape never sees a declared-but-empty metric.

## Where it lands

```
/var/lib/node_exporter/textfile_collector/rocm_pytorch_build.prom
```

written to a temp path and renamed, so the collector never reads a
partial file. node_exporter already runs on `:9100` here, so a scrape of
that target picks them up with no extra job.

Writing to the collector directory needs permission on it. When that
directory is not a writable directory, the wrapper falls back to
`telemetry/out/` (gitignored) and says so.

## Attributing sccache stats to a target

The subtle part. Replayed history records carry no bake-target prefix on
their vertex headers, so the step cannot be identified the way
[the benchmark harness](methodology.md#sccache-counters) does it
live. Instead each Dockerfile tees its stats to a known file, and the
wrapper finds the vertex whose command contains that marker:

| Target | Marker |
| --- | --- |
| `pytorch` | `/opt/pytorch/sccache-stats.txt` |
| `triton-wheel` | `/wheels-triton-sccache-stats.txt` |
| `aiter-wheel` | `/wheels-aiter-sccache-stats.txt` |

Having found the step number, it reads that step's stats lines. With no
marker present it falls back to the last stats block in the log, which
is a guess and is why the markers exist.

## Reading it back

```bash
make build-status     # build records on $(BUILDER), with the node each ran on
make build-inspect    # duration, steps, cached steps, VCS revision
make layer-summary    # layer reuse per image, most recent build of each
make cache-summary    # compiler-cache size and the delta since last call
```

`layer-summary` is keyed by image, not by node. Which node a target ran
on is an artefact of scheduling — the balancer moves targets between
nodes run to run — so a per-node view answers "what did this machine
last do" when the question is "how much of this image did we rebuild".
The node is still shown, because it explains a low number: a target that
moved nodes cannot use the previous node's local BuildKit cache and must
refetch from Zot.

## When numbers are missing

sccache counters are absent when a target was fully layer-cached. The
build step never ran, so it printed no stats. That is correct, not a
fault — and it is exactly the distinction the benchmark harness uses to
separate a hot run that compiled from one that skipped the compile.
