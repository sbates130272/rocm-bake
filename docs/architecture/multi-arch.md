# Multiple GFX Targets

Two different things, easy to confuse:

| | What It Produces |
| --- | --- |
| `PYTORCH_ROCM_ARCH='gfx950;gfx1201'` | One fat build, both code objects in one binary, one set of tags |
| `ARCHES='gfx950 gfx1201'` | Two builds, two separately-tagged sets of artifacts |

`PYTORCH_ROCM_ARCH` picks the architecture for one build and defaults to
`gfx950`. `ARCHES` is the list the `arches-*` wrappers fan out over, and
defaults to `gfx950 gfx1201 gfx1151 gfx1250`.

```bash
make arches-push-all                      # every target, every arch
make arches-push-wheels                   # just the wheel artifacts
make arches-build-pytorch ARCHES=gfx1201  # narrow it while iterating
make arches-list                          # what ARCHES resolves to
```

`arches-%` accepts *any* target name. Each architecture is a full pass
over every target, so treat the list as a multiplier on build time; the
passes run sequentially because they contend for the same builders.

## `gfx1151` Is The Card snoc-strix Actually Has

RDNA3.5 (Strix Halo). Unlike `gfx950` and `gfx1250`, it is in the fleet
— see `manifests/*.yml` or `make list-nodes` for which node has what —
so it can be GPU-tested rather than only cross-compiled, including with
`GPU_HOST=snoc-strix` when the default `gpu_node` is busy.

ROCm 10.1 ships eleven `-gfx1151` packages, so `rocm-prune` has
something to keep. AITER v0.1.28 lists it as Experimental and still
recommends installing it on RDNA parts, with the caveat that drives the
`PREBUILD_KERNELS` choice below: most CK and ASM kernels are CDNA-only,
so level 2 fails here as it does on `gfx1201`. Level 0 is the default.

It is **not** RDNA4 despite being gfx11-and-up — `IS_RDNA4` tests for a
`gfx12` substring, so `USE_ROCM_CK_SDPA_GFX12` stays off.

## `gfx1250` Is In The List Without Being In The Fleet

The builders cross-compile — no node has a `gfx950` card, yet the fleet
builds it daily — so having no card only means `make gpu-test` cannot
cover it. The ROCm 10.1 toolchain compiles it:

```bash
clang -x hip --offload-arch=gfx1250 -nogpulib -c   # exits 0
```

## `gfx1250` Is Not RDNA, Despite The Number

This is the one place the architecture naming actively misleads, and the
build branches on it:

```hcl
ARCH_RDNA_TEST = replace(PYTORCH_ROCM_ARCH, "gfx125", "")
IS_RDNA4       = ARCH_RDNA_TEST != replace(ARCH_RDNA_TEST, "gfx12", "")
```

`gfx1250` and `gfx1251` are `gfx12`-numbered but MI450-class datacenter
parts: upstream LLVM gates `amdgpu-sched-strategy=coexec` on `gfx1250`
and `gfx950` together, and gives `gfx1250` tensor instructions no RDNA
part has. A bare `gfx12` test applies RDNA-only settings to a datacenter
card, which is why the strip comes first.

AITER's kernel prebuild is **level 0 on every architecture**: build time
is the binding constraint here, and the prebuild buys first-inference
latency rather than capability, since AITER JIT-compiles on first use
either way.

A measurement forced that before cost chose it. On `gfx1201` all 13 844
kernels compiled and the build failed in the JIT *module* phase — 6 of
68 modules carry CDNA-only code and `setup.py` treats a failure as
fatal, so `bdist_wheel` exited 1 after 51 minutes with no wheel.
Reproduced twice; upstream lists `gfx1201` as Experimental.

`PREBUILD_KERNELS` pins a level for one build. Level 2 produces **no
wheel at all** on `gfx1201` and `gfx125x`, so a global pin is only safe
on CDNA.

## The Layer Cache Is Scoped By Architecture

`CACHE_ARCH` keeps each architecture's registry cache separate, because
before it existed alternating architectures cost two cold builds every
time. `triton-wheel` stays on the shared ref — it compiles no device
code — and `pytorch-base` does not. See
[Caching](caching.md#scoped-by-architecture).

## Per-Architecture Pip Index

Every wheel here has an architecture-independent filename. `torch` is
`torch-…-cp314-cp314-linux_x86_64.whl` whether it was built for `gfx950`
or `gfx1201`, and `amd_aiter` is 131 MB for one architecture and 481 MB
for the other. In one directory they overwrite each other and
`--find-links` serves whichever landed last. So the architecture lives
in the path.

```bash
make wheel-index                  # fetch per arch, generate the indexes
make wheel-index-check            # install each one into a throwaway venv
python3 -m http.server 8081 --directory dist
```

```bash
pip install \
  --index-url http://<host>:8081/index/gfx950/ \
  --extra-index-url https://pypi.org/simple \
  "rocm-torch[device-gfx950]"
```

`rocm-torch` is a metapackage generated per index by
`.builders/wheelindex.py`; its `device-<arch>` extra pins every wheel in
that index at once, and each index declares only its own architecture's
extra, so asking `gfx950`'s index for `[device-gfx1201]` fails rather
than installing mismatched binaries.

Wheels are fetched by architecture-specific tag, never `:latest` —
written by whichever architecture was pushed last, with the wheels
inside indistinguishable afterwards, which is the failure this index
exists to prevent.

!!! warning "`--extra-index-url` is not optional"
    `--index-url` replaces PyPI outright, and the first ordinary
    dependency — numpy, via `triton-kernels` — then fails to resolve.
    `download.pytorch.org` has the same property and the same
    workaround.

### Why `device-<arch>` And Not A Variant

This is the shape TheRock ships ROCm in, rather than the WheelNext
variant mechanism. Variants (PEP 817/825) are the better long-term
answer, but both PEPs are Draft, installer support is prototype-only
forks of pip and uv, and AMD's published provider matches PyTorch 2.9 on
ROCm 6.3/6.4 against a gfx list without `gfx950`.

The extra is spelled `device-<arch>` so that when variants do land the
architecture is already a first-class coordinate.

CI builds two architectures' indexes on every pull request and asserts
that each installs its own and only its own.
