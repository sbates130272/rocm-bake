# Operations

Day-to-day running of the fleet.

## Routine

```bash
make push-all BUILDER=snoc-pool    # build and publish everything, scheduled
make build-watch                   # follow it from a second terminal
make layer-summary                 # how much of each image was rebuilt
make cache-summary                 # is the compiler cache taking objects?
```

`push-all` with the pool sentinel is the usual way to build. Everything
else is diagnosis.

## Health Checks

```bash
make fleet-check      # the whole fleet, against what the manifest claims
make zot-check        # registry active and answering
make cache-check      # every node can reach the compiler cache
make builder-health   # which builders can take work
make builder-status   # all builders and their nodes
make builder-load     # CPU, cores and load per node
make version-check    # are any upstream pins behind?
```

`fleet-check` is the one to run first: it asks every node in
[the manifest](../architecture/fleet.md) whether it can reach the
registry, read *and write* the compiler cache, and export metrics. The
targets under it ask one of those questions each.

`make fleet-apply` is the other half — it makes a node match the
manifest rather than reporting that it does not. Run it when the fleet
is idle: it can restart `dockerd`, stopping every container on the node
including a builder mid-build. `builder-health` is what `builder-ensure`
gates every build target on, so a build against a dead node fails fast
rather than hanging.

## Continuous Integration

Five workflows. Every pull-request check runs on a GitHub-hosted runner
and builds no real image — the images need a build fleet — so the PR
gate validates structure and agreement rather than output.

The exception is the nightly, which does build: a warm run per
architecture on AWS CodeBuild, published to ECR, reported as a GitHub
issue and to
[data/nightly/](https://sbates130272.github.io/rocm-bake/data/nightly/).
SNOC runs no CI job at all — it is driven by hand. See
[CI runners](runners.md) and [Building on AWS](aws.md).

**`CI — Dockerfile & bake validation`** runs on pull requests and pushes
to `main`, path-filtered to the build files. It enumerates the bake
targets into a matrix and checks, per target, that `bake --print`
resolves, that the Dockerfile exists, and that the cache ref and the
tags agree about the architecture. It also builds two architectures' pip
indexes and asserts each installs its own and only its own, runs
`check-defaults.py`, validates the serving compose file, HCL-lints the
bake file, renders a synthetic perf report, and runs
`check-contracts.py` over the
[producer/parser pairs](../performance/perf-runs.md#contracts).

**`Lint & spelling`** runs codespell, shellcheck, hadolint, actionlint,
yamllint and ruff, plus `make version-scrub-check`. That last gate lives
here rather than in `ci.yml` because `ci.yml` is path-filtered to the
build files — `README.md` and `docs/` are not in that list, so a pull
request that hand-edited the version table would have run no job at all.

**`Build & push — ROCm PyTorch`** is `workflow_dispatch` only.

**`Version check — upstream releases`** runs Mondays and opens or
comments on a single tracking issue when a pin is behind upstream. It
uses the same `.builders/versioncheck.py` an operator runs, with the
published-wheels column skipped: the registry is a tailnet name a GitHub
runner cannot resolve, and an empty column would read as "we have
published nothing".

**`Docs`** builds this site and deploys it to `gh-pages`, preserving the
`data/` directory already on that branch — that is where
[the published results](../performance/index.md#publishing) live.

## Cleaning Up

```bash
make clean         # built images, locally, for every arch in ARCHES
make clean-cache   # cache images, locally
docker system df   # what is using the disk
docker system prune -a
```

Both `clean` targets are local only. The registry has to be pruned
separately, and `clean-cache` covers only four of the ten cache
repositories.

!!! warning "`docker buildx prune` is fleet-shared"
    These builders are shared with another project. Pruning a node's
    BuildKit store empties its layers too. The
    [frozen benchmark scenario](../performance/index.md#frozen) does
    this deliberately, which is why it is not in the nightly rotation.

## When Something Is Wrong

[Troubleshooting](troubleshooting.md) covers the failures that have
actually happened on this fleet, with the log line that identifies each
one.
