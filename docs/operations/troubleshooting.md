# Troubleshooting

Failures that have actually happened here, with the line that
identifies each one.

## The registry

### Connection refused

```bash
systemctl status zot              # bare metal, not a container
sudo journalctl -u zot -n 50
curl -s http://snoc-strix.fold-leaffish.ts.net:8080/v2/_catalog
make zot-check
```

### Two failures that look similar from a build log

| Log line | Cause |
| --- | --- |
| `no such host` | The builder cannot resolve the tailnet name. It was created without `--driver-opt network=host`, so Docker gave it the upstream resolver instead of the host's MagicDNS one. |
| `http: server gave HTTP response to HTTPS client` | DNS is fine but the client will not speak plain HTTP. For the Docker daemon, check `insecure-registries` in `/etc/docker/daemon.json`; for BuildKit, confirm the builder was created with `--config .builders/buildkitd-strix.toml`. |

Both settings are fixed at builder-create time, so the fix is always
`docker buildx rm <name>` then `make builder-<name>`. Editing the toml
does nothing to an existing builder. Inspect with
`docker buildx inspect <name>`.

If pushes get 401:
`docker login snoc-strix.fold-leaffish.ts.net:8080 -u ci`.

### Push dies at exactly 60 seconds

Zot's default HTTP read timeout is 60 s, measured across the whole
request body. The ROCm base image has a single 8.67 GB layer, which
cannot cross a 1 Gb/s link in under ~73 s, so every push of it failed at
the 60 s mark: Zot discarded the partial upload and returned 500, and
BuildKit retried with backoff.

The client-side error is a connection reset, which reads like a network
fault rather than a timeout. The giveaway is Zot's own log:

```
PUT /v2/.../blobs/uploads/...  statusCode: 500  latency: "1m0s"
error: "read tcp ...: i/o timeout"   Content-Length: 8672333352
```

`/etc/zot/config.json` needs:

```json
"http": {
  "readTimeout": "30m",
  "writeTimeout": "30m"
}
```

then `sudo systemctl restart zot`. That layer then pushes in ~200 s.

Zot is deployed from outside this repository, so the setting belongs in
whatever provisions it, or it reverts on the next deploy.

## The compiler cache

The build refuses to start when the store is unreachable, so a silent
no-cache build should not happen. If it does:

```bash
make cache-summary    # endpoint, size, disk, deltas and hit rates
make cache-check      # can every node reach it?
make cache-logs       # the WebDAV access log
```

Run `cache-summary` twice a minute apart during a build: the interval
line is the one that matters. The store itself cannot report a hit rate
— WebDAV has no stats verb — so that column is read back out of the
telemetry textfile, per target, from the last build of each.

### Three failure modes with distinct signatures

| Log line | Cause |
| --- | --- |
| `No such file or directory` on a source path | The client reached a server outside its own container. Structurally impossible now that the server is addressed over a unix socket, but this is what it looked like. |
| `cache storage failed to read … I/O error` | The store's address did not resolve. Check the `[dns]` block in `.builders/buildkitd-strix.toml`, and that the Makefile resolved `WEBDAV_IP` — build containers address the store by IP, not by name. |
| `Cache write errors` climbing | The store's filesystem is full. `make cache-summary` shows the disk line. |

`SCCACHE_LOG=debug` reveals what sccache's "Cache errors" counter is
actually counting; it is not the default because debug logs every
lookup, and a cold Triton does 361 of them.

Builder settings are fixed at create time, so after changing the
buildkitd config:

```bash
docker buildx rm snoc-strix && make builder-snoc-strix
```

## The build

### "HIP not found"

```bash
rocm-smi --showversion     # are the ROCm modules loaded?
ls -la /dev/kfd /dev/dri   # is the GPU visible?
```

Note that compiling for an architecture does not need a GPU. This
matters only for `make test` and `make gpu-test`.

### A build fails at the last target, every time

If `pytorch-test` has found its way into a group: it cannot run inside
the build graph at all. Its stage exits 1 when
`torch.cuda.is_available()` is false, and a BuildKit `RUN` step has no
`/dev/kfd`. Use `make test` on a GPU node instead.

