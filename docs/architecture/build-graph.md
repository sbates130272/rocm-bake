# Build graph

`rocm-bake.hcl` declares thirteen targets. Bake derives the build DAG
from the `contexts` each one names, and orders the graph itself — which
is why asking for `vllm` alone also builds `pytorch-base`,
`triton-wheel`, `pytorch`, `aiter-wheel`, `nixl-wheel`, `cupy-wheel` and
`lmcache-wheel`, in dependency order.

```mermaid
flowchart TD
    base["pytorch-base<br/><i>rocm/dev-ubuntu-26.04:10.1.0-full</i>"]
    triton["triton-wheel<br/><i>noarch</i>"]
    cupy["cupy-wheel"]
    pt["pytorch"]
    ptw["pytorch-wheel"]
    run["pytorch-run"]
    test["pytorch-test"]
    aiter["aiter-wheel"]
    nixl["nixl-wheel<br/><i>+ UCX from source</i>"]
    lmc["lmcache"]
    lmcw["lmcache-wheel"]
    vllm["vllm"]
    vllmw["vllm-wheel"]

    base --> triton
    base --> cupy
    base --> pt
    triton --> pt
    pt --> ptw
    pt --> run
    pt --> test
    pt --> aiter
    triton --> aiter
    pt --> nixl
    pt --> lmc
    triton --> lmc
    nixl --> lmc
    cupy --> lmc
    lmc --> lmcw
    pt --> vllm
    triton --> vllm
    aiter --> vllm
    nixl --> vllm
    lmcw --> vllm
    vllm --> vllmw
```

Four edges are worth explaining because they are not obvious from the
names.

**`triton-wheel` builds from the base, not from `pytorch`.** Triton
needs `cmake<4` while PyTorch pulls cmake 4.x, so they cannot share an
environment. That also means Triton can build in parallel with PyTorch
on another node. It is the only target with no architecture in its tag:
Triton is a compiler and publishes one noarch wheel.

**`cupy-wheel` hangs off the base too**, because CuPy has no torch
dependency. It is not optional. LMCache's multi-process server imports
cupy at module scope to build a `cupy.cuda.ExternalStream`, and no
published wheel fits this stack — PyPI's `cupy-rocm-7-0` targets a
different ROCm major, and plain `cupy` ships only an sdist. Without it
the server dies on the first request and vLLM waits five minutes before
reporting a generic engine failure.

**`vllm` consumes `lmcache-wheel`.** vLLM ships the LMCache MP
connector but imports `lmcache.utils` from it, so the wheel has to exist
first. On the scheduled path it has to be *published* first, not merely
building somewhere else.

**`lmcache` takes no AITER context.** Its extension is cache movement,
not GEMMs, and it has no AITER code path.

## Groups

| Group | Members |
| --- | --- |
| `default` | `pytorch-base`, `pytorch`, `pytorch-wheel`, `triton-wheel`, `aiter-wheel`, `cupy-wheel`, `nixl-wheel`, `vllm`, `vllm-wheel`, `lmcache`, `lmcache-wheel` |
| `wheels` | `pytorch-wheel`, `triton-wheel`, `aiter-wheel`, `nixl-wheel`, `cupy-wheel`, `vllm-wheel`, `lmcache-wheel` |
| `serving` | `cupy-wheel`, `nixl-wheel`, `vllm`, `vllm-wheel`, `lmcache`, `lmcache-wheel` |

There is no `all` group. Two targets are deliberately outside `default`:

- **`pytorch-test`** cannot run inside the build graph at all. Its stage
  exits 1 when `torch.cuda.is_available()` is false, and a BuildKit
  `RUN` step has no `/dev/kfd`. It is a verification step for a finished
  image on a real GPU (`make test` on a GPU node), and including it in
  `default` made `build-all` and `push-all` fail at the last target
  every time.
- **`pytorch-run`** is excluded because no node currently has a usable
  GPU to exercise the runtime image on, and building it every run costs
  time and a registry push for an artifact nobody can test.
  `make push-runtime` still builds it, and it belongs back in `default`
  once a GPU node is available.

## How inputs are wired

Targets take their inputs from sibling targets through `target:` named
contexts. That is bake's dependency mechanism and the only one it has.

```hcl
contexts = USE_PUB ? {} : {
  triton-wheels = "target:triton-wheel"
  base-img      = "target:pytorch-base"
}
args = {
  TRITON_WHEEL_IMAGE = USE_PUB ? PUB_TRITON : "triton-wheels"
  BASE_IMAGE         = USE_PUB ? PUB_BASE   : "base-img"
}
```

A target with no context on its inputs is, as far as bake is concerned,
independent — and may run concurrently with the thing it needs.

### `PUBLISHED_INPUTS`

Set `PUBLISHED_INPUTS=1` and every one of those contexts collapses to a
registry reference instead. The `PUB_*` locals in `rocm-bake.hcl` hold
those references, and they must track the `tags` of the target they
mirror — a change to one is a change to the other.

This is what makes cross-node scheduling possible. A `target:` context
only works within one bake invocation, so one-bake-per-node would
rebuild the whole chain on every node rather than pulling what the
previous stage just pushed.

`pytorch-run` is the exception: its context has to resolve in both
modes, so it uses a `docker-image://` reference.

