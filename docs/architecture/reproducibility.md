# Reproducibility

Two builds of the same commit must produce the same image digest —
because the digest is what every downstream `FROM` pins, and one that
moves invalidates the entire chain below it. Three mechanisms get there,
each added after the absence of it cost a full rebuild.

## `SOURCE_DATE_EPOCH`

`BUILD_DATE` only reaches the `created` **label**. The image *config*
has a `created` field of its own, stamped with nanosecond wall-clock
time regardless — so two builds of identical content produced different
digests and every downstream `FROM` missed. `SOURCE_DATE_EPOCH` pins
it.

It is set per image, not per repository, and it is a **constant**:

```hcl
variable "SDE_EPOCH" { default = "1700000000" }
```

Two earlier designs failed. **Taking it from HEAD** gave the base a new
digest on every commit, hence a full downstream rebuild even for a
commit that touched only the Makefile — measured, `Dockerfile.base`
unchanged yet the base digest moved `91db3c2e → aa52684f`. **Taking it
from the Dockerfile's own last commit** used history as a proxy for
"this image's inputs changed", and the proxy does not hold: squashing 26
commits into 3 made every remaining commit touch every Dockerfile, so
all five values collapsed and every cache was invalidated at once.

Content should decide, and already does — it decides the layer digests.
The config `created` field carries no information anyone reads; the real
build date lives in `org.opencontainers.image.created`. Pinning it to a
constant costs nothing and survives history being rewritten.

Bump `SDE_EPOCH` only to force every image to a new digest deliberately.
Per-image overrides pin one without the others:

```bash
SDE_PYTORCH=1700000001 make build-pytorch
```

The twelve `SDE_*` per-image variables all default to empty, meaning
"use `SDE_EPOCH`". Bake reads them from the environment, so `SDE_PYTORCH=…
make …` works and `make … SDE_PYTORCH=…` does not.

## `atom-wheel` Is Not Bit-Reproducible, And `SOURCE_DATE_EPOCH` Cannot Fix It

ATOM's `atom/mesh/build.rs` stamps the binary with
`chrono::Utc::now()`, which no epoch variable reaches:

```rust
set_env!("BUILD_TIME", chrono::Utc::now().format("%Y-%m-%d %H:%M:%S UTC"));
```

Measured by comparing the `gfx950` and `gfx1151` wheels of ATOM
`v0.1.9`, built an hour apart. Of 1206 files, 1204 are byte-identical;
only `atom/mesh/target/release/libmesh.so` and the `RECORD` that
carries its hash differ. Inside that 20,930,632-byte `.so`, exactly 24
bytes differ — 20 of them the `.note.gnu.build-id`, which is a hash of
the output rather than an input, and the other four the digits of:

```
2026-11-05 02:13:25 UTC     gfx950
2026-11-05 03:12:52 UTC     gfx1151
```

Everything else in that record matches: crate version `0.2.0`, target
triple, ATOM commit `606aceb1`, `clean` tree, `rustc 1.95.0`.

Two things follow. First, the wheel's *content* really is
architecture-independent — which is what `docker/Dockerfile.atom` and
the `atom-wheel` target claim, and the 1204 identical files are the
evidence. Second, two builds of the same ATOM tag will never share a
digest, so nothing downstream can pin `atom-wheel` by digest and expect
a rebuild to match. Fixing it means patching `build.rs` to honour
`SOURCE_DATE_EPOCH`, upstream or in this repo; until then this is a
known exception rather than a defect to hunt.

## Provenance Attestations

Provenance attestations record build timestamps, so they differ on every
build even when the image is byte-identical — and because the
attestation shares an OCI index with the image manifest, that changes
the digest a downstream `FROM` pins. Measured: two identical base builds
produced indexes `fd260117` and `9c5e5112` around one unchanged manifest
`91db3c2e`, and a probe `RUN` missed across them.

So provenance is disabled on every image that is a parent or a named
context — `pytorch-base`, `pytorch`, `triton-wheel`, and `pytorch-wheel`
by inheritance:

```hcl
NO_PROVENANCE = ["type=provenance,disabled=true"]
```

`pytorch-run`, `aiter-wheel`, `torchvision-wheel`, `cupy-wheel`,
`nixl-wheel`, `vllm` and `lmcache` keep theirs — nothing inherits a
layer stack from them, so their digests may churn freely.

That is a weaker claim than "nothing builds `FROM` them", and the
weaker one is the true one: `Dockerfile.vllm` does say
`FROM ${AITER_WHEEL_IMAGE}` and the same for nixl, lmcache and
torchvision. Those stages exist only to be bind-mounted from, and each
is a `scratch` image holding one wheel — so a churned digest re-runs
the `pip install` that was going to run anyway, rather than
invalidating a chain of expensive layers underneath it. The cost that
made `NO_PROVENANCE` worth having on `pytorch-base` is not present
here.

## Labels

Labels live in the image config, so a changing `revision` or `created`
gives an image a new digest even when its content is identical — the
same trap, by a different route. Everything that ships gets full OCI
provenance; `pytorch-base` gets identity only:

```hcl
OCI_LABELS = {
  "org.opencontainers.image.source"   = SOURCE_URL
  "org.opencontainers.image.revision" = VCS_REF
  "org.opencontainers.image.created"  = BUILD_DATE
}
BASE_LABELS = {
  "org.opencontainers.image.source" = SOURCE_URL
}
```

Without that, a changing revision would give the base a new digest on
every commit, re-cloning PyTorch's submodule tree each time. The base is
an intermediate and should stay content-addressed.

## `VCS_REF` And Dirty Trees

`VCS_REF` is the short commit hash, with `-dirty` appended when the tree
has uncommitted changes, so an image built from edited sources cannot be
mistaken for the commit it came from. It also drives an immutable tag on
every target:

```
…/pytorch:2.15.0-10.1.0-full-gfx950-g<sha>
```

`BUILD_DATE` is the commit's own timestamp, not "now", for the same
reason `SOURCE_DATE_EPOCH` is pinned.

## Checking It Still Holds

The [warm benchmark scenario](../performance/index.md#warm) exists as a
standing check on this: a new commit should cost nothing, so warm should
build exactly what hot builds. The result is the assertion rather than
the number — if warm diverges from hot, some per-commit value has found
its way back into an image digest. That has happened twice.
