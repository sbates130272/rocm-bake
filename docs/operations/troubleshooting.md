# Troubleshooting

Failures that have actually happened here, with the line that
identifies each one.

## The Registry

### Connection Refused

```bash
systemctl status zot              # bare metal, not a container
sudo journalctl -u zot -n 50
curl -s http://snoc-strix.fold-leaffish.ts.net:8080/v2/_catalog
make zot-check
```

### Two Failures That Look Similar From A Build Log

| Log line | Cause |
| --- | --- |
| `no such host` | The builder cannot resolve the tailnet name. It was created without `--driver-opt network=host`, so Docker gave it the upstream resolver instead of the host's MagicDNS one. |
| `http: server gave HTTP response to HTTPS client` | DNS is fine but the client will not speak plain HTTP. For the Docker daemon, check `insecure-registries` in `/etc/docker/daemon.json`; for BuildKit, confirm the builder was created from the fleet manifest with `make builder-<node>` rather than by hand — a builder created with no `--config` has no `[registry]` block. |

Both settings are fixed at builder-create time, so the fix is always
`docker buildx rm <name>` then `make builder-<name>` — editing the toml
does nothing to an existing builder. If pushes get 401, `docker login`
as `ci`.

### Push Dies At Exactly 60 Seconds

Zot's default HTTP read timeout is 60 s, measured across the whole
request body. The ROCm base image has a single 8.67 GB layer, which
cannot cross a 1 Gb/s link in under ~73 s, so every push failed at the
60 s mark. The client-side error is a connection reset, which reads like
a network fault; the giveaway is Zot's own log:

```
PUT /v2/.../blobs/uploads/...  statusCode: 500  latency: "1m0s"
error: "read tcp ...: i/o timeout"   Content-Length: 8672333352
```

`/etc/zot/config.json` needs `"readTimeout": "30m"` and
`"writeTimeout": "30m"` under `"http"`, then a restart; that layer then
pushes in ~200 s. Zot is deployed from outside this repository, so the
setting belongs in whatever provisions it, or it reverts.

## The Compiler Cache

The build refuses to start when the store is unreachable, so a silent
no-cache build should not happen. If it does:

```bash
make cache-summary    # endpoint, size, disk, deltas and hit rates
make cache-check      # can every node reach it?
make cache-logs       # the WebDAV access log
```

Run `cache-summary` twice a minute apart during a build — the interval
line is the one that matters. The hit-rate column comes from the
telemetry textfile, not the store: WebDAV has no stats verb.

### Three Failure Modes With Distinct Signatures

| Log line | Cause |
| --- | --- |
| `No such file or directory` on a source path | The client reached a server outside its own container. Structurally impossible now that the server is addressed over a unix socket, but this is what it looked like. |
| `cache storage failed to read … I/O error` | The store's address did not resolve. Check the `[dns]` block in `.builders/buildkitd.toml.in`, and that the Makefile resolved `WEBDAV_IP` — build containers address the store by IP, not by name. |
| `Cache write errors` climbing | The store's filesystem is full. `make cache-summary` shows the disk line. |

`SCCACHE_LOG=debug` reveals what sccache's "Cache errors" counter is
counting; it is not the default because debug logs every lookup, and a
cold Triton does 361 of them. After changing the buildkitd config:
`docker buildx rm snoc-strix && make builder-snoc-strix`.

## The Build

### "HIP Not Found"

```bash
rocm-smi --showversion     # are the ROCm modules loaded?
ls -la /dev/kfd /dev/dri   # is the GPU visible?
```

Compiling for an architecture does not need a GPU; this matters only
for `make test` and `make gpu-test`.

### A Build Fails At The Last Target, Every Time

`pytorch-test` has found its way into a group. It cannot run inside the
build graph: its stage exits 1 when `torch.cuda.is_available()` is
false, and a BuildKit `RUN` step has no `/dev/kfd`. Use `make test`.

### AITER's Wheel Build Exits 1 After ~51 Minutes

