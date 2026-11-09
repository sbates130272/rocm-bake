# Quick Start

From nothing to a published PyTorch image. On a fleet that is already
set up, skip to [step 5](#step-5-build).

## Prerequisites

The fleet below is `manifests/snoc.yml`, which is what `FLEET` defaults
to. Everything here reads that file, so a different fleet is a different
manifest rather than a different set of instructions — see
[The fleet](architecture/fleet.md).

- All nodes on the same Tailscale network.
- `snoc-strix`: a `gfx1151` GPU, Docker 27+. Runs the Zot registry, the
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
    Every proxy-aware tool — curl, urllib, and the Go binaries
    including `docker` — tries to reach `snoc-*` through ZScaler and
    fails. The Makefile exports `NO_PROXY_LIST` for its own targets;
    anything run by hand needs the same in your shell profile:

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

Zot is the local OCI registry: published images, the BuildKit layer
cache as OCI artifacts, and a pull-through mirror of Docker Hub, GHCR
and Quay. It runs on Strix as a bare-metal systemd service, deployed
outside this repository.

!!! danger "Do not start a second one"
    Other services pull through the same registry. Nothing here starts,
    stops or configures Zot — the `zot-*` targets only inspect it.

```bash
make zot-check      # is it active and answering?
make zot-catalog    # what does it hold?
```

Anonymous read is open; only pushing needs the `ci` account. Store that
credential with `pass`, which is GPG-encrypted at rest and works over
SSH — the `secretservice` helper fails with `Cannot create an item in a
locked collection` unless gnome-keyring has been unlocked graphically.

```bash
sudo apt-get install -y pass golang-docker-credential-helpers
pass init <your-gpg-key-id>        # gpg --list-secret-keys --keyid-format=long
# set "credsStore": "pass" in ~/.docker/config.json
docker login snoc-strix.fold-leaffish.ts.net:8080 -u ci
docker-credential-pass list        # verify it landed
```

One login on Strix covers the fleet: buildx sends registry auth to the
builder as a session attachment.

Zot also needs a raised HTTP read timeout, or pushing the ROCm base
fails — its largest layer is 8.67 GB and cannot cross a 1 Gb/s link
inside Zot's 60-second default:

```json
"http": {
  "readTimeout": "30m",
  "writeTimeout": "30m"
}
```

then `sudo systemctl restart zot`.
[Troubleshooting](operations/troubleshooting.md#push-dies-at-exactly-60-seconds)
has what the failure looks like.

The registry serves plain HTTP over the tailnet, so the Docker daemon
needs it in `/etc/docker/daemon.json`:

```json
{
  "insecure-registries": ["snoc-strix.fold-leaffish.ts.net:8080"],
  "registry-mirrors": ["http://snoc-strix.fold-leaffish.ts.net:8080"]
}
```

`make fleet-apply` writes that file on every build node, from the
manifest's registry.

## Step 3 — Create The Builders

```bash
make list-nodes             # which fleet this is, and what it declares
make builder-setup          # one builder per build node in the manifest
make builder-snoc-think     # or just one of them
make builder-status         # what exists now
```

There is no list of builders in the Makefile — `builder-setup` expands
the manifest's node list. The remote nodes join over SSH to their Docker
daemons, so neither needs buildkitd, TLS certificates or the plugin.

Every builder gets a `buildkitd.toml` rendered for that node and
`--driver-opt network=host`. Both are load-bearing:

- the config carries plain HTTP to Zot, the pull-through mirrors and a
  `[dns]` block — BuildKit writes its own `resolv.conf` and defaults it
  to `8.8.8.8`, so without the block a `RUN` step cannot resolve any
  tailnet name;
- `network=host` gives the builder the host's resolver, MagicDNS
  included, which Docker strips from a bridged container's.

!!! warning "Both are fixed at create time"
    An existing builder does not pick up a later change. Adopting one
    costs that node's BuildKit content store:
    `docker buildx rm snoc-strix && make builder-snoc-strix`.

## Step 4 — Deploy The Shared Compiler Cache

Every build container runs its own sccache server, all sharing one
object store: nginx with the WebDAV modules on Strix at `:8081`. An
object compiled on any node is a hit on the others.

```bash
sudo ./.builders/deploy-webdav.sh
make cache-check                 # can every node reach it?
make cache-summary               # endpoint, size, disk, deltas, hit rates
```

The port and path come from the manifest, so the deployer and the
builders cannot disagree about where the store is. `make fleet-check`
asks every node whether it can *write* to it, not just reach it: a node
that can only read compiles everything and shares none of it, which
looks exactly like a slow node.

!!! info "Why a durable store, and why WebDAV"
    An in-RAM store loses the whole fleet's compiler cache on a power
    cycle; a plain directory tree survives and backs up with rsync.
    WebDAV rather than S3/MinIO because `dl.min.io` is blocked by the
    corporate proxy while `nginx-extras` is a normal apt install. Off
    the fleet, [the nightly](operations/aws.md) uses S3.

There is nothing to install on the other nodes.

## Step 5 — Build

```bash
make build-pytorch                    # one target on $(BUILDER)
make build-all                        # every target, one builder
make push-all BUILDER=snoc-pool       # scheduled across all three nodes
```

`BUILDER=snoc-pool` is a sentinel, not a buildx builder: it routes
through [the balancer](architecture/build-graph.md#the-balancer), one
bake per target, results handed between nodes through Zot.

Each `make build-*` runs through `telemetry/build.sh`, which records
duration, layer-cache hit ratio and sccache counters, then exits with
the build's own status. `TELEMETRY=0` skips it.

The build refuses to start when the compiler-cache store is unreachable,
rather than silently recompiling everything:

```bash
docker buildx bake -f rocm-bake.hcl --set '*.args.REQUIRE_SCCACHE=0' pytorch
```

### Watch It

From a second terminal:

```bash
make build-watch                        # every builder, with a live tail
make build-watch WATCH_BUILDERS=snoc-think WATCH_LINES=40
```

Or one thing at a time:

```bash
make build-status     # records on $(BUILDER): running, completed, errored
make build-logs       # step output; BUILD=<id> for a specific record
make build-inspect    # duration, steps, cached steps, VCS revision
make builder-logs     # buildkitd's own log: registry, DNS, cache failures
make build-stop       # cancel builds started from this repo
```

`build-logs` is what the steps printed; `builder-logs` is the daemon
underneath, where a registry, DNS or cache fault shows up while the
build merely looks slow.

## Step 6 — Verify

```bash
make gpu-test GPU_HOST=snoc-thinkstation PYTORCH_ROCM_ARCH=gfx1201
```

It checks per-dtype numerics on real hardware, and exists because a
BuildKit `RUN` step has no `/dev/kfd` — an incorrect
`HSA_OVERRIDE_GFX_VERSION` once shipped undetected in every image.

By hand:

```bash
docker run --rm -it --device /dev/kfd --device /dev/dri \
  snoc-strix.fold-leaffish.ts.net:8080/rocm-pytorch/pytorch:2.15.0-10.1.0-full-gfx950
```

```python
import torch
print(torch.__version__)           # 2.15.0a0+git31a77fc.rocm10.1.0
print(torch.cuda.is_available())   # True
print(torch.cuda.get_device_name(0))
```

## Step 7 — Measure It

```bash
make bench BENCH_SCENARIO=cold BUILDER=snoc-think
make bench-report
```

See [Performance](performance/index.md) for what the four scenarios mean
and how to read the numbers.

## Where Next

- [Architecture](architecture/index.md) — the fleet, the build graph,
  and the caches
- [Reference](reference/make-targets.md) — every make target, bake
  variable and published tag
- [Troubleshooting](operations/troubleshooting.md) — the failures that
  have actually happened here
