# Make Targets

`make help` is authoritative and prints the live list with the values
currently in effect. This page is a map of the groups; a target missing
here is not a target that does not exist. Targets marked `*` in `make
help` build **and push** to the registry, which needs the `ci` login.

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
| `image-sizes` | Published image sizes, split into shared and own layers — `LAYERS=1` for the breakdown |
| `image-data` | Aggregate those into `dist/images/images.json` for the docs site |
| `image-publish` | Commit that onto `gh-pages`; `PUSH=1` to push |
| `zot-disk` | What the registry actually occupies, deduplicated — registry host only |

Nothing here starts, stops or configures Zot — it is a bare-metal
systemd service owned outside this repository. `image-sizes` and
`zot-disk` answer different questions and disagree by a factor of two:
see [Image sizes](image-sizes.md).

## Compiler Cache

| Target | |
| --- | --- |
| `cache-summary` | Endpoint, size, disk, deltas and per-target hit rates |
| `cache-check` | Can every build node reach the store? (`fleet-check` asks more) |
| `cache-logs` | Follow the WebDAV access log |
| `layer-summary` | Layer reuse per image on its most recent build |

## Fleet

| Target | |
| --- | --- |
| `list-nodes` | Which manifest is in effect, and the nodes it declares |
| `fleet-apply` | Bring every node to the state the manifest claims (Ansible) |
| `fleet-check` | Read-only acceptance test: can each node do its job? |
| `builder-setup` | A buildx builder for every build node in the manifest |
| `builder-<node>` | One of them — `builder-snoc-think`, say |
| `builder-pool` | Every build node as one buildx builder (little used — see below) |
| `builder-status` | Every builder and its nodes |
| `builder-health` | Which builders can take work |
| `builder-load` | CPU, cores and load per node of `$(BUILDER)` |
| `builder-logs` | buildkitd's **own** log: registry auth, GC, connection failures |
| `builder-restart` | Restart buildkitd on `$(BUILDER)`, clearing a wedged build |

`builder-ensure` gates every build target on `builder-health`, so a
build fails fast against a dead node rather than hanging.
`builder-restart` drops only that node's in-memory build state.

`builder-<node>` is a pattern rule over the manifest's node names, so a
new node needs no Makefile edit. The buildkitd config is baked in at
create time — an existing builder does not pick up a later manifest
change, and adopting one costs that node's content store:
`docker buildx rm snoc-think && make builder-snoc-think`. See
[The fleet](../architecture/fleet.md).

## Watching A Build

| Target | |
| --- | --- |
| `watch` | Live: history across every builder, a tail of each running build, layer reuse and cache deltas |
| `build-status` | Build records on `$(BUILDER)`, with the node each ran on |
| `build-logs` | What a build's steps printed — `BUILD=<id>`, default most recent |
| `build-inspect` | Duration, step count, cached steps, VCS revision |
| `build-stop` | Cancel builds started from this repository |

```bash
make watch WATCH_BUILDERS=snoc-think WATCH_LINES=40 WATCH_INTERVAL=2
```

!!! tip "Two logs, easy to confuse"
    `build-logs` is the output of the build's steps — what a `RUN`
    printed. `builder-logs` is the daemon underneath, and it is where a
    registry failure, a DNS failure or a cache problem shows up, often
    while the build itself just looks slow.

`build-stop` works off a PID file (`/tmp/.rocm-build.pids`) that every
bake invocation and the balancer write to. Matching command lines with
`pgrep -f` killed the invoking shell, and the sibling project's builds.

## Build And Push

Every target has a `build-<name>` form and a `push-<name>` form. Four
names do not match their bake target:

| Make | Bake target |
| --- | --- |
| `build-base` / `push-base` | `pytorch-base` |
| `build-runtime` / `push-runtime` | `pytorch-run` |
| `build-torch-wheel` / `push-torch-wheel` | `pytorch-wheel` |
| `build-triton-wheel` / `push-triton-wheel` | `triton-wheel` (noarch) |

The rest are the obvious ones: `pytorch`, `rocm-runtime`,
`pytorch-src`, `aiter-wheel`, `cupy-wheel`, `nixl-wheel`, `vllm`,
`vllm-wheel`, `lmcache`, `lmcache-wheel`. Group targets are
`build-serving`/`push-serving`, `build-all`/`push-all` (the `default`
group) and `push-wheels`.

The build-only forms exist because the benchmark harness dispatches
through `make build-<name>`, and a `push-` target writes to the
registry, which the credential helper cannot do unattended.

`fetch-<name>-wheel` pulls a published wheel artifact into `./dist`.
`build-cold` builds `COLD_TARGET` (default `pytorch`) with neither
layer cache nor compiler-cache hits.

