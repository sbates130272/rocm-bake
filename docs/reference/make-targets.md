# Make targets

`make help` is authoritative and prints the live list with the values
currently in effect. This page is a map of the groups and the ones worth
knowing about; a target missing here is not a target that does not
exist.

Targets marked `*` in `make help` build **and push** to the registry,
which needs the `ci` login.

```bash
make help          # every target, grouped
make list-vars     # every variable these targets read, with its value
```

## Registry (Zot)

| Target | |
| --- | --- |
| `zot-check` | Is the registry active and answering? |
| `zot-catalog` | List repositories |
| `zot-tags` | List tags for one repo — `REPO=rocm-pytorch/base` |
| `zot-wheels` | Published wheel artifacts, newest first — `ZOT_TAGS=0` for all |
| `zot-wheelhouse` | The same with sizes, plus anything extracted into `./dist/wheels` |
| `zot-logs` | Follow the registry's journal |

Nothing here starts, stops or configures Zot. It is a bare-metal
systemd service owned outside this repository.

## Compiler cache

| Target | |
| --- | --- |
| `cache-summary` | Endpoint, size, disk, deltas and per-target hit rates |
| `cache-check` | Can every build node reach the store? |
| `cache-logs` | Follow the WebDAV access log |
| `layer-summary` | Layer reuse per image on its most recent build |

## Builders

| Target | |
| --- | --- |
| `builder-setup` | All three builders |
| `builder-snoc-strix` | Local `docker-container` driver |
| `builder-snoc-think` | `snoc-thinkstation`, over SSH |
| `builder-snoc-gaming` | `snoc-gaming`, over SSH |
| `builder-snoc-pool` | All three as one buildx builder (little used — see below) |
| `builder-status` | Every builder and its nodes |
| `builder-health` | Which builders can take work |
| `builder-load` | CPU, cores and load per node of `$(BUILDER)` |
| `builder-logs` | buildkitd's **own** log: registry auth, GC, connection failures |
| `builder-restart` | Restart buildkitd on `$(BUILDER)`, clearing a wedged build |

`builder-ensure` gates every build target on `builder-health`, which is
why a build fails fast against a dead node rather than hanging.

`builder-restart` drops that node's in-memory build state. The registry
layer cache and the shared compiler cache are untouched, so the next
build still picks up where it can.

## Watching a build

| Target | |
| --- | --- |
| `watch` | Live: history across all `snoc-*` builders, a tail of each running build, layer reuse and cache deltas |
| `build-status` | Build records on `$(BUILDER)`, with the node each ran on |
| `build-logs` | What a build's steps printed — `BUILD=<id>`, default most recent |
| `build-inspect` | Duration, step count, cached steps, VCS revision |
| `build-stop` | Cancel builds started from this repository |

```bash
make watch
make watch WATCH_BUILDERS=snoc-think
make watch WATCH_LINES=40 WATCH_INTERVAL=2
```

!!! tip "Two logs, easy to confuse"
    `build-logs` is the output of the build's steps — what a `RUN`
    printed. `builder-logs` is the daemon underneath, and it is where a
    registry failure, a DNS failure or a cache problem shows up, often
    while the build itself just looks slow.

`build-stop` works off a PID file (`/tmp/.rocm-build.pids`) that every
bake invocation and the balancer write to. Matching command lines with
`pgrep -f` was unreliable: it killed the invoking shell, and it killed
the sibling project's builds.

## Build and push

| Build (no push) | Push | Target |
| --- | --- | --- |
| `build-base` | `push-base` | `pytorch-base` |
| `build-pytorch` | `push-pytorch` | `pytorch` |
| `build-runtime` | `push-runtime` | `pytorch-run` |
| `build-torch-wheel` | `push-torch-wheel` | `pytorch-wheel` |
| `build-triton-wheel` | `push-triton-wheel` | `triton-wheel` |
| `build-aiter-wheel` | `push-aiter-wheel` | `aiter-wheel` |
| `build-cupy-wheel` | `push-cupy-wheel` | `cupy-wheel` |
| `build-nixl-wheel` | `push-nixl-wheel` | `nixl-wheel` |
| `build-vllm` | `push-vllm` | `vllm` |
| `build-vllm-wheel` | `push-vllm-wheel` | `vllm-wheel` |
| `build-lmcache` | `push-lmcache` | `lmcache` |
| `build-lmcache-wheel` | `push-lmcache-wheel` | `lmcache-wheel` |
| `build-serving` | `push-serving` | the `serving` group |
| `build-all` | `push-all` | the `default` group |
| — | `push-wheels` | the `wheels` group |

Every wheel has a `build-` form as well as a `push-` form. The build-only
targets exist because the benchmark harness needs them: it dispatches
through `make build-<name>`, and a `push-` target writes to the registry,
which the credential helper cannot do unattended. Without them a cold
measurement stopped at the first wheel that had no build-only target.

`fetch-torch-wheel`, `fetch-triton-wheel`, `fetch-aiter-wheel`,
`fetch-cupy-wheel`, `fetch-nixl-wheel`, `fetch-vllm-wheel` and
`fetch-lmcache-wheel` pull a published wheel artifact into `./dist`.

`cold-build` builds `COLD_TARGET` (default `pytorch`) with neither
layer cache nor compiler-cache hits.

