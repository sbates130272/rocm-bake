# rocm-bake

Reproducible builds of PyTorch, Triton, AITER, CuPy, NIXL, vLLM and
LMCache against ROCm, on a three-node BuildKit fleet, with every
artifact published to a local OCI registry.

Plus one that is not tied to ROCm at all: an arch-free vLLM that serves
from a captured latency profile instead of a GPU, so the serving path
can be exercised on any machine — including CI.

**Full documentation: <https://sbates130272.github.io/rocm-bake/>**

## Live Reports

Two lanes publish measurements continuously, to the `gh-pages` branch.
They are **not** comparable with each other.

| | What it measures | Published | Older runs |
| --- | --- | --- | --- |
| **[Fleet runs][perf]** | Every wheel across all three SNOC nodes at once, instrumented — CPU, compiler-cache and registry traffic sampled throughout | on demand, from a build node | interactive chart, selector over every run |
| **[Nightly builds][nightly]** | One warm bake per architecture on AWS CodeBuild, published to ECR — phase wall clock and cache errors | 02:17 UTC, from CI | table of every run |

A fleet run is a parallel build across three nodes sharing a compiler
cache; a nightly is sequential bakes on one rented machine. Both keep
every run published, each behind a `<stamp>/` permalink — but only the
fleet page charts, because a rented machine has nothing to sample.
Details: [Live reports][reports].

For fleet runs, `make perf-serve` is the same chart on `:8090` for a
run that is still going, regenerating every 30 s; `make perf-publish
PUSH=1` is what puts it on the web. It binds every interface by
default — `PERF_BIND=` narrows it, `make perf-serve-stop` ends it.

[perf]: https://sbates130272.github.io/rocm-bake/data/perf/
[nightly]: https://sbates130272.github.io/rocm-bake/data/nightly/
[reports]: https://sbates130272.github.io/rocm-bake/reports/

## Versions

<!-- BEGIN VERSIONS -->

