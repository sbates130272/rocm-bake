# Multiple GFX targets

Two different things, easy to confuse:

| | What it produces |
| --- | --- |
| `PYTORCH_ROCM_ARCH='gfx950;gfx1201'` | One fat build, both code objects in one binary, one set of tags |
| `ARCHES='gfx950 gfx1201'` | Two builds, two separately-tagged sets of artifacts |

`PYTORCH_ROCM_ARCH` picks the architecture for one build and defaults to
the single value `gfx950`. `ARCHES` is the list the `arches-*` wrappers
fan out over, and defaults to `gfx950 gfx1201 gfx1250`.

```bash
make arches-push-all                      # every target, every arch
make arches-push-wheels                   # just the wheel artifacts
make arches-build-pytorch ARCHES=gfx1201  # narrow it while iterating
make arches-list                          # what ARCHES resolves to
```

`arches-%` is a pattern rule: it accepts *any* target name, not only the
examples above. Each architecture is a full pass over every target, so
treat the list as a multiplier on build time. The passes run
sequentially — they contend for the same three builders and the same
compiler cache, so running them concurrently only makes both slower.

## `gfx1250` is in the list without being in the fleet

The builders cross-compile — the two `gfx1201` nodes build `gfx950`
every day — so having no such card only means `make test` and
`make gpu-test` cannot cover it. The ROCm 10.1 toolchain in the base
image compiles it:

```bash
clang -x hip --offload-arch=gfx1250 -nogpulib -c   # exits 0
```

## `gfx1250` is not RDNA, despite the number

This is the one place the architecture naming actively misleads, and the
build branches on it.

AITER's kernel prebuild is CDNA-only in practice, so `PREBUILD_LEVEL` is
chosen from the architecture rather than fixed. On `gfx1201` every one
of the 13 844 kernels compiled and the build then failed in the JIT
*module* phase: 6 of 68 modules carry CDNA-only code — MFMA templates,
GFX9 DPP broadcasts ("broadcasts are not supported on GFX10+"), CDNA
inline asm, `gfx950/` header trees — and `setup.py` treats a failed
module as fatal. `bdist_wheel` exited 1 after 51 minutes and produced no
wheel. Reproduced twice. Upstream documents it: AITER lists `gfx1201` as
Experimental, with most CK and ASM kernels CDNA-only.

So RDNA gets level 0. Those six modules cannot run there whatever we do,
every other module stays reachable because AITER JIT-compiles on first
use, and the prebuild is a startup-latency optimisation rather than a
capability. A wheel that exists beats a faster first inference that
never happens.

The detection has to special-case `gfx125x`:

```hcl
ARCH_RDNA_TEST = replace(PYTORCH_ROCM_ARCH, "gfx125", "")
IS_RDNA = (
  ARCH_RDNA_TEST != replace(ARCH_RDNA_TEST, "gfx11", "") ||
  ARCH_RDNA_TEST != replace(ARCH_RDNA_TEST, "gfx12", "")
)
PREBUILD_LEVEL = PREBUILD_KERNELS != "" ? PREBUILD_KERNELS : (IS_RDNA ? "0" : "2")
```

`gfx1250` and `gfx1251` are `gfx12`-numbered but are MI450-class
datacenter parts, not RDNA: upstream LLVM gates
`amdgpu-sched-strategy=coexec` on `gfx1250` and `gfx950` together, and
gives `gfx1250` tensor instructions no RDNA part has. Left to the bare
`gfx12` test they would read as RDNA and silently drop the kernel
prebuild to level 0 — turning off, on the one architecture that most
wants it, an optimisation that exists for exactly this class of card.

Set `PREBUILD_KERNELS` to pin a level for every target.

!!! note "`gfx950` is CDNA, not Strix Halo"
    Older text in this repository called `gfx950` "Strix Halo". It is
    not — Strix Halo is `gfx1151`. `gfx950` is a CDNA-class
    (MI350-series) architecture, which is why it takes the
    prebuild-level-2 path above. The build host is named `snoc-strix`;
    that is a hostname.

## The layer cache is scoped by architecture

Covered in [Caching](caching.md#scoped-by-architecture). Short version:
`CACHE_ARCH` keeps each architecture's registry cache separate, because
before it existed alternating architectures cost two cold builds every
time. `pytorch-base` and `triton-wheel` stay on the shared ref
deliberately — neither compiles device code.

## Per-architecture pip index

Every wheel here has an architecture-independent filename. `torch` is
`torch-2.14.1a0+git5c48869-cp314-cp314-linux_x86_64.whl` whether it was
built for `gfx950` or `gfx1201`, and `amd_aiter-0.1.27` is 131 MB for
one architecture and 481 MB for the other. In one directory they
overwrite each other and `--find-links` serves whichever landed last. So
the architecture lives in the path.

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
that index at once. Each index declares only its own architecture's
extra, so asking `gfx950`'s index for `[device-gfx1201]` fails rather
than installing mismatched binaries. `make zot-wheels` prints the extra
beside each published tag.

Wheels are fetched by architecture-specific tag, never `:latest` —
`:latest` is written by whichever architecture was pushed last and the
wheels inside cannot be told apart afterwards, which is the entire
failure this index exists to prevent. The tags come from `bake --print`
rather than being rebuilt in the Makefile, because `rocm-bake.hcl` owns
tag construction and a second copy is exactly the drift
`check-defaults.py` exists to catch.

!!! warning "`--extra-index-url` is not optional"
    `--index-url` replaces PyPI outright, and the first ordinary
    dependency — numpy, via `triton-kernels` — then fails to resolve.
    `download.pytorch.org` has the same property and the same
    workaround.

### Why `device-<arch>` and not a variant

This is the shape TheRock ships ROCm in —
`pip install "rocm[device-gfx1153]"` — rather than the WheelNext variant
mechanism. Variants (PEP 817/825) are the better long-term answer and
AMD ships an `amd-variant-provider` plugin, but both PEPs are Draft,
installer support is prototype-only forks of pip and uv, and the
published provider matches PyTorch 2.9 on ROCm 6.3/6.4 against a gfx
list that does not include `gfx950`. None of that resolves this stack
today.

The extra is spelled `device-<arch>` so that when variants do land the
architecture is already a first-class coordinate, and only the selection
mechanism has to change.

CI builds two architectures' indexes on every pull request and asserts
that each installs its own and only its own.
