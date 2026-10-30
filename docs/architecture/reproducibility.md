# Reproducibility

Two builds of the same commit must produce the same image digest. Not
for its own sake — because the digest is what every downstream `FROM`
pins, and a digest that moves invalidates the entire chain below it.

Three mechanisms get there, and each one was added after the absence of
it cost a full rebuild.

## `SOURCE_DATE_EPOCH`

`BUILD_DATE` only reaches the `created` **label**. The image *config*
has a `created` field of its own, which BuildKit stamps with
nanosecond wall-clock time regardless. So two builds of identical
content produced different config digests, different manifest digests,
and every downstream `FROM` missed. `SOURCE_DATE_EPOCH` is what pins
that field.

It is set per image, not per repository, and it is a **constant**:

```hcl
variable "SDE_EPOCH" { default = "1700000000" }
```

Two earlier designs failed, and the reasons are worth keeping.

**Taking it from HEAD** gave the base a new `created` on every commit,
hence a new digest, hence a full downstream rebuild — even for a commit
that only touched the Makefile. Measured: `Dockerfile.base` unchanged
between two commits, yet the base digest moved `91db3c2e → aa52684f`
and nothing downstream could hit.

**Taking it from `git log -1 --format=%ct -- Dockerfile.<image>`** used
commit history as a proxy for "this image's inputs changed". The proxy
does not hold. Squashing 26 commits into 3 made every remaining commit
touch every Dockerfile, so all five values collapsed to one timestamp
and every image's cache was invalidated at once. Any rebase, squash or
`filter-branch` does this.

Content is what should decide, and content already does — it decides the
layer digests. The config `created` field carries no information anyone
reads; the real build date lives in
`org.opencontainers.image.created`. So pinning it to a constant costs
nothing and is immune to history being rewritten.

Bump `SDE_EPOCH` only to force every image to a new digest
deliberately. Per-image overrides exist for pinning one without the
others:

```bash
SDE_PYTORCH=1700000001 make build-pytorch
make build-pytorch BAKE_EXTRA='--set pytorch.args.SOURCE_DATE_EPOCH=…'
```

`SDE_BASE`, `SDE_PYTORCH`, `SDE_TRITON`, `SDE_AITER`, `SDE_RUNTIME`,
`SDE_NIXL`, `SDE_VLLM`, `SDE_LMCACHE` and `SDE_CUPY` all default to
empty, meaning "use `SDE_EPOCH`". They are read by bake from the
environment, so `SDE_PYTORCH=… make …` works and
`make … SDE_PYTORCH=…` does not.

## Provenance attestations

Provenance attestations record build timestamps, so they differ on every
build even when the image is byte-identical. Because the attestation
shares an OCI index with the image manifest, that changes the digest a
downstream `FROM` pins, and every layer below it misses.

Measured: two identical base builds produced indexes `fd260117` and
`9c5e5112` wrapped around one unchanged image manifest `91db3c2e`. A
probe `RUN` missed the cache across those two indexes, while the same
digest under a different tag hit.

So provenance is disabled on every image that is a parent or a named
context — `pytorch-base`, `pytorch`, `triton-wheel`, and
`pytorch-wheel` by inheritance:

```hcl
NO_PROVENANCE = ["type=provenance,disabled=true"]
```

`pytorch-run`, `aiter-wheel`, `cupy-wheel`, `nixl-wheel`, `vllm` and
`lmcache` keep theirs. Nothing builds `FROM` them, so their digests may
churn freely.

## Labels

Labels live in the image config, so a changing `revision` or `created`
gives an image a new digest even when its content is identical. The same
trap as `SOURCE_DATE_EPOCH`, arriving by a different route.

Everything that ships gets full OCI provenance:

```hcl
OCI_LABELS = {
  "org.opencontainers.image.source"   = SOURCE_URL
  "org.opencontainers.image.revision" = VCS_REF
  "org.opencontainers.image.created"  = BUILD_DATE
}
```

`pytorch-base` gets identity only:

```hcl
BASE_LABELS = {
  "org.opencontainers.image.source" = SOURCE_URL
}
```

Without that, a changing revision would give the base a new digest on
every commit, and every downstream `FROM` would invalidate —
re-cloning PyTorch's submodule tree and re-running pip each time.
Provenance belongs on the artifacts that ship; the base is an
intermediate and should stay content-addressed.

## `VCS_REF` and dirty trees

`VCS_REF` is the short commit hash, with a `-dirty` suffix appended when
the tree has uncommitted changes, so an image built from edited sources
can never be mistaken for the commit it came from. It also drives an
extra immutable tag on every target:

```
…/pytorch:2.14.1-10.1.0-full-gfx950-g<sha>
```

`BUILD_DATE` is the commit's own timestamp, not "now", for the same
reason `SOURCE_DATE_EPOCH` is pinned.

## Checking it still holds

The [warm benchmark scenario](../performance/index.md#warm) exists
entirely as a standing check on this. Under the current design a new
commit should cost nothing, so warm should build exactly what hot
builds. The result is the assertion rather than the number: if warm ever
diverges from hot, some per-commit value has found its way back into an
image digest. That has happened twice.
