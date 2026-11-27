# Notes for agents working in this repo

Hard-won things that are not obvious from the code, and that have each
cost a wrong build, a wrong answer, or a wrong claim. Written for an
agent picking this repo up cold. Add to it when something bites.

The repo's own prose is the better reference for *why* a thing is the
way it is: the Dockerfiles, `rocm-bake.hcl` and `serving/*.yml` carry
long comments that record measurements, not intentions. Read the
comment next to the line before changing the line.

## Working agreements

- **Propose fleet commands, don't run them unasked.** `make push-*`,
  `make perf-*` and `make serve-*` occupy the whole fleet for minutes
  to hours and push to the registry. Print the command and stop, unless
  the user has asked for that specific run. Read-only inspection (curl
  against Zot, `--print`, `--call=check`, reading logs) needs no
  ceremony.
- **Never commit.** Write the message to
  `/tmp/<repo>-commit-msg.txt` and show the `git commit -s -S -F …`
  command. Commits are GPG-signed; never pass `--no-gpg-sign` or
  `--no-verify`.
- **Report what happened, not what was supposed to happen.** A build
  that exits 0 having exported to the wrong daemon is a failure; say
  so.

## The fleet

| Node | GPU | Role |
| --- | --- | --- |
| `snoc-strix` | gfx1151, Radeon 8060S, unified memory | registry (Zot), sccache, builder, 122 GB RAM |
| `snoc-think` (ssh: `snoc-thinkstation`) | gfx1201, RX 9070 XT, 16 GB VRAM | builder, 122 GB RAM |
| `snoc-gaming` | gfx1201 | builder |

`manifests/snoc.yml` is the source; `make list-nodes` prints it.

**`snoc-strix` is an APU and its split is a BIOS setting, not a fixed
property of the board.** It was 96 GB carved out as VRAM with 30 GB
left to the CPU. It is now almost all given to the CPU — 122 GB of
system RAM, 512 MB of dedicated VRAM — and the GPU allocates what it
needs from there through GTT, which `/sys/class/kfd` reports as about
61 GiB available to the device. Check it rather than assume it:

```sh
free -g                               # what the CPU has
rocm-smi --showmeminfo vram           # what is dedicated (small now)
```

That change is recent, so **anything in this repo that reasons from
"snoc-strix has 30 GB" is describing a machine that no longer
exists** — including the measurements behind `MEM_RESERVE_GB` in
`Dockerfile.vllm` and the Triton note about dying at 32 jobs. Those
numbers were real when taken and are still a safe lower bound; they
are no longer a description of this node.

The old asymmetry note said the node with the big GPU had the small
RAM. That is no longer true, and nothing should be scheduled on the
assumption that it is.

## Builds

- **`rocm-bake.hcl` is the only source of versions.** No Dockerfile may
  default `ROCM_VERSION`; each asserts it was passed. `make
  version-scrub` regenerates the tables in `README.md` and
  `docs/reference/bake-variables.md`, and lint fails on drift.
- **`PUBLISHED_INPUTS=1` changes what a build reads.** Targets then
  take their inputs as registry refs by tag rather than as bake
  targets, so a changed Dockerfile upstream is *not* rebuilt — the tag
  is the same and the old image is pulled. `make perf-*` runs this way.
  After changing a base image, rebuild and push it explicitly
  (`make push-rocm-runtime`, `push-base`) or the measured run will
  silently use the old one.
- **Memory, not cores, bounds the compiles.** Each Dockerfile derives
  `MAX_JOBS` from `MemAvailable`. `Dockerfile.vllm` additionally holds
  back `MEM_RESERVE_GB` because about 10 GB of its HIP compile arrives
  in one burst whatever the job count. A 30 GB node has hung on this;
  there was no OOM kill, the node thrashed and had to be reset.
- **Wheel images are `FROM scratch`.** They carry `/wheels` and, for
  `nixl-wheel`, `/nixl-dev`. They have no shell: inspect them by
  `COPY --from=` or by bind-mounting into another stage.
- **MORI without `BUILD_UMBP=ON` builds, imports, and is useless.**
  Upstream defaults it off, and with it off the wheel simply has no
  `mori/umbp_master` and no `mori/umbp_standalone_server` — the two
  processes the `mori` image exists to run. Nothing else notices.
  `Dockerfile.mori` unpacks the wheel and asserts both are there.
- **MORI's job count is `PYTHON_CPU_COUNT`, not `MAX_JOBS`.** Its
  `setup.py` runs `cmake --build . -j {os.cpu_count()}`, so the count
  is baked into the argument before `MAX_JOBS` or
  `CMAKE_BUILD_PARALLEL_LEVEL` could be read. Python 3.13's
  `PYTHON_CPU_COUNT` changes what `os.cpu_count()` returns and is the
  only lever that reaches it.
