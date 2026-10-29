# PyTorch ROCm gfx950 Build - Buildx Bake Definition
# Uses the bare-metal Zot registry on Strix for cache storage; build
# nodes are Strix, snoc-thinkstation and snoc-gaming (see the Makefile)
#
# Targets:
#   pytorch-base  - ROCm base with dev tools
#   pytorch       - Full PyTorch build with deps
#   pytorch-run   - Minimal runtime image
#   pytorch-test  - Build + test in one pass
#   all           - All targets (default)
#
# Usage:
#   docker buildx bake -f bake.hcl                     # build all (local)
#   docker buildx bake -f bake.hcl --push              # build + push to Zot
#   docker buildx bake -f bake.hcl pytorch             # build just pytorch
#   docker buildx bake -f bake.hcl --builder snoc-strix pytorch
#   docker buildx bake -f bake.hcl --builder snoc-think pytorch
#
# Override variables at build time:
#   docker buildx bake -f bake.hcl --set 'target.pytorch.args.PYTORCH_VERSION=2.14.1'
#   docker buildx bake -f bake.hcl --set 'target.pytorch.args.ROCM_VERSION=7.14'

# Bare-metal zot on Strix (zot.service, /etc/zot/config.json), plain HTTP
# on the tailnet. Resolving this name inside a build requires the builder
# to have been created with --driver-opt network=host, which the
# Makefile's builder-* targets do.
variable "REGISTRY" {
  default = "snoc-strix.fold-leaffish.ts.net:8080"
}

variable "REGISTRY_NAME" {
  default = "rocm-pytorch"
}

variable "PYTORCH_VERSION" {
  default = "2.14.1"
}

variable "ROCM_VERSION" {
  default = "10.1.0-full"
}

variable "PYTORCH_ROCM_ARCH" {
  default = "gfx950"
}

variable "USE_AITER" {
  default = "ON"
}

variable "USE_FLYDSL" {
  default = "ON"
}

variable "USE_FLASH_ATTENTION" {
  default = "ON"
}

# Ubuntu 26.04 ships only 3.14 — 3.12 and 3.13 are absent from the
# archive, so an older pin cannot be apt-installed on this base.
variable "PYTHON_VERSION" {
  default = "3.14"
}

variable "GIT_REF" {
  default = ""
}

# Short commit of THIS repo, for an immutable tag alongside the moving
# one. Two builds of the same PyTorch version from different repo states
# otherwise produce identical tags and silently overwrite each other.
# The Makefile passes it; empty means "no repo tag", not "unknown".
# PyTorch v2.14.1's own pins: .ci/docker/triton_version.txt (3.8.0) and
# .ci/docker/ci_commit_pins/triton.txt. Building this commit gives the
# triton PyTorch expects, for ROCm 10.1 instead of AMD's newest
# published channel (7.2.0).
# The release the pinned TRITON_REF belongs to. The ref is a bare SHA
# and carries no version, which is why the published tag used to have
# no version component. Bump both together.
variable "TRITON_VERSION" {
  default = "3.8.0"
}

variable "TRITON_REF" {
  default = "675c59878aa2280b31f722aaf42b825fcee21de8"
}

# ─── Reproducible image timestamps ───────────────────────────────
# BUILD_DATE only reaches the `created` LABEL. The image *config* has a
# `created` field of its own, which BuildKit stamps with nanosecond
# wall-clock time regardless — so two builds of identical content got
# different config digests, different manifest digests, and every
# downstream FROM missed. SOURCE_DATE_EPOCH is what pins that field.
#
# Per image, not per repo. Taking it from HEAD meant every commit gave
# the base a new `created`, hence a new digest, hence a full downstream
# rebuild — even for a commit that only touched the Makefile. Measured:
# Dockerfile.base unchanged between cf70d3c and 87f539e, yet the base
# digest moved 91db3c2e -> aa52684f and nothing downstream could hit.
#
# A constant, not a date derived from history. This was once
# `git log -1 --format=%ct -- Dockerfile.<image>`, on the reasoning
# that an image's timestamp should move only when its own inputs do.
# That used commit history as a proxy for "the inputs changed", and the
# proxy does not hold: squashing 26 commits into 3 made every remaining
# commit touch every Dockerfile, so all five values collapsed to one
# timestamp and every image's cache was invalidated at once. Any
# rebase, squash or filter-branch does this.
#
# Content is what should decide, and content already does — it decides
# the layer digests. The config `created` field carries no information
# anyone reads: the real build date lives in the
# org.opencontainers.image.created label. So pinning it to a constant
# costs nothing and is immune to history being rewritten.
#
# Bump this only to force every image to a new digest deliberately.
variable "SDE_EPOCH" {
  default = "1700000000"
}

# Per image, so a single image can be pinned without the others. Empty
# means "use SDE_EPOCH"; the fallback is resolved in EPOCH_* below.
# This used to default to "" with the arg omitted entirely, which meant
# a bake driven directly — without the Makefile to supply values — got
# BuildKit's wall-clock and lost reproducibility silently. The defaults
# live here now precisely so that cannot happen.
variable "SDE_BASE"    { default = "" }
variable "SDE_PYTORCH" { default = "" }
variable "SDE_TRITON"  { default = "" }
variable "SDE_AITER"   { default = "" }
variable "SDE_RUNTIME" { default = "" }
variable "SDE_NIXL"    { default = "" }
variable "SDE_VLLM"    { default = "" }
variable "SDE_LMCACHE" { default = "" }
variable "SDE_CUPY"    { default = "" }