!!! note
    `PUBLISHED_INPUTS` is read by bake from the environment, so it needs
    `PUBLISHED_INPUTS=1 make …`, not `make … PUBLISHED_INPUTS=1`. The
    same is true of `SCCACHE_LOG`, `RUN_ID`, `CACHE_TAG_SUFFIX` and the
    `SDE_*` overrides.

## The balancer

buildx's multi-node builder does not balance. Node selection is driven
by platform matching, and when every node advertises `linux/amd64` the
choice among them ignores capacity: all five targets once landed on
`snoc-gaming` (16 cores, 15 GB) while `snoc-think` (32 cores, 122 GB)
sat idle. There is no hook to change that, so the scheduling happens in
`.builders/balance.sh` instead — one bake invocation per target, each
pinned to a builder it picks.

```bash
make push-all BUILDER=snoc-pool       # the usual way to build everything
make push-wheels BUILDER=snoc-pool    # just the wheel artifacts
.builders/balance.sh --dry-run        # what it would schedule, and where
.builders/balance.sh --best           # the strongest node right now
```

Nodes are scored by free GB of RAM plus idle cores, weighted equally on
purpose: a cold PyTorch build runs one `cc1plus` per core and each takes
1–2 GB, so RAM is what actually bounds a big node. Nodes below
`MIN_MEM_GB` (default 8) are skipped.

Work runs in stages. Targets within a stage run concurrently on
different nodes; stages run in order.

| Stage | Default | Why |
| --- | --- | --- |
| `STAGE_1` | `pytorch-base` | Everything depends on it |
| `STAGE_2` | `triton-wheel` | The pytorch image installs this wheel, so it is on the critical path |
| `STAGE_2B` | `pytorch` | |
| `STAGE_3` | `aiter-wheel nixl-wheel pytorch-wheel` | The first stage wide enough to use the whole fleet |
| `STAGE_3B` | `cupy-wheel` | Only `lmcache` consumes it; stage 3 is already the widest point |
| `STAGE_4` | `lmcache lmcache-wheel` | The wheel must be published before vLLM starts |
| `STAGE_5` | `vllm vllm-wheel` | |

Order **within** a stage is priority, not preference: targets are handed
to nodes best-first, so the most expensive target must be listed first
or it gets whatever is left. That was backwards for stage 3 once —
`aiter-wheel` was last, so a 50-minute kernel compile landed on the
weakest node at `MAX_JOBS=12` while two targets costing 67 s and 32 s
took `snoc-think`'s 32 jobs.

Stage width is the whole game for this scheduler. It parallelises
*within* a stage, so a one-target stage always goes to the single best
node however the others score. Stages 1, 2 and 2B are width-1 because
the dependency chain genuinely is serial there.

Every stage is overridable, so a run can skip a target without editing
the file — `STAGE_3="pytorch-wheel"` builds a new arch without AITER,
which costs more than everything else combined.

### Queue mode drops the barrier

`balance.sh --queue` is a second scheduling mode, and it is the default
for [performance runs](../performance/perf-runs.md#queues-not-stage-barriers).

Stages exist to order work that depends on earlier work. Under
`PUBLISHED_INPUTS=1` nothing here does — every wheel resolves to a
self-contained target that pulls its inputs from Zot — so the barrier
buys nothing and costs a great deal: on one measured run stage 1 took
44m16s of wall clock to do 77m09s of work, leaving 55m39s of idle
builder time.

In queue mode the stage variables only set the pool. Targets are packed
onto nodes longest-first and each node drains its own list sequentially
while the nodes run concurrently — sequential per node because several
concurrent builds on one box each derive `MAX_JOBS` from
`MemAvailable` as though they were alone, and oversubscribe it.

The packing cost model is `.builders/target-costs`, and it ranks by
which node would *finish* a target soonest rather than which is least
loaded, because this fleet's upload speeds span a factor of 25.

Barriers remain the right answer the moment a target gains a real
dependency on another: `PERF_QUEUE=0`, or simply do not pass
`--queue`.

### Why `build-all` refuses the pool

`make build-all BUILDER=snoc-pool` exits with an error rather than
scheduling. Scheduling makes every target its own bake invocation, so
they cannot hand results to each other through `target:` contexts —
stage 2 would build against whatever happens to be in the registry
rather than what stage 1 just produced, silently. On a single builder
the contexts resolve in-process and it is fine.

```bash
make push-all  BUILDER=snoc-pool    # scheduled, publishes
make build-all BUILDER=snoc-think   # single builder, no push
```

## `MAX_JOBS`

Left empty, each build derives its own job count from the node it lands
on, sized by `MemAvailable` rather than by core count, with a per-job
memory budget of 2 GB. Set `MAX_JOBS` to pin one.

The derivation is sampled when the *compile* step starts, by which point
the build's own earlier steps have taken memory of their own. A cold
PyTorch that settled at 21 GB available still derived 5 jobs, where the
same node gives a hot run 10 — because a hot run's early steps are all
cache hits. The derivation therefore tracks how much work precedes the
compile, which differs by scenario. That is why
[the benchmark harness](../performance/methodology.md) keys its results
by job count and can pin it.

## Telling builds apart

Every target stamps `rocm-pytorch-build/<target>/<arch>/<RUN_ID>` into
its BuildKit history record. `RUN_ID` defaults to `dev`.

The prefix is this repository's name rather than something shorter
because a sibling project builds on the same nodes, uses the same
convention, and produces images with the same names — `pytorch`,
`triton`, `aiter`. A shared prefix made its builds indistinguishable
from these in `make watch`.