- **A binary that links ROCm's `rocm_sysdeps` libraries will not
  load.** `/opt/rocm/lib/rocm_sysdeps/lib` is on no loader path in our
  base — no `ld.so.conf.d` entry, not in `LD_LIBRARY_PATH`, invisible
  to `ldconfig`. ROCm's own libraries reach it through `$ORIGIN`
  RPATHs; anything built outside the ROCm tree does not. Naming
  `rocm_sysdeps` in `CMAKE_PREFIX_PATH` is what causes it, because
  `find_package` then resolves zlib and libnuma to ROCm's renamed
  copies. `Dockerfile.mori` adds the `ld.so.conf.d` entry in both its
  stages; adding the whole directory is safe because 36 of its 37
  sonames carry a `librocm_sysdeps_` prefix and the odd one,
  `libiberty.so.0`, has no system counterpart here.
- **UMBP is one medium per node, and tiering needs RDMA we do not
  have.** It is not LMCache's L1/L2: a node serves DRAM *or* SSD, and
  setting `UMBP_SSD_ENABLED` without `UMBP_DISTRIBUTED_MEDIUM` is
  refused at startup. More than one medium means a master plus
  per-medium nodes, and that path demands `UMBP_IO_ENGINE_HOST` and
  then dies with "no active RDMA device on this host". Forcing
  `MORI_DISABLE_AUTO_XGMI=0` makes the node hang silently instead --
  running, no socket, no log. A single DRAM node is the whole of what
  this fleet supports. Do not spend an afternoon on the SSD tier.
- **The UMBP pool pins an engine's VRAM and does not release it.**
  Workers register GPU KV allocations with `umbp_standalone_server`
  over HIP IPC, and killing the engine does not hand them back:
  measured 4.88 GiB still held 60s after the vLLM container was
  removed, on a 15.92 GiB card, freed only by restarting the pool.
  A vLLM restart against a live pool then fails on
  "Free memory on device cuda:0 ... is less than desired GPU memory
  utilization". Leave headroom, or restart the pool in the loop.
- **`/reset_prefix_cache` is 404 on vLLM 0.34.0 even with
  `VLLM_DEV_MODE=1`.** So the LMCache-style "store then re-ask the
  same engine" cache test silently measures VRAM instead. Prove a
  second tier by restarting the engine against a surviving pool and
  reading the connector's `operation="load"` counters.
- **A `manylinux` tag does not cover those libraries.**
  `auditwheel-rocm.sh` excludes every ROCm-only soname from the policy
  calculation as well as from vendoring, so a wheel can be
  `manylinux_2_39` and still need `librocm_sysdeps_z.so.1`.
- **MORI builds on RDNA even though upstream does not claim it.**
  Measured 2026-11-26 on snoc-think: gfx950 and gfx1201 both produce a
  wheel with 13 extensions, one offload bundle for the arch asked for,
  and both UMBP binaries resolving. Only one or two of the 140 compile
  requests are HIP, so there is very little arch-specific code to go
  wrong. **This is a build result, not a runtime one** — nothing here
  has executed MORI on a GPU, upstream still lists only MI300-class
  hardware, and its RDMA paths want an IBGDA NIC this fleet lacks. No
  build gate is needed; do not read that as support.

## The registry (Zot, on snoc-strix)

- **Anonymous read, authenticated write.** `GET /v2/_catalog` works
  from anywhere on the tailnet; a push needs the `ci` credential.
- **That credential is in `pass`, encrypted to a smartcard GPG key.**
  When the card is absent, `docker-credential-pass get` fails and every
  push is a 401 — see `docs/operations/troubleshooting.md`. Nothing an
  agent can fix; say so and stop.
- **With a remote builder, the *client* supplies push credentials.**
  snoc-think can reach the registry perfectly well and still cannot
  push, because buildx forwards auth from the machine driving the
  build.
- **`make serve-load` is the way round it.** It builds `vllm` and
  `lmcache` straight into `GPU_HOST`'s docker daemon with `--load`, as
  `emu-load` and `cpu-load` already do for their lanes. Serve what it
  loads with `PULL_POLICY=never`, or compose's `pull_policy: always`
  pulls the registry's older image over the top and reports nothing.

## Public wheels (GitHub releases + gh-pages)

- **A published release asset is never replaced or deleted.** Each
  build is its own release, `wheels-<rocm>-<arch>-<YYYYMMDD>`.
  `wheelpublish.sh` uploads nothing when the wheels match the newest
  release and refuses a tag that holds different ones; do not reach
  for `--clobber` or `gh release delete-asset` to get past it. People
  install from those URLs by hash.
- **gh-pages has no history.** `docs.yml` force-pushes an orphan
  commit on every deploy, so nothing can be recovered from that
  branch, and a deploy racing a publish discards it silently. The
  releases are the record: each carries a `manifest.json`, and
  `make wheels-reindex` rebuilds every index page from them.
- **`wheels-publish`, `wheels-reindex`, `emu-publish` and
  `cpu-publish` write to the public site.** Same agreement as the
  fleet commands: propose, or run the `-dry` form.
- **The weekly is a cron string compared in two places.**
  `nightly.yml` decides it is Sunday by matching
  `github.event.schedule` against the literal `'17 2 * * 0'`. Change
  the schedule and the comparison together, or the weekly silently
  becomes a nightly: one architecture, nothing published.

