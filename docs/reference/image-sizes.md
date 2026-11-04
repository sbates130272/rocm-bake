# Image Sizes

What each published image costs to pull, and which part of it is this
project's doing. The numbers are read from the Zot registry on the
fleet; `make image-publish` pushes them onto `gh-pages` from the
registry host.

<p id="images-generated"></p>

## Shared, And Own

<div class="bench-chart" markdown="0">
  <canvas id="images-split"></canvas>
</div>

A layer digest appearing under more than one repository is **shared**;
everything else is that image's **own**. The split is measured from the
manifests, so nothing has to know what the base image is called.

It is the only reading of these images that is not misleading: every run
image descends from one common base, so most of what a `total` column
reports is not the image's doing. Ranked by total, `vllm` is the largest
thing we build; ranked by what it contributes, it is under a gigabyte.
That base used to be `rocm/dev-ubuntu-26.04` directly, whose single
compressed layer is 8.67 GB — between 71% and 95% of each published
image, which is what the rest of this page is about.

<div id="images-table"></div>

`own` is the column to watch in review. A change that moves `total`
without moving `own` is a change to the base image, and a change that
moves `own` is one of ours.

## Wheels

The `*-wheel` targets publish scratch images holding one `.whl` each —
what `make fetch-torch-wheel` and the
[pip index](../architecture/multi-arch.md#per-architecture-pip-index)
read, and the reason the run images can mount a wheel instead of copying
it.

<div id="images-wheels"></div>

No shared/own split: a scratch image holding one file shares nothing.

## Over Time

<div class="bench-chart" markdown="0">
  <canvas id="images-history"></canvas>
</div>

One point per `make image-data`. Sizes only move when something is
rebuilt, so the line is flat by design — a step in it is the event worth
explaining.

## Layer Caches

Each build target exports its layer cache to a `*-cache` repository.

<div id="images-caches"></div>

**This table double-counts.** It sums each tag's manifest, and the tags
of one cache repo share most of their layers — an upper bound, useful
for comparing targets and useless as a disk figure.

These repos are not unbounded, which is what the number invites you to
assume. Each holds a fixed set of tags — `latest`, `latest-<arch>` and
`latest-<arch>-ref`, one per architecture in
[`ARCHES`](bake-variables.md) — and every build overwrites the one it
owns. Zot runs `dedupe`, `gc` and `deleteUntagged` on its own
schedule.

For what the registry actually occupies, ask the host:

```bash
make zot-disk
```

## Regenerating

From the registry host, where the tailnet name resolves:

```bash
make image-sizes                      # the table, in the terminal
make image-sizes LAYERS=1             # with the per-layer breakdown
make image-sizes IMAGE_ARCH=gfx1201   # a card other than the default
make zot-disk                         # deduplicated disk, from the Zot host
make image-data                       # dist/images/images.json
make image-publish                    # commit it to gh-pages, locally
make image-publish PUSH=1             # and push
```

**One architecture per table.** `shared` counts a layer digest carried
by more than one image *in the set being compared*, so a table mixing
cards reports layers as unshared that are not — and the `own` column,
the one worth reading, comes out wrong.

`image-publish` reads the copy already on `gh-pages` first, because
`images.json` carries its own history array and that branch is the only
place the older points exist.

## Why The Images Were The Size They Were

Three things, in order of how much they cost.

### The ROCm SDK Base — 7.13 GB

`rocm/dev-ubuntu-26.04:10.1.0-full` unpacks to 20.53 GB in one 8.67 GB
layer, carrying rocBLAS, hipBLASLt and MIOpen kernel libraries for every
architecture AMD supports plus a full LLVM. Each image here targets
exactly one architecture, and AMD publishes no `-runtime` variant.

`rocm-runtime` cuts it down by `dpkg --purge` of the per-architecture
packages for cards we do not target — ROCm 10.1 already splits them as
`<component>10.1-<gfx>` — which is 10.77 GB of the 20.53 on its own:

| removed | how | measured |
| --- | --- | --- |
| per-architecture packages (260 of them) | `dpkg --purge` | 10.77 GB |
| static archives (`*.a`, 835 files) | `rm` — with one exception | 4.73 GB |
| docs, man, info | `rm` | small |
| `/opt/rocm/lib/cmake` | `rm` — **`minimal` only** | a few MB |

The second stage is what makes any of it count: a `rm` in a child layer
reclaims nothing, so `COPY --from=pruned / /` onto `scratch` flattens
the result into one new layer. The whole root, not `/opt/rocm` — a ROCm
install reaches outside its own tree, and an image missing
`ld.so.conf.d` or the udev rules loads `libamdhip64` and finds no
device.

Measured, `gfx1201`: **8.67 GB → 1.42 GB**, with `base` adding 0.24 GB.
An earlier revision quoted 1.54 GB on `gfx950`; treat it as withdrawn.

!!! warning "Two things the sweep must not remove"
    "Nothing loads a `.a` at run time" is true of the ROCm math
    libraries and false of the compiler's own runtime: `clang` links
    `libclang_rt.builtins.a` into *every* HIP compilation. The cmake
    package files went the same way — `pytorch-wheel` compiles PyTorch
    inside this image, and cmake's HIP language detection reads
    `hip-lang-config.cmake`. Both were removed on reasoning about the
    *runtime* images, and both surfaced hours downstream as a failed
    wheel build naming neither ROCm nor the prune.

    So `Dockerfile.rocm-runtime` compiles **and links** a real HIP
    program and checks the cmake package, in 0.9 s, at build time.
    Asserting files exist is what failed twice; building something
    covers the class.

`docker/rocm-prune.sh` also asserts the architecture it kept still has
packages — guarding against an image that imports `torch` happily and
then has no kernels for the card it lands on.

#### Prune Profiles

| profile | keeps | for |
| --- | --- | --- |
| `keep-toolchain` (default) | `hipcc`, the ROCm headers, LLVM, `/opt/rocm/lib/cmake` | everything |
| `minimal` | none of them | an image that compiles nothing |

One base serves every target. `minimal` is 0.4 GB better on a 4.4 GB
tree, but giving `pytorch-run` its own would mean a second base image
and a second layer cache per architecture — and the serving images
genuinely need the toolchain, since AITER JIT-compiles on first use and
Triton shells out to `ld.lld`.

`amdrocm-rpp`, `amdrocm-rdc` and `amdrocm-rocshmem` are 1.1 GB nothing
here imports, deliberately kept: each is a hard `Depends` of the
architecture core package, and purging them leaves `apt` refusing every
later operation in *downstream* images.

### Wheels Copied Into The Image That Installs Them — ~1.5 GB

A `COPY` is a layer. `Dockerfile.pytorch` copied the torch wheel in
(0.40 GB), installed it, then `rm -rf` in a later layer — which reclaims
nothing, so every pull paid for a wheel it could not use. Same for
Triton (0.45 GB) and every wheel in the vLLM and LMCache images. Those
sites use `RUN --mount=type=bind,from=<stage>` now, so the wheel never
becomes a layer; the `*-wheel` scratch images still publish it.

### Dependencies That Cannot Run Here

The PyPI builds of `torchvision`, `torchaudio` and `torchdata` are CUDA
builds, and were the only thing in these images that was. On ROCm
`torchvision`'s extension fails to load, which is why `Dockerfile.vllm`
cannot import vLLM's own LMCache connector in a verification step. The
optional-extras step that pulled them in carried `|| true`, which kept
it quiet; it is gone from `Dockerfile.pytorch`, but vLLM's `timm`
dependency still reaches torchvision. See
[Serving stack](../architecture/serving.md).