### AITER's wheel build exits 1 after ~51 minutes

On RDNA. Every kernel compiles and the build then fails in the JIT
module phase: six of 68 modules carry CDNA-only code and `setup.py`
treats a failed module as fatal. The build should have selected
`PREBUILD_LEVEL=0` — check that `PREBUILD_KERNELS` has not been pinned
to 2 in the environment. See
[Multiple GFX targets](../architecture/multi-arch.md).

### A build is wedged

```bash
make build-stop        # cancel builds started from this repo
make builder-restart   # restart buildkitd on $(BUILDER)
```

`builder-restart` drops that node's in-memory build state. The registry
layer cache and the shared compiler cache are untouched, so the next
build still picks up where it can.

A build cancelled by `build-stop` is recorded by BuildKit as status
`Error` with no detail, which is indistinguishable from a real failure.
`make watch` reads a stop file so it can label those correctly rather
than showing a red "error" for something you stopped on purpose.

### Alternating architectures are both always cold

Fixed by `CACHE_ARCH`, but if it recurs: check that the target in
question actually scopes its cache ref by architecture.
`pytorch-base` and `triton-wheel` deliberately do not, because neither
compiles device code.

### Insufficient disk space

```bash
docker system df
docker system prune -a
```

Remember the BuildKit store is bounded by `gckeepstorage = "100GB"` per
node and is shared with the other project on these builders.

## Telemetry

### No metrics appeared

```bash
./telemetry/build.sh --builder snoc-strix pytorch   # run it directly
docker buildx history ls --builder snoc-strix       # is there history to read?
```

Metrics land in `telemetry/out/` instead of the node_exporter directory
when that directory is not writable — the wrapper says so when it falls
back.

sccache counters are absent when a target was fully layer-cached: the
build step never ran, so it printed no stats. That is correct.

## Benchmarks

### A frozen run is recorded as `frozen*`

The registry eviction was refused, so the run was really a cold run.
Zot needs deletes enabled. Such rows are excluded from every published
ratio rather than averaged in.

### The harness exits immediately saying a build is running

By design — two builds on one node contend for cores and memory, and
every timing would be meaningless. It exits 0 so it is safe to drive
from cron. `make build-status` shows what is running.

### Results look implausible

Check the job count. The same cold PyTorch is 6892 s at 5 jobs and
2342 s at 32, and the harness only prints a ratio when both sides were
measured at the same width. `BENCH_MAX_JOBS` pins it. See
[Methodology](../performance/methodology.md).

## The serving stack

### The endpoint is healthy but nothing is cached

`/health` is not evidence. Run `make serve-test`, which requires the
second prefill of a repeated prefix to be measurably cheaper *and* reads
LMCache's own log for the store and the retrieve.

### The stack fails at startup

Check `HSA_ENABLE_IPC_MODE_LEGACY`. It decides whether the two
containers can share KV memory at all, and no amount of `TRANSFER_MODE`
tuning will work around it.

### A pull fails naming a plausible-looking tag

The serving tag comes from `GPU_HOST`'s own architecture, not the build
default. `make list-vars` prints the resolved `SERVE_ARCH`, `VLLM_TAG`
and `LMCACHE_TAG`. If the host is unreachable, `SERVE_ARCH` falls back
to the build architecture — which may well be an image nobody has
built.

### `import torchvision` fails

Known and not fixed here. torchvision is a CUDA wheel in these images;
nothing in the text-model serving path touches it, but vision and video
models will fail at serve time. See
[Serving stack](../architecture/serving.md#three-upstream-constraints).

## Everything is slow and nothing is obviously broken

In order:

1. `make builder-logs` — a registry, DNS or cache fault shows up in the
   daemon's log while the build itself merely looks slow.
2. `make cache-summary` — twice, a minute apart. If the object count is
   not moving during a compile, the compiler cache is not being written.
3. `make layer-summary` — a target that moved nodes cannot use the
   previous node's local BuildKit cache and must refetch from the
   registry.
4. `make builder-load` — something else may be on the node.