EPOCH_BASE    = SDE_BASE    != "" ? SDE_BASE    : SDE_EPOCH
EPOCH_PYTORCH = SDE_PYTORCH != "" ? SDE_PYTORCH : SDE_EPOCH
EPOCH_TRITON  = SDE_TRITON  != "" ? SDE_TRITON  : SDE_EPOCH
EPOCH_AITER   = SDE_AITER   != "" ? SDE_AITER   : SDE_EPOCH
EPOCH_RUNTIME = SDE_RUNTIME != "" ? SDE_RUNTIME : SDE_EPOCH
EPOCH_NIXL    = SDE_NIXL    != "" ? SDE_NIXL    : SDE_EPOCH
EPOCH_VLLM    = SDE_VLLM    != "" ? SDE_VLLM    : SDE_EPOCH
EPOCH_LMCACHE = SDE_LMCACHE != "" ? SDE_LMCACHE : SDE_EPOCH
EPOCH_CUPY    = SDE_CUPY    != "" ? SDE_CUPY    : SDE_EPOCH

# Empty means each build derives its own job count from the node it
# lands on, sized by memory rather than cores. Set it to pin one.
variable "MAX_JOBS" {
  default = ""
}

# Compile AITER's kernel modules at build time rather than leaving them
# to JIT on first use. See Dockerfile.aiter for what each level excludes.
#
# Empty means "decide from the architecture" — see PREBUILD_LEVEL below.
# Set it to a level to pin one for every target.
variable "PREBUILD_KERNELS" {
  default = ""
}

# Two-tier layer cache. Reads always consult both the rolling tag and a
# frozen "-ref" baseline; writes go to the rolling tag unless this is
# set to "-ref", which is how the baseline is deliberately refreshed.
# Without it one bad build overwrites the only cache everyone reads.
variable "CACHE_TAG_SUFFIX" {
  default = ""
}

# Stamped into every BuildKit history record name, so records from one
# run can be told apart later. The prefix is this repo's name, not the
# shorter "rpb": the sibling vllm-lmcache project builds on the same
# nodes, uses the same convention, and builds images with the same
# names (pytorch, triton, aiter), so a shared prefix made its builds
# indistinguishable from ours in `make watch`.
#
# Without the run id a cross-run comparison needs the log files, and
# the balancer overwrites /tmp/balance-<target>.log on each run — which
# already cost one measurement.
variable "RUN_ID" {
  default = "dev"
}

variable "AITER_REF" {
  default = "v0.1.27"
}

# ─── Input wiring ────────────────────────────────────────────────
# Targets take their inputs from sibling targets through `target:`
# named contexts. That is bake's dependency mechanism, and the only one
# it has: bake derives the build DAG from these contexts and orders the
# graph itself, which is why asking for `vllm` alone also builds
# pytorch, triton-wheel, aiter-wheel and nixl-wheel, in that order. A
# target with no context on its inputs is, as far as bake is concerned,
# independent — and may run concurrently with the thing it needs.
#
# Set PUBLISHED_INPUTS=1 to resolve those inputs from the registry
# instead. balance.sh needs it: it runs one bake per target, each pinned
# to a different node, and hands results between them through Zot. A
# `target:` context there would rebuild the whole chain on every node
# rather than pulling what the previous stage just pushed.
variable "PUBLISHED_INPUTS" {
  default = ""
}

# The refs each context collapses to under PUBLISHED_INPUTS. These must
# track the `tags` of the target they mirror — a change to one is a
# change to the other.
PUB_BASE    = "${REGISTRY}/${REGISTRY_NAME}/base:${ROCM_VERSION}-${PYTHON_VERSION}"
PUB_PYTORCH = "${REGISTRY}/${REGISTRY_NAME}/pytorch:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}"
PUB_TRITON  = "${REGISTRY}/${REGISTRY_NAME}/triton-wheel:${TRITON_VERSION}-${ROCM_VERSION}"
PUB_AITER   = "${REGISTRY}/${REGISTRY_NAME}/aiter-wheel:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}"
PUB_NIXL    = "${REGISTRY}/${REGISTRY_NAME}/nixl-wheel:${NIXL_REF}-${ROCM_VERSION}-${ARCH_TAG}"
PUB_LMCACHE = "${REGISTRY}/${REGISTRY_NAME}/lmcache-wheel:${LMCACHE_REF}-${ROCM_VERSION}-${ARCH_TAG}"
PUB_CUPY    = "${REGISTRY}/${REGISTRY_NAME}/cupy-wheel:${CUPY_REF}-${ROCM_VERSION}-${ARCH_TAG}"

USE_PUB = PUBLISHED_INPUTS != ""

# ─── Serving stack refs ──────────────────────────────────────────
# All four are release tags, never branches: a moving ref would be
# served from the layer cache indefinitely once built, so an "update"
# would silently be a no-op. Bump them here.
variable "NIXL_REF" {
  default = "v1.5.1"
}

# UCX is built from source inside Dockerfile.nixl because Ubuntu's libucx
# is compiled without ROCm memory-type support; see the comment there.
variable "UCX_REF" {
  default = "v1.22.0"
}

variable "VLLM_REF" {
  default = "v0.32.0"
}

# CuPy, built from source because no published wheel fits: PyPI's
# cupy-rocm-7-0 targets ROCm 7.0 against our 10.1, and plain `cupy`
# ships only an sdist. LMCache's MP server imports it unconditionally.
variable "CUPY_REF" {
  default = "v14.2.0"
}