- **A CodeBuild runner is requested once, by a webhook, and the
  account takes one queued build.** GitHub sends
  `workflow_job.queued` once per job; CodeBuild answers it by starting
  a build. With one build running and one queued, every further
  request is refused outright — *"Cannot have more than 1 builds in
  queue for the account"* — and never retried, so that job waits for a
  runner that is not coming until GitHub gives up, about fifteen
  hours later, holding its concurrency group.
  **`strategy.max-parallel` does not help**: it limits how many legs
  run, not how many are announced, and all four webhooks go out under
  it. Only `needs` delays the announcement. That is why the weekly's
  architectures are a chain of jobs in `nightly.yml` calling
  `nightly-build.yml`, not a matrix, and why `check-contracts.py`
  asserts the chain matches `ARCHES`. A matrix is still right for jobs
  on `instance-size:small`, whose quota is thirty.

## Make macros

- **The `bake` macro's recipe starts with `@echo … ; \`.** A shell
  variable written *before* `$(call bake,…)` therefore attaches to that
  first command and never reaches `docker buildx bake`. This produced a
  `--load` that exported to the local daemon while claiming to target a
  remote host, and exited 0. Pass environment through the macro's
  fourth argument instead:

      $(call bake,vllm lmcache,--load,,DOCKER_HOST=ssh://$(GPU_HOST))

- **Recipes that end in `rm -rf` hide the exit status of what came
  before.** `wheel-index-check` cannot fail for this reason, which is
  how a wheel index that could not be installed shipped unnoticed.
  Check such a target by hand before trusting a green run.

## Serving

- **Two containers, one IPC namespace.** `lmcache` owns it, `vllm`
  joins with `ipc: service:lmcache`. `HSA_ENABLE_IPC_MODE_LEGACY=1` is
  what makes cross-container KV transfer work on this fleet; the
  compose file records what each value breaks.
- **`make serve-test` is the check that the cache is live**, not
  `/health`. LMCache can serve every request correctly and cache
  nothing, with no error anywhere. The test reads LMCache's own store
  and retrieve counts.
- **`VLLM_DEV_MODE=1` is required for an honest cache test.** Without
  it `/reset_prefix_cache` is absent, vLLM answers the second request
  from VRAM, and LMCache is never asked — which reads as "stored but
  served none".
- **A 16 GB card cannot fit the defaults.** vLLM's 0.90 utilisation
  plus 4 GB of graph capture leaves nothing for the KV cache with
  Qwen2.5-3B. Use `GPU_UTIL=0.70 VLLM_EXTRA_ARGS=--enforce-eager`.
  About 4 GB is also missing from vLLM's view of free memory at startup
  on both ROCm 10.1 and 10.2 — unexplained, and not from the LMCache
  container, the runtime, imports or the IPC setting.
- **`KV_TIER` selects the L2 adapter**: `cpu` (L1 only), `file`
  (LMCache's own filesystem adapter), and `nixl-native`,
  `nixl-dynamic`, `nixl-store` (NIXL's POSIX plugin through each of
  LMCache's three NIXL adapters). `nixl_store` is a fixed pool whose
  `file_size` defaults to one L1 page: sized wrong it fails every store
  with "Insufficient NIXL storage capacity" while L1 keeps working, so
  the stack looks healthy.

## Things that look like bugs and are not

- **`import_utils.py:417` tracebacks in the vLLM log.** vLLM probes for
  `nixl_ep` (a CUDA module), fails, warns and continues.
- **Images dated "3 years ago".** `SOURCE_DATE_EPOCH` pins the created
  timestamp for reproducibility.
- **`make version-check` saying a pin is *ahead* of upstream.** It
  compares against the newest tag that passes the strict semver
  filter, and that filter drops release candidates on purpose
  (LMCache and aiter flag theirs as full releases). So a pin
  deliberately on an rc outranks the newest release and reads as
  "ahead". Known limitation, written up at the end of `status_of()`
  in `versioncheck.py`; `--bump` does not move an "ahead" row.
- **`base-cache:latest-<arch>-ref: not found`.** The frozen cache tier
  does not exist for that arch yet; the build carries on.
- **`no lookup ipc key` in the LMCache log.** Normal for the first
  lookup of a session. It is only the LMCache#4419 signature when it is
  *all* you ever see, with no stores.

## ROCm 10.2 specifics

- **LLVM's `libgomp.so` alias is on clang's search path.** 10.2 moved
  the runtime libraries into `llvm/lib/x86_64-unknown-linux-gnu`, which
  clang searches implicitly, and that directory has a `libgomp.so` that
  is really `libomp`. A GCC link that includes HIP objects picks it up,
  and the result needs `libomp.so` at run time. `rocm-prune.sh` removes
  the alias; the toolchain check in `Dockerfile.rocm-runtime` fails the
  build if it returns.
- **Package names carry the version**: `amdrocm-core-sdk10.2-gfx1201`.
  `rocm-prune.sh` matches on the `-gfxNNNN` suffix, so it is
  version-agnostic — but check that a new ROCm still ships packages for
  an architecture before assuming it builds.
