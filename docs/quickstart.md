# Quick start

From nothing to a published PyTorch image. On a fleet that is already
set up, skip to [step 5](#step-5-build).

## Prerequisites

- All nodes on the same Tailscale network.
- `snoc-strix`: a `gfx950` GPU, Docker 27+. Runs the Zot registry, the
  shared compiler cache, and the GPU tests.
- `snoc-thinkstation`, `snoc-gaming`: Docker 27+, reachable as
  `ssh <host>` from Strix. Both are `gfx1201` (RDNA4): they
  cross-compile for `gfx950` fine but cannot run the test stage.
- 200 GB+ of disk per node for the BuildKit cache.

```bash
docker --version
docker buildx version
```

!!! warning "The tailnet must bypass the corporate proxy"
    `HTTP_PROXY` and `HTTPS_PROXY` are set in this environment but
    `no_proxy` is not, so every proxy-aware tool — curl, Python's
    urllib, and the Go binaries including `docker` — tries to reach
    `snoc-*` through ZScaler and fails. The Makefile exports a
    `NO_PROXY_LIST` for its own targets, but anything you run by hand
    needs the same in your shell profile:

    ```bash
    export no_proxy=localhost,127.0.0.1,::1,.ts.net,.local,10.0.0.0/8,100.64.0.0/10
    export NO_PROXY="$no_proxy"
    ```

## Step 1 — Clone

```bash
git clone git@github.com:sbates130272/rocm-bake.git
cd rocm-bake
```

## Step 2 — Check Zot

Zot is the local OCI registry. It holds the published images, the
BuildKit layer cache as OCI artifacts, and a pull-through mirror of
Docker Hub, GHCR and Quay. It already runs on Strix as a bare-metal
systemd service (`zot.service`, configured in `/etc/zot/config.json`),
deployed and owned outside this repository.

!!! danger "Do not start a second one"
    Other services on the fleet pull through the same registry. Nothing
    in this repository starts, stops or configures Zot — the `zot-*`
    targets only inspect it.

```bash
make zot-check      # is it active and answering?
make zot-catalog    # what does it hold?
```

Anonymous read is open, so every pull, pull-through and cache read works
unauthenticated. Only pushing needs the `ci` account from
`/etc/zot/htpasswd`.

Store that credential with `pass`, which is GPG-encrypted at rest and
works over SSH. The `secretservice` helper does not: it fails with
`Cannot create an item in a locked collection` whenever the
gnome-keyring login collection has not been unlocked by a graphical
session.

```bash
sudo apt-get install -y pass golang-docker-credential-helpers
pass init <your-gpg-key-id>        # gpg --list-secret-keys --keyid-format=long
# set "credsStore": "pass" in ~/.docker/config.json
docker login snoc-strix.fold-leaffish.ts.net:8080 -u ci
docker-credential-pass list        # verify it landed
```

One login on Strix covers the whole fleet: buildx sends registry auth
from your local Docker config to the builder as a session attachment, so
builds pushing from think or gaming use it too.

Zot also needs a raised HTTP read timeout, or pushing the ROCm base
fails — its largest layer is 8.67 GB and cannot cross a 1 Gb/s link
inside Zot's 60-second default. In `/etc/zot/config.json`:

```json
"http": {
  "readTimeout": "30m",
  "writeTimeout": "30m"
}
```

then `sudo systemctl restart zot`. See
[Troubleshooting](operations/troubleshooting.md#push-dies-at-exactly-60-seconds)
for what the failure looks like if you skip this.

The registry serves plain HTTP over the tailnet, so the Docker daemon
needs it in `/etc/docker/daemon.json` (already set on Strix):

```json
{
  "insecure-registries": ["snoc-strix.fold-leaffish.ts.net:8080"],
  "registry-mirrors": ["http://snoc-strix.fold-leaffish.ts.net:8080"]
}
```

## Step 3 — Create the builders

```bash
make builder-snoc-strix     # local, gfx950, runs the GPU tests
make builder-snoc-think     # snoc-thinkstation, over SSH
make builder-snoc-gaming    # snoc-gaming, over SSH
make builder-status         # what exists now
```

The remote nodes join over SSH to their Docker daemons: buildx creates
and owns a buildkit container on each, so neither needs buildkitd, TLS
certificates, or the buildx plugin installed.

Every builder is created with `.builders/buildkitd-strix.toml` and
`--driver-opt network=host`. Both are load-bearing:

- the config carries plain HTTP to Zot, the pull-through mirrors, and a
  `[dns]` block, because BuildKit writes its own `/etc/resolv.conf` for
  the build sandbox and defaults it to `8.8.8.8` — without the block a
  `RUN` step cannot resolve any tailnet name;
- `network=host` gives the builder container the host's resolver,
  MagicDNS included. Docker strips loopback nameservers when it writes a
  bridged container's `resolv.conf`.

!!! warning "Both are fixed at create time"
    An existing builder does not pick up edits to the toml. After
    changing it: `docker buildx rm snoc-strix && make builder-snoc-strix`.

## Step 4 — Deploy the shared compiler cache

Every build container runs its own sccache server, and all of them share
one object store: nginx with the WebDAV modules, serving a plain
directory tree on Strix at `:8081`. An object compiled on any node is a
hit on the others.

```bash
sudo ./.builders/deploy-webdav.sh
make cache-check                 # can every node reach it?
make cache-summary               # endpoint, size, disk, deltas, hit rates
```

!!! info "Why a durable store, and why WebDAV"
    The store has to survive a reboot. An in-RAM store loses the whole
    fleet's compiler cache on a power cycle, and an overflow tier does
    not help — it is not durable storage and is never read back at
    startup. A plain directory tree survives, can be backed up with
    rsync, and is bounded only by the filesystem.

    WebDAV rather than S3/MinIO because `dl.min.io` is blocked by the
    corporate proxy and MinIO is not packaged, whereas `nginx-extras`
    is a normal apt install and sccache speaks WebDAV natively.

There is nothing to install on the other nodes.
`.builders/deploy-sccache.sh` installs a *node-level* sccache daemon on
port 4226; builds do not use it, and it is only for compiling on a host
directly.

## Step 5 — Build

```bash
make build-pytorch                    # one target on $(BUILDER)
make build-all                        # every target, one builder
make push-all BUILDER=snoc-pool       # scheduled across all three nodes
```

`BUILDER=snoc-pool` is a sentinel, not a buildx builder: it routes the
request through [the balancer](architecture/build-graph.md#the-balancer),
which runs one bake per target on a chosen node and hands results
between them through Zot.

Each `make build-*` runs through `telemetry/build.sh`, which records
duration, layer-cache hit ratio and sccache counters, then exits with
the build's own status. `TELEMETRY=0 make build-pytorch` skips it.

The build refuses to start when the compiler-cache store is unreachable,
rather than silently spending an hour recompiling everything:

```bash
docker buildx bake -f rocm-bake.hcl --set '*.args.REQUIRE_SCCACHE=0' pytorch
```

### Watch it

From a second terminal:

```bash
make watch                              # every builder, with a live tail
make watch WATCH_BUILDERS=snoc-think WATCH_LINES=40
```

Or one thing at a time:

```bash
make build-status     # records on $(BUILDER): running, completed, errored
make build-logs       # step output; BUILD=<id> for a specific record
make build-inspect    # duration, steps, cached steps, VCS revision
make builder-logs     # buildkitd's own log: registry, DNS, cache failures
make build-stop       # cancel builds started from this repo
```

`build-logs` is what the build's steps printed. `builder-logs` is the
daemon underneath, and that is where a registry fault, a DNS fault or a
cache fault shows up — often while the build itself merely looks slow.

## Step 6 — Verify

```bash
make gpu-test GPU_HOST=snoc-thinkstation PYTORCH_ROCM_ARCH=gfx1201
```

`gpu-test` runs the published image on a machine with a real GPU and
checks per-dtype numerics. It exists because a BuildKit `RUN` step has
no `/dev/kfd`, so nothing inside the build graph can prove the image
works — and an incorrect `HSA_OVERRIDE_GFX_VERSION` once shipped
undetected in every image.

By hand:

```bash
docker run --rm -it --device /dev/kfd --device /dev/dri \
  snoc-strix.fold-leaffish.ts.net:8080/rocm-pytorch/pytorch:2.15.0-10.1.0-full-gfx950
```

```python
import torch
print(torch.__version__)           # 2.15.0+rocm10.1
print(torch.cuda.is_available())   # True
print(torch.cuda.get_device_name(0))
```

## Step 7 — Measure it

```bash
make bench BENCH_SCENARIO=cold BUILDER=snoc-think
make bench-report
```

See [Performance](performance/index.md) for what the four scenarios
mean and how to read the numbers.

## Where next

- [Architecture](architecture/index.md) — the fleet, the build graph,
  and the caches
- [Reference](reference/make-targets.md) — every make target, bake
  variable and published tag
- [Troubleshooting](operations/troubleshooting.md) — the failures that
  have actually happened here