!!! note "`build-all` refuses `BUILDER=snoc-pool`"
    Scheduling makes every target its own bake invocation, so they
    cannot hand results to each other through `target:` contexts. Use
    `push-all BUILDER=snoc-pool` (scheduled, publishes) or
    `build-all BUILDER=snoc-think` (single builder, no push). See
    [the balancer](../architecture/build-graph.md#the-balancer).

## Multiple architectures

| Target | |
| --- | --- |
| `arches-<anything>` | Run any target once per architecture in `ARCHES` |
| `arches-list` | What `ARCHES` resolves to, with the tag each would produce |
| `wheel-index` | Fetch each architecture's wheels and build a PEP 503 index |
| `wheel-index-check` | Install each generated index into a throwaway venv |

`arches-%` is a pattern rule and takes any target name, not only the
documented examples.

## Test and serve

| Target | |
| --- | --- |
| `test` | The in-graph `pytorch-test` stage, which needs a GPU |
| `gpu-test` | Run a published image on a real GPU — `GPU_HOST=`, `PYTORCH_ROCM_ARCH=` |
| `serve-vllm` | vLLM alone on `GPU_HOST`, no KV offload |
| `serve-stack` | vLLM plus the LMCache MP server |
| `serve-wait` | Block until `/health` answers |
| `serve-test` | Prove the KV cache is actually working |
| `serve-test-baseline` | The same for a `serve-vllm` stack |
| `serve-test-l2` | Prove the disk tier serves blocks — needs `KV_TIER=file` |
| `serve-logs` | Both containers, merged, live |
| `serve-logs-cache` | The same, filtered to hit/miss/store lines |
| `serve-logs-sorted` | A snapshot merged in timestamp order |
| `serve-status` | What is running on `GPU_HOST` |
| `serve-down` | Stop and remove |

See [Serving stack](../architecture/serving.md).

## Benchmarks

| Target | |
| --- | --- |
| `bench` | Run the harness — `BENCH_SCENARIO=frozen\|cold\|warm\|hot\|all\|everything` |
| `bench-report` | Render accumulated results as markdown |
| `bench-data` | Aggregate into `dist/bench/bench.json` for the docs site |
| `bench-publish` | Commit that onto `gh-pages`; `PUSH=1` to push |

See [Performance](../performance/index.md).

## Performance runs

| Target | |
| --- | --- |
| `perf-plan` | Which builder each wheel would land on; builds nothing |
| `perf-run` | Cold parallel build of every wheel, fully instrumented |
| `perf-build` | The same instrumentation on a *normal* build — caches on, pushes |
| `perf-report` | Render the newest run as markdown plus SVG charts |
| `perf-serve` | Serve the newest run's interactive chart on `:8090` |
| `perf-runs` | List collected runs, newest last |

A different question from `bench`: the fleet flat out rather than one
target in isolation. `perf-run` is a build from nothing; `perf-build`
is the build you actually run, where the cost is almost entirely export
rather than compute. See
[Instrumented fleet runs](../performance/perf-runs.md).

`PERF_ARCH` selects the architecture, `PERF_QUEUE=0` reverts to stage
barriers, and `PERF_BIND` narrows what `perf-serve` listens on — it
binds every interface by default.

## Versions

| Target | |
| --- | --- |
| `version-check` | Upstream releases vs published wheels vs our pins |
| `version-scrub` | Regenerate the version tables from `rocm-bake.hcl` |
| `version-scrub-check` | Fail if those generated tables are stale |

`version-check` needs the network: `gh` for api.github.com and the
tailnet for the registry. `version-scrub` reads `rocm-bake.hcl` and
nothing else, which is what lets `version-scrub-check` gate every pull
request in `lint.yml`.

The tables it generates live between `<!-- BEGIN VERSIONS -->` markers
in `README.md` and in [Bake variables](bake-variables.md). Bump a
version in `rocm-bake.hcl`, run `make version-scrub`, commit both.

## Documentation

| Target | |
| --- | --- |
| `docs-deps` | Create the docs venv from `docs/requirements.txt` |
| `docs-build` | Build into `dist/site`; fails on a broken internal link |
| `docs-serve` | Serve locally with live reload on `:8000` |

## Utilities

| Target | |
| --- | --- |
| `validate` | Is the bake file parseable? |
| `bake-plan` | Print the resolved build plan as JSON |
| `list-vars` | Every variable these targets read, with its value and source |
| `clean` | Remove built images locally, for every architecture in `ARCHES` |
| `clean-cache` | Remove cache images locally — the registry must be pruned separately |
| `setup` | `zot-check` then `builder-setup` |

## Variables worth knowing

| Variable | Default | |
| --- | --- | --- |
| `BUILDER` | `snoc-strix` | Which builder, or `snoc-pool` for the balancer |
| `ARCHES` | `gfx950 gfx1201 gfx1250` | What `arches-*` fans out over |
| `PYTORCH_ROCM_ARCH` | `gfx950` | The architecture for **one** build |
| `TELEMETRY` | `1` | `0` skips the metrics wrapper |
| `BAKE_EXTRA` | — | Arbitrary extra flags passed to bake |
| `GPU_HOST` | `snoc-thinkstation` | The machine with `/dev/kfd` |
| `REPO` | `rocm-pytorch/base` | What `zot-tags` lists |
| `ZOT_TAGS` | `5` | Tags per repo in `zot-wheels`; `0` for all |
| `BENCH_SCENARIO` | `all` | Which benchmark scenario `make bench` runs |

!!! warning "Some variables only work from the environment"
    `make <target> VAR=value` works for anything the Makefile reads.
    But `SCCACHE_LOG`, `PUBLISHED_INPUTS`, `RUN_ID`, `CACHE_TAG_SUFFIX`
    and the `SDE_*` overrides are read by **bake**, from the
    environment — so they need `VAR=value make <target>` instead.
