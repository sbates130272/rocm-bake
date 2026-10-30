# rocm-bake

Reproducible builds of PyTorch, Triton, AITER, CuPy, NIXL, vLLM and
LMCache against ROCm, on a three-node BuildKit fleet, with every
artifact published to a local OCI registry.

**📖 Full documentation: <https://sbates130272.github.io/rocm-bake/>**

## Versions

<!-- BEGIN VERSIONS -->

| Component | Upstream | Bake variable | Pinned |
| --- | --- | --- | --- |
| PyTorch | [pytorch/pytorch](https://github.com/pytorch/pytorch) | `PYTORCH_VERSION` | `2.15.0` |
| ROCm | [rocm/dev-ubuntu-26.04](https://hub.docker.com/r/rocm/dev-ubuntu-26.04) | `ROCM_VERSION` | `10.1.0-full` |
| Python | [python.org](https://www.python.org/) | `PYTHON_VERSION` | `3.14` |
| Triton | [triton-lang/triton](https://github.com/triton-lang/triton) | `TRITON_VERSION` | `3.9.0` |
| AITER | [ROCm/aiter](https://github.com/ROCm/aiter) | `AITER_REF` | `v0.1.27` |
| NIXL | [ai-dynamo/nixl](https://github.com/ai-dynamo/nixl) | `NIXL_REF` | `v1.5.2` |
| UCX | [openucx/ucx](https://github.com/openucx/ucx) | `UCX_REF` | `v1.22.0` |
| vLLM | [vllm-project/vllm](https://github.com/vllm-project/vllm) | `VLLM_REF` | `v0.32.0` |
| CuPy | [cupy/cupy](https://github.com/cupy/cupy) | `CUPY_REF` | `v14.2.0` |
| LMCache | [LMCache/LMCache](https://github.com/LMCache/LMCache) | `LMCACHE_REF` | `v0.5.6` |

<!-- END VERSIONS -->

That table is generated from `rocm-bake.hcl` by `make version-scrub`, and
CI fails if it drifts. Triton is pinned to a commit (`TRITON_REF`) as well
as a version; `RUST_VERSION` and `SCCACHE_VERSION` are toolchain pins and
live in [the bake variables reference][vars]. Built for `gfx950` (default),
`gfx1201` and `gfx1250`.

`rocm-bake.hcl` is the single source for every value a build reads.
`make list-vars` prints what is actually in effect, and `make version-check`
compares it against what upstream has released and what we have published.

[vars]: https://sbates130272.github.io/rocm-bake/reference/bake-variables/

## Quick start

```bash
make help                          # every target, grouped
make zot-check                     # is the registry up?
make builder-setup                 # create all three buildx builders
sudo ./.builders/deploy-webdav.sh  # the shared compiler-cache store
make push-all BUILDER=snoc-pool    # build and publish everything
make watch                         # follow it from a second terminal
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

## Build targets

```text
pytorch-base ─┬─► triton-wheel ─┬─► pytorch ─┬─► pytorch-run
              │                 │            ├─► nixl-wheel
              │                 │            └─► aiter-wheel
              │                 ├─► pytorch-wheel
              │                 └─► pytorch-test
              └─► cupy-wheel

lmcache, lmcache-wheel  ◄─ cupy-wheel, nixl-wheel, pytorch, triton-wheel
vllm,    vllm-wheel     ◄─ aiter-wheel, lmcache-wheel, nixl-wheel,
                           pytorch, triton-wheel
```

Thirteen targets, three groups (`default`, `wheels`, `serving`). Bake
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

A second harness answers a different question — `make perf-run` builds
every wheel across the whole fleet at once, with CPU, compiler-cache and
registry traffic sampled throughout, and `make perf-report` renders it
as markdown plus SVG and interactive charts. `bench.sh` gives isolated
per-target cost; `perf-run` gives throughput under contention. Do not
quote one as if it were the other.

Measured results, why `warm` is an assertion rather than a number, and
what a fleet run found:
[Performance](https://sbates130272.github.io/rocm-bake/performance/).

## Repository layout

| | |
| --- | --- |
| `rocm-bake.hcl` | The build graph: 13 targets, 3 groups, 45 variables |
| `Makefile` | Wrapper; reads every default out of `rocm-bake.hcl` |
| `docker/` | Nine Dockerfiles; build context is always the repo root |
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
onto `gh-pages` separately by `make bench-publish`, run from a build
node, because that is the only place the numbers exist. The docs
workflow preserves `data/` when it deploys.

## License

MIT
