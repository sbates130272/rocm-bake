# Operations

Day-to-day running of the fleet.

## Routine

```bash
make push-all BUILDER=snoc-pool    # build and publish everything, scheduled
make watch                         # follow it from a second terminal
make layer-summary                 # how much of each image was rebuilt
make cache-summary                 # is the compiler cache taking objects?
```

`push-all` with the pool sentinel is the usual way to build. Everything
else is diagnosis.

## Health checks

```bash
make zot-check        # registry active and answering
make cache-check      # every node can reach the compiler cache
make builder-health   # which builders can take work
make builder-status   # all builders and their nodes
make builder-load     # CPU, cores and load per node
make version-check    # are any upstream pins behind?
```

`builder-health` is what `builder-ensure` gates every build target on,
so a build against a dead node fails fast rather than hanging. It
reports `running`, `inactive` or `error` per node.

## Continuous integration

Four workflows, all on GitHub-hosted runners. None of them builds a real
image — the images need this fleet — so CI validates structure and
agreement rather than output.

**`CI — Dockerfile & bake validation`** runs on pull requests and pushes
to `main`, path-filtered to the build files. It enumerates the bake
targets out of `rocm-bake.hcl` into a matrix and, for each one, checks
that `bake --print` resolves, that the Dockerfile it names exists, and
that its cache ref and its tags agree about the architecture. It also
builds two architectures' pip indexes and asserts each installs its own
and only its own, runs `check-defaults.py`, validates the serving
compose file and that the services the Makefile drives still exist, and
HCL-lints the bake file.

**`Lint & spelling`** runs codespell, shellcheck at `-S warning`,
hadolint over `docker/Dockerfile.*`, actionlint and yamllint over
`.github/`, and ruff `--select E,F` plus `py_compile` over every tracked
Python file. It also runs `make version-scrub-check`, which fails if the
generated version tables in `README.md` and the docs have drifted from
`rocm-bake.hcl`. That gate lives here rather than in `ci.yml` because
`ci.yml` is path-filtered to the build files — `README.md` and `docs/`
are not in that list, so a pull request that hand-edited the table would
have run no job at all.

`ci.yml` also renders a synthetic perf report and asserts every SVG is
well-formed, that timeline spans do not overlap, that labels fit their
bars, and that a partial run degrades rather than crashes — then runs
`check-contracts.py` over the
[producer/parser pairs](../performance/perf-runs.md#contracts).

**`Build & push — ROCm PyTorch`** is `workflow_dispatch` only.

**`Version check — upstream releases`** runs Mondays. It runs
`.builders/versioncheck.py --markdown --no-zot` — the same script
`make version-check` runs here, so the weekly report and the one an
operator runs cannot disagree — and opens or comments on a single
tracking issue when a pin is behind upstream. The published-wheels
column is skipped there: the registry is a tailnet name a GitHub runner
cannot resolve, and an empty column would read as "we have published
nothing".

**`Docs`** builds this site and deploys it to the `gh-pages` branch on
every push to `main` that touches `docs/` or `mkdocs.yml`. It preserves
the `data/` directory already on that branch, because that is where
[the published benchmark results](../performance/index.md#publishing)
live and they are written from a build node, not from CI.

## Cleaning up

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

## When something is wrong

[Troubleshooting](troubleshooting.md) covers the failures that have
actually happened on this fleet, with the log line that identifies each
one.