On RDNA. Every kernel compiles and the build then fails in the JIT
module phase: six of 68 modules carry CDNA-only code and `setup.py`
treats a failure as fatal. The default is level 0 everywhere, so this
means `PREBUILD_KERNELS` has been pinned to 2 — a pin only safe on
CDNA. See [Multiple GFX targets](../architecture/multi-arch.md).

### A Build Is Wedged

```bash
make build-stop        # cancel builds started from this repo
make builder-restart   # restart buildkitd on $(BUILDER)
```

`builder-restart` drops that node's in-memory build state. The registry
layer cache and the shared compiler cache are untouched, so the next
build still picks up where it can.

A build cancelled by `build-stop` is recorded by BuildKit as `Error`
with no detail, indistinguishable from a real failure. `make build-watch`
reads a stop file so it can label those correctly.

### Alternating Architectures Are Both Always Cold

Fixed by `CACHE_ARCH`; if it recurs, check that the target actually
scopes its cache ref by architecture. `triton-wheel` deliberately does
not, because it compiles no device code.

### Insufficient Disk Space

```bash
docker system df
docker system prune -a
```

Remember the BuildKit store is bounded by `gckeepstorage = "100GB"` per
node and is shared with the other project on these builders.

## Telemetry

### No Metrics Appeared

```bash
./telemetry/build.sh --builder snoc-strix pytorch   # run it directly
docker buildx history ls --builder snoc-strix       # is there history to read?
```

Metrics land in `telemetry/out/` when the node_exporter directory is
not writable — the wrapper says so. sccache counters are absent when a
target was fully layer-cached: the build step never ran, so it printed
no stats.

## Benchmarks

### A Frozen Run Is Recorded As `frozen*`

The registry eviction was refused, so the run was really cold — Zot
needs deletes enabled. Such rows are excluded from every published
ratio.

### The Harness Exits Immediately Saying A Build Is Running

By design: two builds on one node contend for cores and memory. It
exits 0 so it is safe to drive from cron; `make build-status` shows what
is running.

### Results Look Implausible

Check the job count: the same cold PyTorch is 6892 s at 5 jobs and
2342 s at 32, and a ratio is only printed when both sides were measured
at the same width. `BENCH_MAX_JOBS` pins it.

## The Serving Stack

### The Endpoint Is Healthy But Nothing Is Cached

`/health` is not evidence. Run `make serve-test`, which requires the
second prefill of a repeated prefix to be measurably cheaper *and* reads
LMCache's own log for the store and the retrieve.

### The Stack Fails At Startup

Check `HSA_ENABLE_IPC_MODE_LEGACY`. It decides whether the two
containers can share KV memory at all, and no amount of `TRANSFER_MODE`
tuning will work around it.

### A Pull Fails Naming A Plausible-Looking Tag

The serving tag comes from `GPU_HOST`'s architecture, not the build
default — `make list-vars` prints the resolved `SERVE_ARCH`. If the host
is unreachable it falls back to the build architecture, which may be an
image nobody has built.

### `import torchvision` Fails

This should no longer happen: `torchvision-wheel` builds torchvision
against this torch and `Dockerfile.vllm` installs it. If it does, the
ROCm wheel has been replaced by PyPI's CUDA build somewhere — check
what is actually installed:

```bash
python -c "import torchvision; print(torchvision.__version__)"
```

A version with no `+rocm` local segment is the CUDA wheel.
`/etc/pip-constraints.txt` exists to make that resolution fail loudly
rather than succeed, so also check that `PIP_CONSTRAINT` is still set
in the container and that the constraints file still has a
`torchvision==` line. See
[Serving stack](../architecture/serving.md#three-upstream-constraints).

## Everything Is Slow And Nothing Is Obviously Broken

In order:

1. `make builder-logs` — a registry, DNS or cache fault shows up here
   while the build merely looks slow.
2. `make cache-summary`, twice a minute apart. A flat object count
   during a compile means the compiler cache is not being written.
3. `make layer-summary` — a target that moved nodes must refetch from
   the registry.
4. `make builder-load` — something else may be on the node.
