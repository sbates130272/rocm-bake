# Image sizes

What each published image costs to pull, and which part of it is
actually this project's doing.

The numbers are read from the Zot registry on the fleet, so they are not
built into the site. `make image-publish` pushes `data/images.json` onto
the `gh-pages` branch from the registry host, the same way
`make bench-publish` publishes the benchmark data — see
[Performance](../performance/index.md).

<p id="images-generated"></p>

## Shared, and own

<div class="bench-chart" markdown="0">
  <canvas id="images-split"></canvas>
</div>

A layer digest that appears under more than one repository is **shared**;
everything else is that image's **own**. The split is measured from the
manifests rather than declared, so nothing in the tooling has to know
what the base image is called.

It is the only reading of these images that is not misleading. Every run
image here descends from `rocm/dev-ubuntu-26.04`, whose single
compressed layer is 8.67 GB — between 71% and 95% of each published
image. Ranked by total, `vllm` is the largest thing we build; ranked by
what `vllm` itself contributes, it is under a gigabyte.

<div id="images-table"></div>

`own` is the column to watch in review. A change that moves `total`
without moving `own` is a change to the base image, and a change that
moves `own` is one of ours.

## Over time

<div class="bench-chart" markdown="0">
  <canvas id="images-history"></canvas>
</div>

One point per `make image-data`. Published image sizes only move when
something is rebuilt, so the line is flat by design — a step in it is
the event worth explaining.

## Layer caches

Each build target exports its layer cache to a `*-cache` repository.

<div id="images-caches"></div>

**This table double-counts.** It sums each tag's manifest, and the tags
of one cache repo share most of their layers — so the total is an upper
bound, useful for comparing one target's cache against another's and
useless as a disk figure.

These repos are not unbounded, which is the thing the number invites you
to assume. Each holds a fixed set of tags — `latest`, `latest-<arch>`
and `latest-<arch>-ref`, one per architecture in
[`ARCHES`](bake-variables.md) — and every build overwrites the one it
owns rather than adding another. Zot is configured with `dedupe`, `gc`
and `deleteUntagged`, so the manifests an overwrite orphans are
collected on its own schedule.

For what the registry actually occupies, ask the host:

```bash
make zot-disk
```

## Regenerating

From the registry host, where the tailnet name resolves:

```bash
make image-sizes              # the table, in the terminal
make image-sizes LAYERS=1     # with the per-layer breakdown
make zot-disk                 # deduplicated disk, from the Zot host
make image-data               # dist/images/images.json
make image-publish            # commit it to gh-pages, locally
make image-publish PUSH=1     # and push
```

`image-publish` reads the copy already on `gh-pages` before it
regenerates, because `images.json` carries its own history array and
that branch is the only place the older points exist.

## Why the images were the size they were

Three things, in order of how much they cost.

### The ROCm SDK base — 7.13 GB

`rocm/dev-ubuntu-26.04:10.1.0-full` unpacks to 20.53 GB and compresses
to one 8.67 GB layer. It carries rocBLAS, hipBLASLt and MIOpen kernel
libraries for every GPU architecture AMD supports, plus headers, static
archives, CMake package files and a full LLVM. Each image here is built
for exactly one architecture, and AMD publishes no `-runtime` variant
of this tag.

The `rocm-runtime` target cuts it down. Not by installing runtime
packages onto plain Ubuntu, which is the obvious guess and needs
AMD's apt repository: ROCm 10.1 **already** splits its per-architecture
content into packages named `<component>10.1-<gfx>`, so the work is a
`dpkg --purge` of the ones for cards we do not target, and that is
10.77 GB of the 20.53 on its own.

| removed | how | measured |
| --- | --- | --- |
| per-architecture packages (260 of them) | `dpkg --purge` | 10.77 GB |
| static archives (`*.a`, 835 files) | `rm` — nothing loads a `.a` at run time | 4.73 GB |
| CMake package files, docs, man, info | `rm` | small |

`docker/rocm-prune.sh` does it and asserts afterwards that the
architecture it was told to keep still has packages — the failure it
guards against is an image that imports `torch` happily and then has no
kernels for the card it lands on, which surfaces on a GPU host hours
later.

The second stage is what makes any of it count. A `rm` in a child layer
reclaims nothing: the parent layer is still in the chain and still
pulled. `COPY --from=pruned / /` onto `scratch` flattens the result
into one new layer, and the 8.67 GB original is not in the image's
chain at all.

Measured, `gfx950`: **8.67 GB → 1.54 GB**, with an identical ROCm
library surface — `hipconfig`, `rocminfo`, `ld.lld`, the HIP headers,
`libMIOpen`, `librccl`, `librocblas`, `libhipblaslt`, `libhipsparselt`
and the `amdsmi` Python package all present, and `torch.cuda` still
enumerating a device.

!!! note "Why `/` and not `/opt/rocm`"
    A ROCm installation reaches outside its own tree —
    `ld.so.conf.d` entries, `/etc/alternatives`, the sysdeps and udev
    packages. An image missing those loads `libamdhip64` and then
    finds no device. Copying the whole root keeps all of it without
    anyone having to enumerate it, and `scratch` avoids paying for the
    Ubuntu underneath twice.

#### Prune profiles

`ROCM_PRUNE_PROFILE` selects how hard to cut:

| profile | keeps | for |
| --- | --- | --- |
| `keep-toolchain` (default) | `hipcc`, the ROCm headers, LLVM | everything |
| `minimal` | neither | an image that compiles nothing |

One base serves every target. `minimal` is a measured 0.4 GB better on
a 4.4 GB tree, and giving `pytorch-run` its own would mean a second
base image and a second layer cache per architecture — which costs the
registry more than it saves. The serving images genuinely need the
toolchain: AITER JIT-compiles kernels on first use and Triton shells
out to `ld.lld`. So the profile is a variable rather than a second
target.

Three things are deliberately **not** removed. `amdrocm-rpp`,
`amdrocm-rdc` and `amdrocm-rocshmem` are about 1.1 GB that nothing here
imports, but each is a hard `Depends` of the architecture core package
we keep. Purging them leaves `apt` refusing every later operation — in
*downstream* images, with an error mentioning neither ROCm nor the
prune. 1.1 GB does not buy that.

### Wheels copied into the image that installs them — ~1.5 GB

A `COPY` is a layer. `Dockerfile.pytorch` copied the torch wheel to
`/opt/pytorch/dist` (0.40 GB), installed it, and then
`rm -rf /opt/pytorch` — in a later layer, which reclaims nothing, so
every pull paid for a wheel it could not use. The same pattern held for
Triton (0.45 GB) and for every wheel in the vLLM and LMCache images.

Those install sites now use `RUN --mount=type=bind,from=<stage>`, so
the wheel exists for the duration of the command and never becomes a
layer. Nothing is lost: the `*-wheel` scratch images publish the same
artifacts, which is where `make fetch-torch-wheel` already reads them.

### Dependencies that cannot run here

The PyPI builds of `torchvision`, `torchaudio` and `torchdata` are CUDA
builds, and they were the only thing in these images that was. On ROCm
`torchvision`'s extension fails to load — which is why serving had to
swap a CPU build in at container start, and why `Dockerfile.vllm`
cannot import vLLM's own LMCache connector in a verification step. The
install step carried `|| true`, which is what kept it quiet. It is
gone; restore it when there is a `torchvision` built against our torch.
