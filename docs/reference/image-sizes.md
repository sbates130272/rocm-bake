# Image Sizes

What each published image costs to pull, and which part is this
project's doing. Numbers come from the Zot registry on the fleet; `make
image-publish` pushes them onto `gh-pages` from the registry host.

<p id="images-generated"></p>

## Shared, And Own

<div class="bench-chart" markdown="0">
  <canvas id="images-split"></canvas>
</div>

A layer digest under more than one repository is **shared**; the rest
is that image's **own**, read from the manifests.

**It is the only reading that is not misleading**, because every run
image descends from one common base: by total, `vllm` is the largest
thing we build; by `own`, under a gigabyte. That base used to be
`rocm/dev-ubuntu-26.04`, whose single layer is 8.67 GB — 71% to 95% of
each published image.

<div id="images-table"></div>

`own` is the column to watch in review: `total` moving alone is a
change to the base image, and `own` moving is one of ours.

## Wheels

The `*-wheel` targets publish scratch images holding one `.whl` each —
what `make fetch-torch-wheel` and the
[pip index](../architecture/multi-arch.md#per-architecture-pip-index)
read, and why run images mount a wheel rather than copy it.

<div id="images-wheels"></div>

No split: one file shares nothing.

## Over Time

<div class="bench-chart" markdown="0">
  <canvas id="images-history"></canvas>
</div>

One point per `make image-data`. Sizes move only when something is
rebuilt, so the flat line is by design — a step in it is the event
worth explaining.

## Layer Caches

Each build target exports its layer cache to a `*-cache` repository.

<div id="images-caches"></div>

**This table double-counts.** The tags of one cache repo share most of
their layers, so summing manifests is an upper bound — useful for
comparing targets, useless as a disk figure.

They are bounded: each repo holds `latest`, `latest-<arch>` and
`latest-<arch>-ref` per architecture in [`ARCHES`](bake-variables.md),
and every build overwrites the one it owns. Zot runs `dedupe`, `gc` and
`deleteUntagged` itself.

Actual occupancy, from the host:

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

**One architecture per table.** `shared` counts a digest carried by
more than one image *in the set compared*, so a table mixing
cards reports shared layers as unshared and `own` comes out wrong.

`image-publish` reads the `gh-pages` copy first — the only place
`images.json`'s history exists.

## Why The Images Were The Size They Were

Three things, in order of cost.

### The ROCm SDK Base — 7.13 GB

`rocm/dev-ubuntu-26.04:10.1.0-full` unpacks to 20.53 GB in one 8.67 GB
layer: rocBLAS, hipBLASLt and MIOpen kernels for every architecture AMD
supports, plus a full LLVM. Each image targets one architecture, and
AMD publishes no `-runtime` variant.

`rocm-runtime` `dpkg --purge`s the per-architecture packages for cards
we do not target — ROCm 10.1 splits them as `<component>10.1-<gfx>` —
10.77 GB of the 20.53 alone:

| removed | how | measured |
| --- | --- | --- |
| per-architecture packages (260 of them) | `dpkg --purge` | 10.77 GB |
| static archives (`*.a`, 835 files) | `rm` — with one exception | 4.73 GB |
| docs, man, info | `rm` | small |
| `/opt/rocm/lib/cmake` | `rm` — **`minimal` only** | a few MB |

A `rm` in a child layer reclaims nothing, so a second stage flattens
it: `COPY --from=pruned / /` onto `scratch` — **the whole root, not
`/opt/rocm`**, since an image missing `ld.so.conf.d` or the udev rules
loads `libamdhip64` and finds no device.

Measured, `gfx1201`: **8.67 GB → 1.42 GB**, `base` adding 0.24 GB. An
earlier 1.54 GB figure on `gfx950` is withdrawn.

!!! warning "Two things the sweep must not remove"
    "Nothing loads a `.a` at run time" is true of the ROCm math
    libraries and false of the compiler's own runtime — `clang` links
    `libclang_rt.builtins.a` into *every* HIP compilation — and cmake's
    HIP detection reads `hip-lang-config.cmake`, which `pytorch-wheel`
    needs to build PyTorch here. Both were removed on reasoning about
    the *runtime* images, and both surfaced hours downstream as a
    failed wheel build naming neither ROCm nor the prune.

    So `Dockerfile.rocm-runtime` compiles **and links** a real HIP
    program and checks the cmake package, in 0.9 s, at build time.
    Asserting files exist failed twice.

`docker/rocm-prune.sh` also asserts the kept architecture still has
packages — else an image imports `torch` happily and has no kernels for
its card.

#### Prune Profiles

| profile | keeps | for |
| --- | --- | --- |
| `keep-toolchain` (default) | `hipcc`, the ROCm headers, LLVM, `/opt/rocm/lib/cmake` | everything |
| `minimal` | none of them | an image that compiles nothing |

`minimal` is 0.4 GB better on a 4.4 GB tree, but giving `pytorch-run`
its own would mean a second base image and a second layer cache per
architecture — and the serving images need the toolchain anyway: AITER
JIT-compiles on first use, Triton shells out to `ld.lld`.

`amdrocm-rpp`, `amdrocm-rdc` and `amdrocm-rocshmem` are 1.1 GB nothing
here imports, kept because each is a hard `Depends` of the architecture
core package: purging them leaves `apt` refusing every later operation
*downstream*.

### Wheels Copied Into The Image That Installs Them — ~1.5 GB

A `COPY` is a layer. `Dockerfile.pytorch` copied the torch wheel in
(0.40 GB), installed it, then `rm -rf` in a later layer, so every pull
paid for a wheel it could not use. Same for Triton (0.45 GB) and every
wheel in the vLLM and LMCache images. All of those sites now use
`RUN --mount=type=bind,from=<stage>`, so the wheel never becomes a
layer; the `*-wheel` images still publish it.

### Dependencies That Cannot Run Here

The PyPI builds of `torchvision`, `torchaudio` and `torchdata` are CUDA
builds, the only such thing here. On ROCm `torchvision`'s extension
fails to load — why `Dockerfile.vllm` cannot import vLLM's own LMCache
connector in a verification step. The optional-extras step that pulled
them in carried `|| true`; it is gone from `Dockerfile.pytorch`, but
vLLM's `timm` still reaches torchvision. See
[Serving stack](../architecture/serving.md).