variable "LMCACHE_REF" {
  default = "v0.5.6"
}

# vLLM v0.32 builds vllm/vllm-rs during setup.py; this tracks the
# channel in its rust-toolchain.toml.
variable "RUST_VERSION" {
  default = "1.95"
}

variable "VCS_REF" {
  default = ""
}

# RFC3339 build time for the OCI created label. Same source.
variable "BUILD_DATE" {
  default = ""
}

variable "SOURCE_URL" {
  default = "https://github.com/sbates130272/rocm-pytorch-build"
}

# gfx950 used to be hardcoded into the tags, so a gfx942 build produced
# an image tagged gfx950. Derive it instead: PYTORCH_ROCM_ARCH is a
# semicolon-separated list, which is not legal in a tag.
ARCH_TAG = replace(PYTORCH_ROCM_ARCH, ";", "_")

# AITER's kernel prebuild is CDNA-only in practice, so the level is
# chosen from the architecture rather than fixed at 2.
#
# On gfx1201 every one of the 13844 kernels compiled and the build then
# failed in the JIT *module* phase: 6 of 68 modules carry CDNA-only code
# — MFMA templates, GFX9 DPP broadcasts ("broadcasts are not supported
# on GFX10+"), CDNA inline asm (v_pk_mul_f32), gfx950/ header trees —
# and setup.py treats a failed module as fatal. bdist_wheel exited 1
# after 51 minutes and no wheel was produced. Reproduced twice.
# Upstream documents this: AITER lists gfx1201 as Experimental, with
# most CK and ASM kernels CDNA-only.
#
# Level 0 costs nothing we can use on RDNA. Those six modules cannot run
# there whatever we do, every other module stays reachable because AITER
# JIT-compiles on first use, and the prebuild is a startup-latency
# optimisation rather than a capability. A wheel that exists beats a
# faster first inference that never happens.
#
# This reverses the reasoning in cbb7186, which set 2 because 0
# "compiles nothing at package time". That still holds on CDNA, which is
# why 2 remains the default there.
#
# Substring test rather than a regex: replace() is already used above,
# and if removing a substring changes the string then it was present.
# PYTORCH_ROCM_ARCH may be a ";"-separated list, so this is true when
# any entry is RDNA.
IS_RDNA = (
  PYTORCH_ROCM_ARCH != replace(PYTORCH_ROCM_ARCH, "gfx11", "") ||
  PYTORCH_ROCM_ARCH != replace(PYTORCH_ROCM_ARCH, "gfx12", "")
)

PREBUILD_LEVEL = PREBUILD_KERNELS != "" ? PREBUILD_KERNELS : (IS_RDNA ? "0" : "2")

# Shared OCI provenance. Without revision and created there is no way to
# work back from a running container to the commit that built it.
#
# Deliberately NOT applied to pytorch-base. Labels live in the image
# config, so a changing revision or created gives the base a new digest
# even when its content is identical — and every downstream FROM then
# invalidates, re-cloning PyTorch's submodule tree and re-running pip on
# every commit. Provenance belongs on the artifacts we ship; the base is
# an intermediate and should stay content-addressed.
OCI_LABELS = {
  "org.opencontainers.image.source"   = SOURCE_URL
  "org.opencontainers.image.revision" = VCS_REF
  "org.opencontainers.image.created"  = BUILD_DATE
}

# What the base gets instead: identity, nothing that varies per build.
BASE_LABELS = {
  "org.opencontainers.image.source" = SOURCE_URL
}

# Provenance attestations record build timestamps, so they differ on
# every build even when the image is byte-identical. Because the
# attestation shares an OCI index with the image manifest, that changes
# the digest a downstream FROM pins, and every layer below it misses.
#
# Measured: two identical base builds produced indexes fd260117 and
# 9c5e5112 wrapped around one unchanged image manifest 91db3c2e. A probe
# RUN missed the cache across those two indexes, while the same digest
# under a different tag hit.
#
# Applied to every image that is a parent or a named context — base,
# pytorch, triton-wheel — and inherited by pytorch-wheel from pytorch.
# pytorch-run and aiter-wheel keep their provenance: nothing builds
# FROM them, so their digests may churn freely.
NO_PROVENANCE = ["type=provenance,disabled=true"]

# Shared compiler cache on Strix (nginx WebDAV, durable on disk).
# Host and port are separate variables because the Makefile needs them
# apart: it resolves the host to an address before handing the endpoint
# to the builders, since in-container DNS for tailnet names proved
# unreliable under load and silently cost most of the cache. See the
# WEBDAV_IP comment in the Makefile.
variable "SCCACHE_WEBDAV_HOST" {
  default = "snoc-strix.fold-leaffish.ts.net"
}

variable "SCCACHE_WEBDAV_PORT" {
  default = "8081"
}

# Empty means "compose it from the host and port above". The Makefile
# sets it to the resolved-address form; anything driving bake directly
# gets the name form, which is correct outside a build container.
variable "SCCACHE_WEBDAV_ENDPOINT" {
  default = ""
}

WEBDAV_ENDPOINT = SCCACHE_WEBDAV_ENDPOINT != "" ? SCCACHE_WEBDAV_ENDPOINT : "http://${SCCACHE_WEBDAV_HOST}:${SCCACHE_WEBDAV_PORT}"

# Key namespace within that store. Overridable so a benchmark can run
# against an isolated prefix and delete it afterwards without touching
# the fleet's objects.
variable "SCCACHE_WEBDAV_KEY_PREFIX" {
  default = "rocm-pytorch"
}