| Component | Upstream | Bake variable | Pinned |
| --- | --- | --- | --- |
| PyTorch | [pytorch/pytorch](https://github.com/pytorch/pytorch) | `PYTORCH_VERSION` | `2.15.0` |
| ROCm | [rocm/dev-ubuntu-26.04](https://hub.docker.com/r/rocm/dev-ubuntu-26.04) | `ROCM_VERSION` | `10.1.0-full` |
| Python | [python.org](https://www.python.org/) | `PYTHON_VERSION` | `3.14` |
| Triton | [triton-lang/triton](https://github.com/triton-lang/triton) | `TRITON_VERSION` | `3.9.0` |
| AITER | [ROCm/aiter](https://github.com/ROCm/aiter) | `AITER_REF` | `v0.1.29` |
| torchvision | [pytorch/vision](https://github.com/pytorch/vision) | `TORCHVISION_REF` | `v0.29.2` |
| ATOM | [ROCm/ATOM](https://github.com/ROCm/ATOM) | `ATOM_REF` | `v0.1.9` |
| NIXL | [ai-dynamo/nixl](https://github.com/ai-dynamo/nixl) | `NIXL_REF` | `v1.5.2` |
| UCX | [openucx/ucx](https://github.com/openucx/ucx) | `UCX_REF` | `v1.22.0` |
| vLLM | [vllm-project/vllm](https://github.com/vllm-project/vllm) | `VLLM_REF` | `v0.33.0` |
| LLM-Emu | [AKafakA/llm-emu](https://github.com/AKafakA/llm-emu) | `LLM_EMU_REF` | `b71c6025b189784cbd4b926d15afa8257738ea39` |
| CuPy | [cupy/cupy](https://github.com/cupy/cupy) | `CUPY_REF` | `v14.2.0` |
| LMCache | [LMCache/LMCache](https://github.com/LMCache/LMCache) | `LMCACHE_REF` | `v0.5.7` |

<!-- END VERSIONS -->

That table is generated from `rocm-bake.hcl` by `make version-scrub`, and
CI fails if it drifts. Triton is pinned to a commit (`TRITON_REF`) as well
as a version; `RUST_VERSION` and `SCCACHE_VERSION` are toolchain pins and
live in [the bake variables reference][vars]. Built for `gfx950` (default),
`gfx1201` and `gfx1250` — plus one arch-free vLLM that needs no GPU at
all, which is how the serving stack gets tested; see [emulated
serving][emu].

`rocm-bake.hcl` is the single source for every value a build reads.
`make list-vars` prints what is actually in effect, and `make version-check`
compares it against what upstream has released and what we have published.

[vars]: https://sbates130272.github.io/rocm-bake/reference/bake-variables/
[emu]: https://sbates130272.github.io/rocm-bake/architecture/emulation/

## Quick start

```bash
make help                          # every target, grouped
make list-nodes                    # which fleet this is, and what it has
make zot-check                     # is the registry up?
make fleet-apply                   # bring every node to the manifest's state
make builder-setup                 # a buildx builder per node
make push-all BUILDER=snoc-pool    # build and publish everything
make build-watch                   # follow it from a second terminal
```

The step-by-step version is in the
[quick start guide](https://sbates130272.github.io/rocm-bake/quickstart/).

## The fleet

| Node          | GPU       | Role                                                                 |
| ------------- | --------- | -------------------------------------------------------------------- |
| `snoc-strix`  | `gfx1151` | Default builder; hosts Zot (`:8080`) and the sccache store (`:8081`) |
| `snoc-think`  | `gfx1201` | Build capacity, joined over SSH to `snoc-thinkstation`               |
| `snoc-gaming` | `gfx1201` | Build capacity, joined over SSH                                      |

No node has a `gfx950` card, which is the default build target — the
fleet cross-compiles. `make gpu-test` therefore needs `GPU_HOST` and
`PYTORCH_ROCM_ARCH` to agree with the hardware it lands on.

`BUILDER=snoc-pool` is a sentinel, not a builder: it routes through
`.builders/balance.sh`, which schedules one bake per target across the
fleet by current load and hands results between stages through the
registry.

That table is not written down twice. It comes from
`manifests/snoc.yml`, which is the only place a node name, address,
role or link speed appears — the Makefile, the balancer, the sampler,
the report and the Ansible inventory all read it through
`.builders/fleet.py`.

```bash
make list-nodes                   # the manifest in effect
make fleet-apply                  # make every node match it (Ansible)
make fleet-check                  # ask each node whether it can do its job
```

Details, including what each capability means and why `arch` is not the
same claim as the `gpu` capability:
[The fleet](https://sbates130272.github.io/rocm-bake/architecture/fleet/).

The fleet is driven by hand and registers no CI runner. The nightly
builds on AWS CodeBuild instead, publishing to ECR and sharing a
compiler cache on S3 — one measured night is $13.94. See
[Building on AWS](https://sbates130272.github.io/rocm-bake/operations/aws/).

## Build targets

```text
rocm-runtime ─► pytorch-base ─┬─► triton-wheel ─┬─► pytorch ─┬─► pytorch-run
                              │                 │            ├─► nixl-wheel
                              │                 │            ├─► aiter-wheel
                              │                 │            └─► torchvision-wheel
                              │                 ├─► pytorch-wheel
                              │                 └─► pytorch-test
                              └─► cupy-wheel

lmcache, lmcache-wheel  ◄─ cupy-wheel, nixl-wheel, pytorch, triton-wheel
vllm,    vllm-wheel     ◄─ aiter-wheel, lmcache-wheel, nixl-wheel,
                           torchvision-wheel, pytorch, triton-wheel
```

`rocm-runtime` is AMD's ROCm SDK cut down to the one GPU architecture
being built for and flattened into a single layer: 8.67 GB becomes
1.54 GB, and every image downstream inherits the difference. See
[Image sizes](https://sbates130272.github.io/rocm-bake/reference/image-sizes/).

Sixteen targets, three groups (`default`, `wheels`, `serving`). Bake
derives the DAG from each target's `contexts`, so asking for `vllm`
alone builds everything it needs.

`pytorch`/`pytorch-wheel`, `lmcache`/`lmcache-wheel` and `vllm`/`vllm-wheel`
are **siblings, not parent and child** — each pair is two stages over one
Dockerfile, with identical dependencies and neither feeding the other.
They are scheduled one at a time so the second reuses the first's builder
stage; run concurrently they compile the same objects twice. Full table with tags:
[Build targets](https://sbates130272.github.io/rocm-bake/reference/build-targets/).

## Four caches

| | What it holds | Where |
| --- | --- | --- |
| Content store | Blobs BuildKit has pulled or produced | Per node, 100 GB cap |
| Layer cache | Build layers as OCI artifacts, two-tier and arch-scoped | Zot `*-cache` repos |
| Compiler cache | Object files, fleet-wide | nginx WebDAV on Strix `:8081` |
| Pull-through | Upstream images | Zot mirrors Docker Hub, GHCR, Quay |

```bash
make layer-summary    # layer reuse per image
make cache-summary    # compiler-cache size and delta
make cache-check      # can every node reach the store?
```

Details: [Caching](https://sbates130272.github.io/rocm-bake/architecture/caching/).

## Build performance

Build time is tracked under four cache conditions, which nest — each is
the one below it with a further cache removed:

| Scenario | Condition |
| --- | --- |
| **frozen** | Nothing anywhere; the base image egresses from Docker Hub |
| **cold** | No layer cache, no compiler cache; base image local |
| **warm** | Caches populated, but a new commit moved `SOURCE_DATE_EPOCH` |
| **hot** | Same commit, everything cached |

```bash
make bench BENCH_SCENARIO=cold BUILDER=snoc-think
make bench-report
```

A second harness answers a different question — `make perf-cold` builds
every wheel across the whole fleet at once, with CPU, compiler-cache and
registry traffic sampled throughout, and `make perf-report` renders it
as markdown plus SVG and interactive charts. `bench.sh` gives isolated
per-target cost; `perf-cold` gives throughput under contention. Do not
quote one as if it were the other.

Measured results, why `warm` is an assertion rather than a number, and
what a fleet run found:
[Performance](https://sbates130272.github.io/rocm-bake/performance/).
The live numbers are at **[data/perf/][perf]** and
**[data/nightly/][nightly]**.

## Repository layout

| | |
| --- | --- |
| `rocm-bake.hcl` | The build graph: 16 targets, 3 groups, 52 variables |
| `manifests/` | The fleets: which machines, what each is for, how fast its uplink |
| `ansible/` | Makes a machine match the manifest; inventory is the manifest |
| `Makefile` | Wrapper; reads what is built from `rocm-bake.hcl` and where from the manifest |
| `docker/` | Ten Dockerfiles and the ROCm prune script; build context is always the repo root |
| `telemetry/build.sh` | Wraps a bake, emits Prometheus metrics |
| `serving/` | Compose file for the vLLM + LMCache pair |
| `.builders/` | Node setup, the balancer, the benchmark harness, registry readers |
| `docs/` | This documentation, published to `gh-pages` |

## Documentation

Built with MkDocs Material and published to the `gh-pages` branch by
`.github/workflows/docs.yml` on every push to `main`.

```bash
make docs-serve    # live reload on :8000
make docs-build    # into dist/site; fails on a broken internal link
```

Benchmark results are **not** committed to this branch. They are pushed
onto `gh-pages` separately by `make bench-publish` and `make
perf-publish`, run from a build node, because that is the only place
the numbers exist; the nightly's are written there by CI. The docs
workflow preserves `data/` when it deploys. See [Live reports][reports].

## License

MIT
