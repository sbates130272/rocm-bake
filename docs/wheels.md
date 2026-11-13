# Installing The Wheels

Every architecture this repo builds has a public pip index. The wheels
themselves are GitHub release assets; the index pages point at them,
with a `#sha256=` on every link so pip verifies what it downloads.

[Browse the indexes][wheels] · [Build performance][perf]

[wheels]: https://sbates130272.github.io/rocm-bake/data/wheels/
[perf]: https://sbates130272.github.io/rocm-bake/data/perf/

```bash
pip install \
  --index-url https://sbates130272.github.io/rocm-bake/data/wheels/gfx950/ \
  --extra-index-url https://pypi.org/simple \
  "rocm-torch[device-gfx950]"
```

Substitute `gfx1201`, `gfx1151` or `gfx1250` for another card. That is
the whole interface.

!!! note "No GPU? There is an `emu` index"
    One index is not a card: `emu` carries a vLLM built with no device
    backend at all, plus the emulator that makes it still serve. It
    installs anywhere and runs nothing on a GPU — see
    [Emulated serving](architecture/emulation.md).

    It is kept out of the per-card indexes on purpose. Two builds of
    `vllm` in one index would let pip hand the emulator to someone who
    asked for `device-gfx950`.

!!! warning "Both index URLs are required"
    `--extra-index-url` is not optional. Ordinary dependencies — numpy,
    pydantic, a hundred others — live on PyPI and the install cannot
    resolve without it. `--index-url` must stay *first*: it is the one
    that carries our wheels.

## What `rocm-torch` Is

A generated metapackage. It carries no code; it pins every wheel in
one architecture's index at the exact version built against that ROCm
and that torch:

```
torch==2.15.0a0+git31a77fc.rocm10.1.0; extra == "device-gfx950"
atom==0.1.9+rocm10.1.0;                extra == "device-gfx950"
...
```

Installing it is how you get a set that was built together rather than
a set pip assembled. The exact pins are also the defence against
name collisions — see below.

Its own version looks like `10.1.0+gfx950.424e84fe`: the ROCm version,
the architecture, and a digest of the pin set. The digest moves
whenever the pinned versions do, so a rebuild is a new version rather
than the same version with different contents, which a pip cache is
entitled to assume.

## Reading A Version

A version string says which ROCm the wheel was built against.

| wheel | version | platform tag |
| --- | --- | --- |
| `torch` | `2.15.0a0+git31a77fc.rocm10.1.0` | `linux_x86_64` |
| `triton` | `3.9.0+gitaad2a60d.rocm10.1.0` | `linux_x86_64` |
| `amd_aiter` | `0.1.29.dev0+g…d20261109.rocm10.1.0` | `linux_x86_64` |
| `cupy` | `14.2.0+rocm10.1.0` | `manylinux_2_39` |
| `lmcache` | `0.5.6+rocm10.1.0` | `manylinux_2_39` |
| `atom` | `0.1.9+rocm10.1.0` | `manylinux_2_38` |
| `torchvision` | `0.29.2+rocm10.1.0` | `manylinux_2_39` |
| `nixl` | `1.5.2+rocm10.1.0` | `py3-none-any` |
| `nixl_rocm` | `1.5.2+rocm10.1.0` | `manylinux_2_39` |
| `vllm` | `0.33.0+rocm101` | `linux_x86_64` |
| `triton_kernels` | `1.0.0` | `py3-none-any` |

Where a wheel already carried a git hash, the ROCm marker is appended
to it rather than replacing it, so the commit stays visible. `vllm`
carries upstream's own `+rocm101`. `triton_kernels` is pure Python with
no ROCm code to qualify.

!!! danger "Nothing in a filename says which GPU"
    `torch` for gfx950 and for gfx1201 is the *same filename* and the
    two files differ by about 40MB of device code. The architecture is
    carried by the index path and by the metapackage, which is why
    downloading a release asset by hand is not a supported way to
    install these. Use the index.

## Why Some Wheels Are `manylinux` And Others Are Not

A `manylinux_X_Y` tag is a verified promise: this loads on any glibc at
or above X.Y. `auditwheel` grants one only by reading the compiled code
and taking the newest glibc symbol it references — so the tag depends
on what the code calls, not on what machine built it. It is measured
here, never asserted.

- **`cupy`, `lmcache`, `atom`, `torchvision`, `nixl_rocm`** fall inside
  a policy auditwheel defines. Their non-system dependencies are
  vendored into the wheel and the tag is rewritten to match.
- **`torch`, `triton`, `vllm` cannot have one.** They reference symbols
  newer than any policy auditwheel knows — torch needs `GLIBC_2.43`,
  the base image's glibc — so `auditwheel show` ends at *"This
  constrains the platform tag to linux_x86_64"*. No exclude list
  changes that; the symbol is in torch's own code.
- **`amd_aiter` has nothing to describe.** At `PREBUILD_KERNELS=0` it
  contains no x86_64 ELF at all, only GPU code objects, and auditwheel
  refuses it outright. It is still architecture-specific — for the GPU,
  which no platform tag can express.

Everything ROCm ships is excluded from vendoring, because the consuming
environment is expected to have the same ROCm these were built against.
A wheel carrying its own copy of hipBLAS or RCCL would both be enormous
and shadow the runtime everything else is using.

## Name Collisions With PyPI

Several of these names are also published by someone else, and pip has
no notion of "prefer this index". It picks by version.

That is a real failure mode here, not a theoretical one. `nixl` is also
NVIDIA's, at the same upstream version: their `nixl 1.5.2` is a CUDA
meta-package whose hard dependencies are `nixl-cu12` and `nixl-cu13`.
With both at `1.5.2` pip had no tiebreaker and took theirs — so a ROCm
index installed CUDA backends. The same shape applies to `atom`, which
is Nucleic's Atom framework on PyPI at a much higher version, and to
`torch`, where PyPI's final `2.15.0` outranks our `2.15.0a0` alpha.

The local version segment is what resolves all of them. `+rocm10.1.0`
cannot be matched by an upstream release, so a metapackage pin of
`nixl==1.5.2+rocm10.1.0` is unsatisfiable by NVIDIA's `1.5.2` and ours
is the only candidate. This is why **installing the metapackage, rather
than the individual wheels, is the supported path** — the exact pins
are the mechanism.

A scheduled workflow re-resolves every published index weekly and fails
if any of our distributions comes from PyPI or any CUDA package appears,
because this class of breakage arrives without a commit of ours: it
starts the day somebody else publishes a colliding name.

## Python Version

The wheels are `cp314`. Ubuntu 26.04 is the only base AMD publishes
ROCm 10.1 for and it ships no other Python, so there is no other build.

Nothing in the set caps below 3.14, so the full install needs no
special flags. `make wheel-index` measures each wheel's
`Requires-Python` and names any that excludes the interpreter here, so
if an upstream does cap it shows up as a note rather than an opaque
resolution failure.