# sccache's stats report a "Cache errors" count but log nothing about
# them at warn, so a run that wants to know what they are has to ask
# for debug. Not the default: debug logs every lookup, and a cold
# triton does 361 of them.
variable "SCCACHE_LOG" {
  default = "warn"
}

# 0.8.0 is the floor for caching hipcc -x hip; see Dockerfile.pytorch.
variable "SCCACHE_VERSION" {
  default = "0.19.0"
}

# There is deliberately no SCCACHE_SERVER_PORT here. The build
# containers address their sccache server over a unix socket instead,
# because network=host made one fixed port shared fleet-wide; see
# Dockerfile.pytorch. The host-level daemon in deploy-sccache.sh still
# uses a port, which is fine: it is not in a container.

# 1 = refuse to start a PyTorch compile with no sccache server, rather
# than spending an hour rebuilding everything uncached.
variable "FORCE_RECACHE" {
  default = "false"
}

variable "REQUIRE_SCCACHE" {
  default = "1"
}

# ─── Shared build attributes ─────────────────────────────────────
# pytorch-test is deliberately absent. Its stage exits 1 when
# torch.cuda.is_available() is false, and a buildkit RUN step has no
# /dev/kfd — the same reason the build logs "no ROCm-capable device is
# detected". It is a verification step for a finished image on a real
# GPU (`make test` on snoc-strix), not something that can run inside the
# build graph, and including it here made build-all and push-all fail at
# the last target every time.
# pytorch-run is deliberately absent. The runtime image is only worth
# publishing where it can be exercised, and no node currently has a
# usable GPU; building it every run costs time and a Zot push for an
# artifact nobody can test. `make push-runtime` still builds it, and it
# belongs back in this list once a GPU node is available.
group "default" {
  targets = [
    "pytorch-base", "pytorch",
    "pytorch-wheel", "triton-wheel", "aiter-wheel",
    "cupy-wheel", "nixl-wheel", "vllm", "vllm-wheel",
    "lmcache", "lmcache-wheel",
  ]
}

# The wheel artifacts. Separate because each builds FROM an image that
# must already be published, so they cannot run from a cold registry.
group "wheels" {
  targets = [
    "pytorch-wheel", "triton-wheel", "aiter-wheel", "nixl-wheel",
    "cupy-wheel", "vllm-wheel", "lmcache-wheel",
  ]
}

# The serving stack: vLLM and LMCache, plus the NIXL wheel both of them
# transfer KV cache through.
#
# Also in `default`, so push-all covers them. The old note here said
# folding them in would make every push-all an hours-long run; that
# argument no longer holds, because STAGE_3 already contains aiter-wheel
# and its kernel prebuild dominates everything else (~50 min on gfx950,
# hours on gfx1201). push-all was already that long.
#
# This group stays as a way to build the serving stack on its own.
group "serving" {
  targets = ["cupy-wheel", "nixl-wheel", "vllm", "vllm-wheel", "lmcache", "lmcache-wheel"]
}

# There was an `attrs = { cache-from/cache-to }` block here pointing at
# a cache:main tag. `attrs` is not a bake keyword, nothing referenced
# it, and bake ignored it silently — Zot has no rocm-pytorch/cache repo
# at all, so it was never written in the lifetime of this file. Each
# target declares its own cache below.

# ─── Base ROCm image with dev toolchain ──────────────────────────
target "pytorch-base" {
  dockerfile = "Dockerfile.base"
  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/base:${ROCM_VERSION}-${PYTHON_VERSION}",
    "${REGISTRY}/${REGISTRY_NAME}/base:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/base:${ROCM_VERSION}-${PYTHON_VERSION}-g${VCS_REF}" : "",
  ])
  labels = merge(BASE_LABELS, {
    "org.opencontainers.image.title"       = "rocm-pytorch base"
    "org.opencontainers.image.description" = "ROCm ${ROCM_VERSION} dev base with Python ${PYTHON_VERSION}"
    "org.opencontainers.image.version"     = "${ROCM_VERSION}-${PYTHON_VERSION}"
  })
  platforms  = ["linux/amd64"]

  # Cache for base layer (apt + common deps)
  cache-from = [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest-ref,mode=max,registry.insecure=true",
  ]
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true,ignore-error=true"]

  args = {
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/base/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    SOURCE_DATE_EPOCH   = EPOCH_BASE
    ROCM_VERSION   = ROCM_VERSION
    PYTHON_VERSION = PYTHON_VERSION
  }

  attest = NO_PROVENANCE

  output = ["type=image,compression=zstd"]
}