!!! note "`build-all` refuses `BUILDER=snoc-pool`"
    Scheduling makes every target its own bake invocation, so they
    cannot hand results to each other through `target:` contexts. Use
    `push-all BUILDER=snoc-pool` (scheduled, publishes) or
    `build-all BUILDER=snoc-think` (single builder, no push). See
    [the balancer](../architecture/build-graph.md#the-balancer).

## Multiple Architectures

| Target | |
| --- | --- |
| `arches-<anything>` | Run any target once per architecture in `ARCHES` |
| `arches-list` | What `ARCHES` resolves to, with the tag each would produce |
| `wheel-index` | Fetch each architecture's wheels and build a PEP 503 index |
| `wheel-index-check` | Install each generated index into a throwaway venv |

`arches-%` takes any target name, not only the documented examples.

## Test And Serve

| Target | |
| --- | --- |
| `test` | The in-graph `pytorch-test` stage, which needs a GPU |
| `gpu-test` | Run a published image on a real GPU — `GPU_HOST=`, `PYTORCH_ROCM_ARCH=` |
| `serve-vllm` | vLLM alone on `GPU_HOST`, no KV offload |
| `serve-stack` | vLLM plus the LMCache MP server |
| `serve-wait` | Block until `/health` answers |
| `serve-test` | Prove the KV cache is actually working (`-baseline`, `-l2` variants) |
| `serve-logs` | Both containers, merged, live (`-cache`, `-sorted` variants) |
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

## Performance Runs

| Target | |
| --- | --- |
| `perf-plan` | Which builder each wheel would land on; builds nothing |
| `perf-cold` | Cold parallel build of every wheel, fully instrumented |
| `perf-warm` | The same instrumentation on a *warm* build — caches on, pushes |
| `perf-report` | Render the newest run as markdown plus SVG charts |
| `perf-serve` | Serve the newest run's interactive chart on `:8090` |
| `perf-serve-stop` | Stop it and free `PERF_PORT` |
| `perf-serve-status` | Whether one is running, and where |
| `perf-runs` | List collected runs, newest last |
| `perf-publish` | Commit a run onto `gh-pages`; `PUSH=1` to push |

The fleet flat out, rather than one target in isolation. Both build and
push whatever the registry is missing first, so neither needs a manual
bootstrap. `PERF_ARCH`, `PERF_TARGETS` and `PERF_BIND` configure them;
see [Instrumented fleet runs](../performance/perf-runs.md).

`perf-serve` and the published
**[data/perf/](https://sbates130272.github.io/rocm-bake/data/perf/)**
page are the same tool: `perf-publish` puts the chart `perf-serve`
renders onto `gh-pages`, with a selector added across runs. Serve
locally while a run is in flight — the page regenerates every 30 s and
re-resolves which run is newest, so it picks up a run that started
after the server did. Published runs are frozen and stop polling.

## Versions

| Target | |
| --- | --- |
| `version-check` | Upstream releases vs published wheels vs our pins |
| `version-scrub` | Regenerate the version tables from `rocm-bake.hcl` |
| `version-scrub-check` | Fail if those generated tables are stale |

`version-check` needs the network. `version-scrub` reads
`rocm-bake.hcl` and nothing else, which is what lets
`version-scrub-check` gate every pull request; the tables it generates
live between `<!-- BEGIN VERSIONS -->` markers in `README.md` and in
[Bake variables](bake-variables.md).

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
| `clean-cache` | Drop locally-pulled cache images; Zot garbage-collects its own store |
| `setup` | `zot-check` then `builder-setup` |

## Variables Worth Knowing

| Variable | Default | |
| --- | --- | --- |
| `FLEET` | `snoc` | Which `manifests/<name>.yml` describes the fleet |
| `FLEET_MANIFEST` | — | A manifest path directly, instead of `FLEET` |
| `BUILDER` | the manifest's `default_builder` | Which builder, or the pool sentinel for the balancer |
| `ARCHES` | `gfx950 gfx1201 gfx1250` | What `arches-*` fans out over |
| `PYTORCH_ROCM_ARCH` | `gfx950` | The architecture for **one** build |
| `TELEMETRY` | `1` | `0` skips the metrics wrapper |
| `BAKE_EXTRA` | — | Arbitrary extra flags passed to bake |
| `GPU_HOST` | the manifest's `gpu_node` | The machine with `/dev/kfd`; empty on a build-only fleet |
| `REPO` | `rocm-pytorch/base` | What `zot-tags` lists |
| `ZOT_TAGS` | `5` | Tags per repo in `zot-wheels`; `0` for all |
| `BENCH_SCENARIO` | `all` | Which benchmark scenario `make bench` runs |

!!! warning "Some variables only work from the environment"
    `make <target> VAR=value` works for anything the Makefile reads.
    But `SCCACHE_LOG`, `PUBLISHED_INPUTS`, `RUN_ID`, `CACHE_TAG_SUFFIX`
    and the `SDE_*` overrides are read by **bake**, from the
    environment — so they need `VAR=value make <target>` instead.
