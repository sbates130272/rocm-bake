# Telemetry

Every build records its own metrics. Separate from
[the benchmark harness](methodology.md): telemetry runs on every build
including real ones, the harness runs under controlled conditions.

`telemetry/build.sh` wraps a bake invocation and writes Prometheus
metrics for each target it produced, exiting with bake's own status — a
drop-in replacement for a bare `bake`. Every `make build-*` and
`push-*` already routes through it.

```bash
./telemetry/build.sh --builder snoc-think pytorch
make build-pytorch                   # the same thing
TELEMETRY=0 make build-pytorch       # a bare bake
```

Both data sources already exist, so nothing is instrumented and no
collector daemon runs: **BuildKit's history API** for duration, status
and cached-step count, and **sccache's own stats**, printed at the end
of the build step and scraped out of the replayed log — they cannot be
queried afterwards, since the server dies with the build container.

## Metrics

Eight per-target gauges, labelled `{target="…",builder="…"}`:

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
`rocm_build_invocation_duration_seconds`,
`rocm_build_invocation_success` and
`rocm_build_last_run_timestamp_seconds`.

A `HELP`/`TYPE` block is emitted only when at least one sample exists for
that name, so a scrape never sees a declared-but-empty metric.

## Where It Lands

```
/var/lib/node_exporter/textfile_collector/rocm_pytorch_build.prom
```

Written to a temp path and renamed, so the collector never reads a
partial file, and picked up by the node_exporter already on `:9100`.
When that directory is not writable the wrapper falls back to
`telemetry/out/` and says so.

## Attributing sccache Stats To A Target

The subtle part. Replayed history records carry no bake-target prefix on
their vertex headers, so the step cannot be identified the way
[the harness](methodology.md#sccache-counters) does it live. Each
Dockerfile tees its stats to a known file instead, and the wrapper finds
the vertex whose command contains that marker:

| Target | Marker |
| --- | --- |
| `pytorch` | `/opt/pytorch/sccache-stats.txt` |
| `triton-wheel` | `/wheels-triton-sccache-stats.txt` |
| `aiter-wheel` | `/wheels-aiter-sccache-stats.txt` |
| `torchvision-wheel` | `/wheels-torchvision-sccache-stats.txt` |

Having found the step number, it reads that step's stats lines. With no
marker present it falls back to the last stats block in the log, which
is a guess and is why the markers exist.

## Reading It Back

```bash
make build-status     # build records on $(BUILDER), with the node each ran on
make build-inspect    # duration, steps, cached steps, VCS revision
make layer-summary    # layer reuse per image, most recent build of each
make cache-summary    # compiler-cache size and the delta since last call
```

`layer-summary` is keyed by image, not node: which node a target ran on
is an artefact of scheduling, so a per-node view answers the wrong
question. The node is still shown, because it explains a low number — a
target that moved nodes cannot use the previous node's local BuildKit
cache and must refetch from Zot.

## When Numbers Are Missing

sccache counters are absent when a target was fully layer-cached: the
build step never ran, so it printed no stats. That is correct, and it is
exactly the distinction the harness uses to separate a hot run that
compiled from one that skipped the compile.