# ─── Full PyTorch build ──────────────────────────────────────────
target "pytorch" {
  inherits = ["pytorch-base"]
  dockerfile = "Dockerfile.pytorch"
  # Explicit: without it buildkit builds the LAST stage in the file, so
  # appending the wheel stage silently made this target publish a
  # scratch image with no shell.
  target     = "final"
  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/pytorch:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/pytorch:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/pytorch:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])
  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "rocm-pytorch"
    "org.opencontainers.image.description" = "PyTorch ${PYTORCH_VERSION} for ROCm ${ROCM_VERSION}, ${PYTORCH_ROCM_ARCH}"
    "org.opencontainers.image.version"     = "${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}"
  })
  platforms  = ["linux/amd64"]

  # Inherit base cache + pytorch-specific cache
  cache-from = [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest-ref,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest-ref,mode=max,registry.insecure=true",
  ]
  cache-to = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true,ignore-error=true"]

  # Named context, not a registry ref: bake resolves "target:x" by
  # building x first and feeding its result straight in, so pytorch is
  # buildable in one invocation with its inputs. The same pattern as
  # aiter-wheel below.
  # base-img is the edge that was missing. Dockerfile.pytorch does
  # `FROM ${BASE_IMAGE}` with a registry ref as its ARG default, so
  # without this context pytorch silently built on the last *published*
  # base rather than the one built beside it — and with no edge between
  # them, bake was free to run the two concurrently.
  contexts = USE_PUB ? {} : {
    triton-wheels = "target:triton-wheel"
    base-img      = "target:pytorch-base"
  }

  args = {
    TRITON_WHEEL_IMAGE  = USE_PUB ? PUB_TRITON : "triton-wheels"
    BASE_IMAGE          = USE_PUB ? PUB_BASE : "base-img"
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/pytorch/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    SOURCE_DATE_EPOCH   = EPOCH_PYTORCH
    ROCM_VERSION         = ROCM_VERSION
    PYTORCH_VERSION      = PYTORCH_VERSION
    PYTHON_VERSION       = PYTHON_VERSION
    PYTORCH_ROCM_ARCH    = PYTORCH_ROCM_ARCH
    USE_AITER            = USE_AITER
    USE_FLYDSL           = USE_FLYDSL
    USE_FLASH_ATTENTION  = USE_FLASH_ATTENTION
    GIT_REF              = GIT_REF

    # The compiler-cache settings are build ARGs, not env. A bake target
    # has no `env` attribute — the block that used to sit here was parsed
    # as nothing, which is why no build was ever compiler-cached. The
    # CMAKE_*_COMPILER_LAUNCHER values live in Dockerfile.pytorch; only
    # the port and the strictness toggle are worth overriding here.
    SCCACHE_WEBDAV_ENDPOINT = WEBDAV_ENDPOINT
    SCCACHE_WEBDAV_KEY_PREFIX = SCCACHE_WEBDAV_KEY_PREFIX
    SCCACHE_LOG          = SCCACHE_LOG
    MAX_JOBS            = MAX_JOBS
    SCCACHE_VERSION      = SCCACHE_VERSION
    FORCE_RECACHE        = FORCE_RECACHE
    REQUIRE_SCCACHE      = REQUIRE_SCCACHE
  }

  attest = NO_PROVENANCE

  output = ["type=image,compression=zstd"]
}

# ─── PyTorch wheel artifact ──────────────────────────────────────
# Same idea as the aiter target: the wheel as its own image so it can
# live in Zot and be pulled without rebuilding PyTorch.
target "pytorch-wheel" {
  inherits   = ["pytorch"]
  target     = "wheel"
  dockerfile = "Dockerfile.pytorch"

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/pytorch-wheel:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/pytorch-wheel:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/pytorch-wheel:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "rocm-pytorch wheel"
    "org.opencontainers.image.description" = "torch wheel for ${PYTORCH_ROCM_ARCH}, ROCm ${ROCM_VERSION}"
    "org.opencontainers.image.version"     = "${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}"
  })
}

# ─── Triton wheel ────────────────────────────────────────────────
# Builds FROM the ROCm base, not from pytorch: triton needs cmake<4
# while PyTorch pulls cmake 4.x, so they cannot share an environment.
# That also means it can build in parallel with pytorch on another node.
target "triton-wheel" {
  dockerfile = "Dockerfile.triton"
  platforms  = ["linux/amd64"]
  target     = "wheel"

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/triton-wheel:${TRITON_VERSION}-${ROCM_VERSION}",
    "${REGISTRY}/${REGISTRY_NAME}/triton-wheel:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/triton-wheel:${TRITON_VERSION}-${ROCM_VERSION}-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "triton wheel"
    "org.opencontainers.image.description" = "Triton 3.8.0 built for ROCm ${ROCM_VERSION}, ${PYTORCH_ROCM_ARCH}"
    "org.opencontainers.image.version"     = "${ROCM_VERSION}-${ARCH_TAG}"
  })

  cache-from = [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/triton-wheel-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/triton-wheel-cache:latest-ref,mode=max,registry.insecure=true",
  ]
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/triton-wheel-cache:latest${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true,ignore-error=true"]

  # Same missing edge pytorch had: Dockerfile.triton does
  # `FROM ${BASE_IMAGE}` with a registry ref as its ARG default, so
  # without this it built on the last *published* base and bake saw no
  # reason to order it after pytorch-base.
  contexts = USE_PUB ? {} : {
    base-img = "target:pytorch-base"
  }

  args = {
    BASE_IMAGE          = USE_PUB ? PUB_BASE : "base-img"
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/triton-wheel/noarch/${RUN_ID}"
    SOURCE_DATE_EPOCH   = EPOCH_TRITON
    TRITON_REF          = TRITON_REF
    TRITON_VERSION      = TRITON_VERSION
    ROCM_VERSION        = ROCM_VERSION
    SCCACHE_VERSION     = SCCACHE_VERSION
    SCCACHE_WEBDAV_ENDPOINT = WEBDAV_ENDPOINT
    SCCACHE_WEBDAV_KEY_PREFIX = SCCACHE_WEBDAV_KEY_PREFIX
    SCCACHE_LOG         = SCCACHE_LOG
    MAX_JOBS            = MAX_JOBS
  }

  attest = NO_PROVENANCE

  output = ["type=image,compression=zstd"]
}

# ─── AITER wheel ─────────────────────────────────────────────────
# Not part of the default group: it builds FROM the pytorch image, so it
# only makes sense once that has been pushed. Build it explicitly, and
# on whichever node is free — it is independent of the runtime image.
target "aiter-wheel" {
  dockerfile = "Dockerfile.aiter"
  # Pinned, not left to the last stage in the file: appending a stage
  # to Dockerfile.aiter would otherwise silently repoint this target,
  # which is what happened to "pytorch" before 680b4cc.
  target     = "wheel"
  platforms  = ["linux/amd64"]

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/aiter-wheel:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/aiter-wheel:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/aiter-wheel:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "aiter wheel"
    "org.opencontainers.image.description" = "AITER wheel built against PyTorch ${PYTORCH_VERSION}, ${PYTORCH_ROCM_ARCH}"
    "org.opencontainers.image.version"     = "${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}"
  })

  cache-from = [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/aiter-wheel-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/aiter-wheel-cache:latest-ref,mode=max,registry.insecure=true",
  ]
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/aiter-wheel-cache:latest${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true,ignore-error=true"]

  # Named contexts, not registry refs: bake resolves "target:x" by
  # building x first and feeding its result straight in. That makes
  # aiter-wheel buildable in the same invocation as its inputs, instead
  # of requiring them to be pushed in a previous run.
  contexts = USE_PUB ? {} : {
    pytorch-img   = "target:pytorch"
    triton-wheels = "target:triton-wheel"
  }

  args = {
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/aiter-wheel/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    SOURCE_DATE_EPOCH   = EPOCH_AITER
    PYTORCH_IMAGE       = USE_PUB ? PUB_PYTORCH : "pytorch-img"
    TRITON_WHEEL_IMAGE  = USE_PUB ? PUB_TRITON : "triton-wheels"
    AITER_REF           = AITER_REF
    PREBUILD_KERNELS    = PREBUILD_LEVEL
    SCCACHE_VERSION     = SCCACHE_VERSION
    PYTORCH_ROCM_ARCH   = PYTORCH_ROCM_ARCH
    SCCACHE_WEBDAV_ENDPOINT = WEBDAV_ENDPOINT
    SCCACHE_WEBDAV_KEY_PREFIX = SCCACHE_WEBDAV_KEY_PREFIX
  }

  output = ["type=image,compression=zstd"]
}

# ─── Minimal runtime image ───────────────────────────────────────
target "pytorch-run" {
  dockerfile = "Dockerfile.runtime"
  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/runtime:${PYTORCH_VERSION}-${ROCM_VERSION}",
    "${REGISTRY}/${REGISTRY_NAME}/runtime:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/runtime:${PYTORCH_VERSION}-${ROCM_VERSION}-g${VCS_REF}" : "",
  ])
  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "rocm-pytorch runtime"
    "org.opencontainers.image.description" = "Minimal PyTorch ${PYTORCH_VERSION} runtime for ROCm ${ROCM_VERSION}"
    "org.opencontainers.image.version"     = "${PYTORCH_VERSION}-${ROCM_VERSION}"
  })
  platforms  = ["linux/amd64"]

  # Inherit pytorch build cache
  cache-from = [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/runtime-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/runtime-cache:latest-ref,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest-ref,mode=max,registry.insecure=true",
  ]
  cache-to = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/runtime-cache:latest${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true,ignore-error=true"]

  args = {
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/runtime/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    SOURCE_DATE_EPOCH   = EPOCH_RUNTIME
    PYTHON_VERSION = PYTHON_VERSION
  }

  # "target:pytorch", not a bare registry ref. A context value with no
  # recognised scheme is treated as a local directory, so this used to
  # fail with "stat <registry>/rocm-pytorch/pytorch:...: no such file or
  # directory" — latent until pytorch-run was first built. Referencing
  # the target also removes the need for pytorch to be pushed first, and
  # fixes the hardcoded gfx950 that ignored PYTORCH_ROCM_ARCH.
  # Unlike the others, this context cannot simply be dropped under
  # PUBLISHED_INPUTS: Dockerfile.runtime says `COPY --from=pytorch`,
  # naming the context directly rather than going through an ARG, so the
  # name has to resolve in both modes. It needs the explicit
  # docker-image:// scheme for the reason in the comment above — a bare
  # ref is read as a local directory.
  contexts = USE_PUB ? {
    pytorch = "docker-image://${PUB_PYTORCH}"
  } : {
    pytorch = "target:pytorch"
  }

  output = ["type=image,compression=zstd"]
}

# ─── Build + Test target ─────────────────────────────────────────
target "pytorch-test" {
  inherits = ["pytorch"]
  tags     = ["${REGISTRY}/${REGISTRY_NAME}/pytorch:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}-test"]

  # run-target is not a bake attribute; target selects the stage.
  target = "test"
}

# ─── CuPy wheel ──────────────────────────────────────────────────
# Built FROM the base image rather than pytorch: cupy has no torch
# dependency and only needs ROCm and the venv. Consumed by lmcache,
# whose MP server imports cupy at module scope, and transitively by
# vllm, which installs lmcache.
target "cupy-wheel" {
  dockerfile = "Dockerfile.cupy"
  platforms  = ["linux/amd64"]
  target     = "wheel"

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/cupy-wheel:${CUPY_REF}-${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/cupy-wheel:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/cupy-wheel:${CUPY_REF}-${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "cupy wheel"
    "org.opencontainers.image.description" = "CuPy ${CUPY_REF} for ROCm ${ROCM_VERSION}, ${PYTORCH_ROCM_ARCH}"
    "org.opencontainers.image.version"     = "${CUPY_REF}-${ROCM_VERSION}-${ARCH_TAG}"
  })

  cache-from = [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/cupy-wheel-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/cupy-wheel-cache:latest-ref,mode=max,registry.insecure=true",
  ]
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/cupy-wheel-cache:latest${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true,ignore-error=true"]

  contexts = USE_PUB ? {} : {
    base-img = "target:pytorch-base"
  }

  args = {
    SOURCE_DATE_EPOCH       = EPOCH_CUPY
    BUILDKIT_BUILD_NAME     = "rocm-pytorch-build/cupy-wheel/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    BASE_IMAGE              = USE_PUB ? PUB_BASE : "base-img"
    CUPY_REF                = CUPY_REF
    PYTORCH_ROCM_ARCH       = PYTORCH_ROCM_ARCH
    ROCM_VERSION            = ROCM_VERSION
    SCCACHE_VERSION         = SCCACHE_VERSION
    SCCACHE_WEBDAV_ENDPOINT = WEBDAV_ENDPOINT
    SCCACHE_WEBDAV_KEY_PREFIX = SCCACHE_WEBDAV_KEY_PREFIX
    MAX_JOBS                = MAX_JOBS
  }

  output = ["type=image,compression=zstd"]
}

# ─── NIXL wheel ──────────────────────────────────────────────────
# Builds FROM the pytorch image (NIXL's python bindings compile against
# torch), and ships as a scratch wheel image consumed by both vllm and
# lmcache. UCX is built inside it — see Dockerfile.nixl for why apt's
# libucx is not usable here.
target "nixl-wheel" {
  dockerfile = "Dockerfile.nixl"
  platforms  = ["linux/amd64"]
  target     = "wheel"

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/nixl-wheel:${NIXL_REF}-${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/nixl-wheel:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/nixl-wheel:${NIXL_REF}-${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "nixl wheel"
    "org.opencontainers.image.description" = "NIXL ${NIXL_REF} with ROCm UCX ${UCX_REF}, for ${PYTORCH_ROCM_ARCH}"
    "org.opencontainers.image.version"     = "${NIXL_REF}-${ROCM_VERSION}-${ARCH_TAG}"
  })

  cache-from = [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/nixl-wheel-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/nixl-wheel-cache:latest-ref,mode=max,registry.insecure=true",
  ]
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/nixl-wheel-cache:latest${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true,ignore-error=true"]

  contexts = USE_PUB ? {} : {
    pytorch-img = "target:pytorch"
  }

  args = {
    SOURCE_DATE_EPOCH       = EPOCH_NIXL
    BUILDKIT_BUILD_NAME     = "rocm-pytorch-build/nixl-wheel/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    PYTORCH_IMAGE           = USE_PUB ? PUB_PYTORCH : "pytorch-img"
    NIXL_REF                = NIXL_REF
    UCX_REF                 = UCX_REF
    PYTORCH_ROCM_ARCH       = PYTORCH_ROCM_ARCH
    ROCM_VERSION            = ROCM_VERSION
    SCCACHE_VERSION         = SCCACHE_VERSION
    SCCACHE_WEBDAV_ENDPOINT = WEBDAV_ENDPOINT
    SCCACHE_WEBDAV_KEY_PREFIX = SCCACHE_WEBDAV_KEY_PREFIX
  }

  output = ["type=image,compression=zstd"]
}

# ─── vLLM ────────────────────────────────────────────────────────
# The serving image. Named contexts resolve to targets rather than
# registry refs, so a single bake invocation can build pytorch, triton,
# aiter and nixl and hand each result straight in — same reasoning as
# aiter-wheel.
target "vllm" {
  dockerfile = "Dockerfile.vllm"
  platforms  = ["linux/amd64"]
  target     = "final"

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/vllm:${VLLM_REF}-${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/vllm:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/vllm:${VLLM_REF}-${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "vllm"
    "org.opencontainers.image.description" = "vLLM ${VLLM_REF} on PyTorch ${PYTORCH_VERSION}, ROCm ${ROCM_VERSION}, ${PYTORCH_ROCM_ARCH}"
    "org.opencontainers.image.version"     = "${VLLM_REF}-${ROCM_VERSION}-${ARCH_TAG}"
  })

  cache-from = [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/vllm-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/vllm-cache:latest-ref,mode=max,registry.insecure=true",
  ]
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/vllm-cache:latest${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true,ignore-error=true"]

  contexts = USE_PUB ? {} : {
    pytorch-img    = "target:pytorch"
    triton-wheels  = "target:triton-wheel"
    aiter-wheels   = "target:aiter-wheel"
    nixl-wheels    = "target:nixl-wheel"
    lmcache-wheels = "target:lmcache-wheel"
  }

  args = {
    SOURCE_DATE_EPOCH       = EPOCH_VLLM
    BUILDKIT_BUILD_NAME     = "rocm-pytorch-build/vllm/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    PYTORCH_IMAGE           = USE_PUB ? PUB_PYTORCH : "pytorch-img"
    TRITON_WHEEL_IMAGE      = USE_PUB ? PUB_TRITON : "triton-wheels"
    AITER_WHEEL_IMAGE       = USE_PUB ? PUB_AITER : "aiter-wheels"
    NIXL_WHEEL_IMAGE        = USE_PUB ? PUB_NIXL : "nixl-wheels"
    LMCACHE_WHEEL_IMAGE     = USE_PUB ? PUB_LMCACHE : "lmcache-wheels"
    VLLM_REF                = VLLM_REF
    # Same ref the aiter-wheel target built from: Dockerfile.vllm fetches
    # AITER's requirements.txt at this tag because the wheel does not
    # carry its own runtime dependencies.
    AITER_REF               = AITER_REF
    RUST_VERSION            = RUST_VERSION
    PYTORCH_ROCM_ARCH       = PYTORCH_ROCM_ARCH
    ROCM_VERSION            = ROCM_VERSION
    SCCACHE_VERSION         = SCCACHE_VERSION
    SCCACHE_WEBDAV_ENDPOINT = WEBDAV_ENDPOINT
    SCCACHE_WEBDAV_KEY_PREFIX = SCCACHE_WEBDAV_KEY_PREFIX
  }

  output = ["type=image,compression=zstd"]
}

# ─── vLLM wheel artifact ─────────────────────────────────────────
target "vllm-wheel" {
  inherits   = ["vllm"]
  target     = "wheel"
  dockerfile = "Dockerfile.vllm"

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/vllm-wheel:${VLLM_REF}-${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/vllm-wheel:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/vllm-wheel:${VLLM_REF}-${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "vllm wheel"
    "org.opencontainers.image.description" = "vLLM ${VLLM_REF} wheel for ${PYTORCH_ROCM_ARCH}, ROCm ${ROCM_VERSION}"
    "org.opencontainers.image.version"     = "${VLLM_REF}-${ROCM_VERSION}-${ARCH_TAG}"
  })
}

# ─── LMCache (multi-process) ─────────────────────────────────────
# No aiter context: LMCache's extension is cache movement, not GEMMs,
# and it has no AITER code path.
target "lmcache" {
  dockerfile = "Dockerfile.lmcache"
  platforms  = ["linux/amd64"]
  target     = "final"

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/lmcache:${LMCACHE_REF}-${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/lmcache:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/lmcache:${LMCACHE_REF}-${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "lmcache"
    "org.opencontainers.image.description" = "LMCache ${LMCACHE_REF} multi-process runtime on PyTorch ${PYTORCH_VERSION}, ROCm ${ROCM_VERSION}, ${PYTORCH_ROCM_ARCH}"
    "org.opencontainers.image.version"     = "${LMCACHE_REF}-${ROCM_VERSION}-${ARCH_TAG}"
  })

  cache-from = [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/lmcache-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/lmcache-cache:latest-ref,mode=max,registry.insecure=true",
  ]
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/lmcache-cache:latest${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true,ignore-error=true"]

  contexts = USE_PUB ? {} : {
    pytorch-img   = "target:pytorch"
    triton-wheels = "target:triton-wheel"
    nixl-wheels   = "target:nixl-wheel"
    cupy-wheels   = "target:cupy-wheel"
  }

  args = {
    SOURCE_DATE_EPOCH       = EPOCH_LMCACHE
    BUILDKIT_BUILD_NAME     = "rocm-pytorch-build/lmcache/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    PYTORCH_IMAGE           = USE_PUB ? PUB_PYTORCH : "pytorch-img"
    TRITON_WHEEL_IMAGE      = USE_PUB ? PUB_TRITON : "triton-wheels"
    NIXL_WHEEL_IMAGE        = USE_PUB ? PUB_NIXL : "nixl-wheels"
    CUPY_WHEEL_IMAGE        = USE_PUB ? PUB_CUPY : "cupy-wheels"
    LMCACHE_REF             = LMCACHE_REF
    PYTORCH_ROCM_ARCH       = PYTORCH_ROCM_ARCH
    ROCM_VERSION            = ROCM_VERSION
    SCCACHE_VERSION         = SCCACHE_VERSION
    SCCACHE_WEBDAV_ENDPOINT = WEBDAV_ENDPOINT
    SCCACHE_WEBDAV_KEY_PREFIX = SCCACHE_WEBDAV_KEY_PREFIX
  }

  output = ["type=image,compression=zstd"]
}

# ─── LMCache wheel artifact ──────────────────────────────────────
target "lmcache-wheel" {
  inherits   = ["lmcache"]
  target     = "wheel"
  dockerfile = "Dockerfile.lmcache"

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/lmcache-wheel:${LMCACHE_REF}-${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/lmcache-wheel:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/lmcache-wheel:${LMCACHE_REF}-${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "lmcache wheel"
    "org.opencontainers.image.description" = "LMCache ${LMCACHE_REF} wheel for ${PYTORCH_ROCM_ARCH}, ROCm ${ROCM_VERSION}"
    "org.opencontainers.image.version"     = "${LMCACHE_REF}-${ROCM_VERSION}-${ARCH_TAG}"
  })
}

# ─── Builders ────────────────────────────────────────────────────
# Builders are NOT defined here. `builder` is not a bake HCL block type —
# the blocks that used to sit here were parsed as nothing and silently
# ignored. Builders are created with `docker buildx create`; see the
# builder-* targets in the Makefile, which also pass the buildkitd config
# that teaches each node to reach Zot over plain HTTP.
#
#   make builder-snoc-strix    # snoc-strix: local, gfx950, runs the GPU tests
#   make builder-snoc-think    # snoc-think: snoc-thinkstation over SSH, gfx1201
#   make builder-snoc-gaming   # snoc-gaming: over SSH, gfx1201
#   make builder-snoc-pool     # snoc-pool: all three as one builder
#
# Select one per invocation with --builder:
#   docker buildx bake -f bake.hcl --builder snoc-pool pytorch
