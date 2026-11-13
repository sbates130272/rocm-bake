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
#   docker buildx bake -f rocm-bake.hcl                     # build all (local)
#   docker buildx bake -f rocm-bake.hcl --push              # build + push to Zot
#   docker buildx bake -f rocm-bake.hcl pytorch             # build just pytorch
#   docker buildx bake -f rocm-bake.hcl --builder snoc-strix pytorch
#   docker buildx bake -f rocm-bake.hcl --builder snoc-think pytorch
#
# Override variables at build time:
#   docker buildx bake -f rocm-bake.hcl --set 'target.pytorch.args.PYTORCH_VERSION=2.15.0'
#   docker buildx bake -f rocm-bake.hcl --set 'target.pytorch.args.ROCM_VERSION=7.14'

# Bare-metal zot on Strix (zot.service, /etc/zot/config.json), plain HTTP
# on the tailnet. Resolving this name inside a build requires the builder
# to have been created with --driver-opt network=host, which the
# Makefile's builder-* targets do.
variable "REGISTRY" {
  default = "snoc-strix.fold-leaffish.ts.net:8080"
}

# Plain HTTP against the fleet's Zot, which runs without TLS on a
# tailnet. ECR and any other hosted registry are HTTPS with auth, and
# `registry.insecure=true` against one fails the cache export rather
# than falling back to TLS — so a build aimed at ECR sets this false.
variable "REGISTRY_INSECURE" {
  default = "true"
}

variable "REGISTRY_NAME" {
  default = "rocm-pytorch"
}

variable "PYTORCH_VERSION" {
  default = "2.15.0"
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

# PyTorch 2.15 (#188114) adds Composable Kernel SDPA for RDNA4, behind
# USE_ROCM_CK_SDPA_GFX12 — a cmake option that is OFF upstream while the
# backend is new, unlike USE_ROCM_CK_SDPA which is already ON for us.
# gfx1201 is half this fleet, so the knob is worth having; the default
# tracks upstream's rather than our own enthusiasm.
#
# Only meaningful on an RDNA4 target. On gfx950 it builds CK SDPA
# kernels for a GPU class the image will never see; IS_RDNA4 below is
# what keeps ON from meaning that. Set to ON to try it, "" for the
# arch-derived default (currently OFF everywhere).
variable "USE_ROCM_CK_SDPA_GFX12" {
  default = ""
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
# PyTorch v2.15.0's own pins: .ci/docker/triton_version.txt (3.9.0) and
# .ci/docker/ci_commit_pins/triton.txt. Building this commit gives the
# triton PyTorch expects, for ROCm 10.1 instead of AMD's newest
# published channel (7.2.0).
# The release the pinned TRITON_REF belongs to. The ref is a bare SHA
# and carries no version, which is why the published tag used to have
# no version component. Bump both together.
variable "TRITON_VERSION" {
  default = "3.9.0"
}

# Must be the FULL 40-character SHA. Dockerfile.triton clones with
# `git clone --revision`, which does not resolve an abbreviation
# against the remote — a short SHA fails outright with "Remote revision
# ... not found in upstream origin" rather than falling back. The old
# full-clone-then-checkout tolerated an abbreviation, so this is a new
# constraint and the failure comes at clone time, not at build time.
variable "TRITON_REF" {
  default = "aad2a60d958f945420c5c40936b37d411fb02e89"
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
variable "SDE_ROCM"    { default = "" }

# How hard docker/rocm-prune.sh cuts the ROCm SDK down.
#
#   keep-toolchain  hipcc, the ROCm headers, LLVM and the HIP cmake
#                   package under /opt/rocm/lib/cmake all survive
#   minimal         none of them do
#
# keep-toolchain by default, and for every target, because one base
# serves them all and the serving images genuinely need the toolchain:
# AITER JIT-compiles kernels on first use and Triton calls ld.lld out
# of /opt/rocm/llvm/bin.
#
# `minimal` is a measured 0.4 GB better on a 4.4 GB tree — the bulk of
# the saving is the per-architecture kernel libraries, which both
# profiles drop. Giving pytorch-run its own minimal base would mean a
# second base image and a second layer cache per architecture, which
# costs the registry more than the 0.4 GB it saves. So the profile is a
# variable rather than a second target: set it when building a runtime
# image on its own and you want the floor.
variable "ROCM_PRUNE_PROFILE" {
  default = "keep-toolchain"
}
variable "SDE_BASE"    { default = "" }
variable "SDE_PYTORCH" { default = "" }
variable "SDE_TRITON"  { default = "" }
variable "SDE_AITER"   { default = "" }
variable "SDE_RUNTIME" { default = "" }
variable "SDE_NIXL"    { default = "" }
variable "SDE_VLLM"    { default = "" }
variable "SDE_VLLM_EMU" { default = "" }
variable "SDE_LMCACHE" { default = "" }
variable "SDE_CUPY"    { default = "" }
variable "SDE_TORCHVISION" { default = "" }
variable "SDE_ATOM"    { default = "" }

EPOCH_ROCM    = SDE_ROCM    != "" ? SDE_ROCM    : SDE_EPOCH
EPOCH_BASE    = SDE_BASE    != "" ? SDE_BASE    : SDE_EPOCH
EPOCH_PYTORCH = SDE_PYTORCH != "" ? SDE_PYTORCH : SDE_EPOCH
EPOCH_TRITON  = SDE_TRITON  != "" ? SDE_TRITON  : SDE_EPOCH
EPOCH_AITER   = SDE_AITER   != "" ? SDE_AITER   : SDE_EPOCH
EPOCH_RUNTIME = SDE_RUNTIME != "" ? SDE_RUNTIME : SDE_EPOCH
EPOCH_NIXL    = SDE_NIXL    != "" ? SDE_NIXL    : SDE_EPOCH
EPOCH_VLLM    = SDE_VLLM    != "" ? SDE_VLLM    : SDE_EPOCH
EPOCH_VLLM_EMU = SDE_VLLM_EMU != "" ? SDE_VLLM_EMU : SDE_EPOCH
EPOCH_LMCACHE = SDE_LMCACHE != "" ? SDE_LMCACHE : SDE_EPOCH
EPOCH_CUPY    = SDE_CUPY    != "" ? SDE_CUPY    : SDE_EPOCH
EPOCH_TORCHVISION = SDE_TORCHVISION != "" ? SDE_TORCHVISION : SDE_EPOCH
EPOCH_ATOM    = SDE_ATOM    != "" ? SDE_ATOM    : SDE_EPOCH

# Empty means each build derives its own job count from the node it
# lands on, sized by memory rather than cores. Set it to pin one.
variable "MAX_JOBS" {
  default = ""
}

# Compile AITER's kernel modules at build time rather than leaving them
# to JIT on first use. See Dockerfile.aiter for what each level excludes.
#
# Empty means level 0 — see PREBUILD_LEVEL below, which no longer
# decides from the architecture. Set this to pin a level for a build.
#
# Two architectures cannot take level 2, and pinning it there produces
# no wheel at all rather than a slower one:
#
#   gfx1201 (RDNA)  6 of 68 modules carry CDNA-only code — MFMA
#                   templates, GFX9 DPP broadcasts, v_pk_mul_f32 inline
#                   asm, gfx950/ header trees — and setup.py treats a
#                   failed module as fatal. bdist_wheel exited 1 after
#                   51 minutes, twice. Upstream lists gfx1201 as
#                   Experimental with most CK and ASM kernels CDNA-only.
#
#   gfx125x         AITER v0.1.28 against ROCm 10.1 fails ten modules
#                   (module_activation, the blockscale and bpreshuffle
#                   cktile GEMMs, deepgemm, the opus MoE modules,
#                   iq2r_moe, moe_mxfp4_aux). ROCm/aiter#6767 is the
#                   upstream inventory: 18 of 21 build on gfx942 and
#                   fail only on gfx1250. Enablement in progress, not
#                   something to patch around one file at a time — the
#                   CK brace fix in Dockerfile.aiter cleared the first
#                   and the build walked into the next nine.
#
# So a global PREBUILD_KERNELS=2 is only safe on CDNA. On anything else
# pin it per build, or not at all.
variable "PREBUILD_KERNELS" {
  default = ""
}

# Where to fetch the two images this build takes from Docker Hub:
# `ubuntu` and `rocm/dev-ubuntu-26.04`. Empty means Docker Hub itself,
# which is what the fleet does and what every ref in this file resolved
# to before this variable existed.
#
# Set it to an ECR pull-through prefix -- e.g.
# 472426151104.dkr.ecr.us-west-2.amazonaws.com/dockerhub -- and both
# images are fetched through ECR instead, authenticated, same-region,
# and cached in the account after the first pull.
#
# WHY. CodeBuild egresses from a shared AWS IP, and Docker Hub's
# anonymous limit is 100 pulls per 6 hours against that IP across every
# tenant using it. The 2026-11-12 gfx1151 run died two seconds in on a
# 429 resolving `ubuntu:26.04`. buildkitd-nightly.toml mirrors Docker
# Hub through mirror.gcr.io, which covers `ubuntu` and
# `docker/dockerfile` -- but mirror.gcr.io only caches
# frequently-accessed images and proxied `rocm/dev-ubuntu-26.04`
# straight through to another 429 when tested. The 8.67 GB ROCm SDK is
# the one that most needs a cache, so it needs this.
#
# The empty default is load-bearing, not tidiness: a build arg is part
# of a layer's cache key, so a prefix that differs by even a hostname
# invalidates rocm-runtime and pytorch-src for everyone who does not
# set it. `make bake-print` with and without proves they are identical.
variable "DOCKERHUB" {
  default = ""
}

# Two-tier layer cache. Reads always consult both the rolling tag and a
# frozen "-ref" baseline; writes go to the rolling tag unless this is
# set to "-ref", which is how the baseline is deliberately refreshed.
# Without it one bad build overwrites the only cache everyone reads.
#
# A lane may also set this to scope its writes away from the fleet's
# rolling tag -- the nightly sets "-nightly" for exactly that reason.
# Reads of that tier go through cache_own() below; see the note there
# before adding a suffix anywhere new.
variable "CACHE_TAG_SUFFIX" {
  default = ""
}

# The lane's own cache tier, as a cache-from entry, or nothing.
#
# WHY THIS EXISTS. CACHE_TAG_SUFFIX used to scope a lane's *writes*
# only. Nothing read the suffixed tag back, so a lane that set one
# wrote a cache with no reader: the AWS nightly exported ~242 GB to
# ECR every night, and reported 0 CACHED against 561-582 DONE on
# every run from 2026-11-04 to 2026-11-10 -- a "warm" build that
# re-executed every vertex, for its entire life. It could not warm up
# by running more nights, because the 46 refs it imported and the 15
# tags it exported had no member in common. Measured across five
# runs; see .aws-analysis/aws-analysis.md section 5.
#
# This goes FIRST in every cache-from, ahead of the fleet's rolling
# tag and the frozen baseline, so a lane prefers layers it built
# itself and falls back to the shared tiers only for what it has not
# built yet.
#
# An empty suffix yields an empty list, so the fleet's own builds
# resolve to byte-identical cache-from lists to before this existed.
# `make bake-print` is the check.
function "cache_own" {
  params = [repo, arch]
  result = CACHE_TAG_SUFFIX == "" ? [] : [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/${repo}:latest${arch}${CACHE_TAG_SUFFIX},mode=max,registry.insecure=${REGISTRY_INSECURE}",
  ]
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
  default = "v0.1.29"
}

# torchvision, built from source because PyPI publishes it only as a
# CUDA build — the one such thing in this pipeline, and not optional:
# vLLM pulls timm, timm pulls torchvision, and transformers imports
# torchvision.io at module scope. See Dockerfile.torchvision.
#
# 0.29.2 is the newest tag and the right one for torch 2.15: since
# 0.29 torchvision is ABI-stable against torch and its setup.py asks
# only for `torch >= 2.14`, so there is no torch== pin to fight and no
# need for a version that moves in lockstep with PYTORCH_VERSION.
variable "TORCHVISION_REF" {
  default = "v0.29.2"
}

# ATOM — AMD's LLM serving engine, and AITER's largest consumer. Built
# here because there is no ROCm wheel on PyPI and because the point of
# this pipeline is artifacts built against its own torch and its own
# AITER. See docker/Dockerfile.atom for what it is and is not.
#
# v0.1.9 is the newest tag. Note that ATOM declares no `aiter`
# dependency or version range at all, so nothing checks our
# AITER_REF = v0.1.29 against what this tag expects — ATOM dispatches
# into AITER per-op across 701 call sites, so a mismatch surfaces deep
# in one model's path rather than at import. Unassessed, deliberately:
# the import check in Dockerfile.atom is the first thing that would
# catch a gross one.
variable "ATOM_REF" {
  default = "v0.1.9"
}

# Which ATOM to build. Upstream by default; set it to a fork to build a
# branch of ATOM without editing Dockerfile.atom.
#
# The reason a fork exists at all: ATOM v0.1.9's vLLM plugin declares
# VLLM_COMMIT=db9527a4 / VLLM_VERSION=0.31.0 in
# atom/plugin/vllm/vllm-version.env, and this repo pins VLLM_REF=v0.33.0
# — two minor releases ahead. Three symbols moved and one of them also
# changed arity; worse, all seven functions ATOM monkeypatches onto
# vllm.v1.core.kv_cache_utils moved to kv_cache_planning while that
# module itself kept existing, so the installers imported fine and
# patched nothing. See docs/architecture/atom-vllm-skew.md.
#
# Pair this with an ATOM_REF that is a TAG on the fork, not a branch:
# Dockerfile.atom's clone is layer-cached on the ref string, so a branch
# name would be served from cache forever and an "update" would be a
# silent no-op.
variable "ATOM_REPO" {
  default = "https://github.com/ROCm/ATOM.git"
}

# Optional Cargo features for atomesh, ATOM's Rust orchestrator. Empty
# matches upstream: the only non-default feature is ext-proc, which
# needs protoc in the image to compile the Envoy ext_proc protos.
variable "ATOM_MESH_FEATURES" {
  default = ""
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
# ARCH_TAG, because base is no longer architecture-independent: it
# builds FROM rocm-runtime, which carries kernel libraries for one card
# only. Without the arch here a gfx950 base would overwrite a gfx1201
# one at the same tag — the identical bug pytorch-run's tag already
# carries a comment about.
PUB_BASE    = "${REGISTRY}/${REGISTRY_NAME}/base:${ROCM_VERSION}-${PYTHON_VERSION}-${ARCH_TAG}"
PUB_ROCM    = "${REGISTRY}/${REGISTRY_NAME}/rocm-runtime:${ROCM_VERSION}-${ARCH_TAG}"
PUB_PYTORCH = "${REGISTRY}/${REGISTRY_NAME}/pytorch:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}"
# No ARCH_TAG and no ROCM_VERSION, deliberately: v2.15.0's source is
# the same bytes whatever it will be compiled against, so one copy
# serves every architecture and every ROCm. GIT_REF is in the tag
# because it changes which commit was checked out.
PUB_SRC     = "${REGISTRY}/${REGISTRY_NAME}/pytorch-src:${PYTORCH_VERSION}${GIT_REF != "" ? "-g${GIT_REF}" : ""}"
PYTORCH_CACHE_TO = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest${CACHE_ARCH}${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=${REGISTRY_INSECURE},ignore-error=true"]

PUB_PYTORCH_WHEEL = "${REGISTRY}/${REGISTRY_NAME}/pytorch-wheel:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}"
PUB_TRITON  = "${REGISTRY}/${REGISTRY_NAME}/triton-wheel:${TRITON_VERSION}-${ROCM_VERSION}"
PUB_AITER   = "${REGISTRY}/${REGISTRY_NAME}/aiter-wheel:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}"
PUB_NIXL    = "${REGISTRY}/${REGISTRY_NAME}/nixl-wheel:${NIXL_REF}-${ROCM_VERSION}-${ARCH_TAG}"
PUB_LMCACHE = "${REGISTRY}/${REGISTRY_NAME}/lmcache-wheel:${LMCACHE_REF}-${ROCM_VERSION}-${ARCH_TAG}"
PUB_CUPY    = "${REGISTRY}/${REGISTRY_NAME}/cupy-wheel:${CUPY_REF}-${ROCM_VERSION}-${ARCH_TAG}"
PUB_TORCHVISION = "${REGISTRY}/${REGISTRY_NAME}/torchvision-wheel:${TORCHVISION_REF}-${ROCM_VERSION}-${ARCH_TAG}"
PUB_ATOM    = "${REGISTRY}/${REGISTRY_NAME}/atom-wheel:${ATOM_REF}-${ROCM_VERSION}-${ARCH_TAG}"
# The serving image as an input, for atom-vllm, which layers onto it the
# way the wheel targets layer onto pytorch.
PUB_VLLM    = "${REGISTRY}/${REGISTRY_NAME}/vllm:${VLLM_REF}-${ROCM_VERSION}-${ARCH_TAG}"

USE_PUB = PUBLISHED_INPUTS != ""

# ─── Serving stack refs ──────────────────────────────────────────
# All four are release tags, never branches: a moving ref would be
# served from the layer cache indefinitely once built, so an "update"
# would silently be a no-op. Bump them here.
variable "NIXL_REF" {
  default = "v1.5.2"
}

# UCX is built from source inside Dockerfile.nixl because Ubuntu's libucx
# is compiled without ROCm memory-type support; see the comment there.
variable "UCX_REF" {
  default = "v1.22.0"
}

variable "VLLM_REF" {
  default = "v0.33.0"
}

# ─── LLM-Emu — the arch-free lane ────────────────────────────────
# github.com/AKafakA/llm-emu, the emulator behind Dockerfile.vllm-emu.
# It replaces vLLM's GPU forward pass with a latency draw from a
# profile pack, which is what lets this repo build and *exercise* a
# vLLM that is tied to no architecture at all.
#
# A full 40-character SHA, and it has to be: upstream publishes no tags
# and no releases, so there is no stable ref to track. Dockerfile.vllm-emu
# clones with `git clone --revision`, which does not resolve an
# abbreviation against the remote — the same constraint TRITON_REF
# carries, and for the same reason.
#
# b71c602 is HEAD of main as of 2026-08-21. Upstream's own vllm_patches/
# target vLLM 0.18.1 and are NOT used here; see
# docker/vllm-emu-shim/vllm_emu_shim/_patch.py for what replaces them.
variable "LLM_EMU_REF" {
  default = "b71c6025b189784cbd4b926d15afa8257738ea39"
}

# Which llm-emu to build. Upstream by default; point it at a fork to
# build a branch without editing the Dockerfile, the same escape hatch
# ATOM_REPO provides.
variable "LLM_EMU_REPO" {
  default = "https://github.com/AKafakA/llm-emu.git"
}

# Where the arch-free wheel is built. NOT the ROCm base every other
# target uses: Dockerfile.vllm cannot run auditwheel because
# vllm/vllm-rs references GLIBC_2.43 from Ubuntu 26.04, so its wheel is
# linux_x86_64 by necessity. The emu wheel's whole claim is that it
# installs anywhere, so it is built where a manylinux policy is
# actually achievable. Pinned to the image's own tag rather than
# :latest would be better still — quay publishes no digest-stable tag
# per policy, so this is the one place the lane is not fully pinned.
variable "MANYLINUX_IMAGE" {
  default = "quay.io/pypa/manylinux_2_28_x86_64:latest"
}


# CuPy, built from source because no published wheel fits: PyPI's
# cupy-rocm-7-0 targets ROCm 7.0 against our 10.1, and plain `cupy`
# ships only an sdist. LMCache's MP server imports it unconditionally.
variable "CUPY_REF" {
  default = "v14.2.0"
}

variable "LMCACHE_REF" {
  default = "v0.5.7"
}

# vLLM builds vllm/vllm-rs during setup.py; this tracks the channel in
# its rust-toolchain.toml, which v0.33 still pins to 1.95.
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

# Image tags have carried the arch since ARCH_TAG landed, but the cache
# refs did not: every arch-sensitive target wrote
# `<repo>-cache:latest`, so a gfx1201 build overwrote the gfx950 cache
# with layers gfx950 can never hit, and the next gfx950 build rebuilt
# from scratch and did the same back. Alternating archs meant two cold
# builds, every time. Scope the ref by arch so each one keeps its own.
#
# Only targets that take PYTORCH_ROCM_ARCH as an arg use this.
# pytorch-base and triton-wheel compile no device code — Triton is a
# compiler and publishes one noarch wheel, which is why wheelhouse.py
# parses its tags without a gfx component — so they stay on the shared
# ref and are built once for the whole fleet.
CACHE_ARCH = "-${ARCH_TAG}"

# Strip gfx125 before any gfx12 test. gfx1250 and gfx1251 are
# gfx12-numbered but are MI450-class datacenter parts, not RDNA:
# upstream LLVM gates `amdgpu-sched-strategy=coexec` on gfx1250 and
# gfx950 together, and gives gfx1250 tensor instructions no RDNA part
# has. A bare "gfx12" test reads them as RDNA and applies RDNA-only
# settings to a datacenter card.
#
# Substring test rather than a regex: replace() is already used above,
# and if removing a substring changes the string then it was present.
# PYTORCH_ROCM_ARCH may be a ";"-separated list, so this is true when
# any entry matches.
ARCH_RDNA_TEST = replace(PYTORCH_ROCM_ARCH, "gfx125", "")

# Level 0 everywhere, by choice rather than by architecture.
#
# It was already 0 on RDNA and on gfx125x, each for its own reason, and
# those reasons are in the history of this file. CDNA kept 2 because
# that is the class of card the prebuild exists for: it trades build
# time for first-inference latency, and a datacenter part serving a
# model is the case where that trade is worth making.
#
# It is now 0 there too, deliberately, because build time is the
# constraint that actually binds on this fleet. The prebuild compiles
# AITER's kernel modules at package time, and the measured `build
# aiter-wheel 72` in .builders/target-costs is a level-0 figure — it
# comes from run 20261029T204149Z on gfx1201, which was already 0. What
# level 2 costs on CDNA has never been measured here, which is itself
# a reason to stop paying it by default.
#
# Nothing becomes unreachable. AITER JIT-compiles on first use, so the
# modules still exist; they are compiled on the GPU host at first call
# rather than on a builder at package time. The cost moves to the first
# inference, which is the trade being made, and it is reversible for
# one build with PREBUILD_KERNELS=2.
PREBUILD_LEVEL = PREBUILD_KERNELS != "" ? PREBUILD_KERNELS : "0"

# RDNA4 specifically, where IS_RDNA is RDNA3-or-4. Same gfx125x strip:
# gfx1250 is gfx12-numbered and is not RDNA, so it must not pull in a
# cmake option whose whole subject is RDNA4 CK kernels.
IS_RDNA4 = ARCH_RDNA_TEST != replace(ARCH_RDNA_TEST, "gfx12", "")

# An explicit ON on a non-RDNA4 target is still refused: the kernels
# would be dead weight in the image, and upstream gates the option on
# USE_ROCM_CK_SDPA rather than on the architecture, so nothing further
# down would catch it.
CK_SDPA_GFX12 = (
  USE_ROCM_CK_SDPA_GFX12 != "" && IS_RDNA4 ? USE_ROCM_CK_SDPA_GFX12 : "OFF"
)

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
# Applied to every image another target inherits a LAYER STACK from —
# rocm-runtime, pytorch-src, pytorch-base, pytorch (and pytorch-wheel by
# inheritance), triton-wheel. A churned digest there invalidates
# everything built on top.
#
# The wheel artifacts keep their provenance: pytorch-run, aiter-wheel,
# torchvision-wheel, cupy-wheel, nixl-wheel, lmcache-wheel. The older
# note here said "nothing builds FROM them", which was never quite
# true — Dockerfile.vllm does say `FROM ${AITER_WHEEL_IMAGE}`, and the
# same for nixl, lmcache and torchvision. Those stages exist only to be
# bind-mounted from, and each is a `scratch` image holding one wheel, so
# a churned digest re-runs the `pip install` that was going to run
# anyway. There is no layer stack underneath to lose.
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

# ─── sccache on S3, for builds that are not on the fleet ─────────
# The WebDAV store above is nginx on the services node, reachable over
# the tailnet. A rented build machine — CodeBuild, say — has neither,
# so it needs a store that outlives the machine.
#
# Empty by default, and that is the safety property: sccache treats an
# empty SCCACHE_BUCKET as unset and falls back to WebDAV, so the fleet
# is unaffected by these existing. Verified against sccache 0.19.0 —
# unset and "" both select WebDAV, a non-empty bucket selects S3.
#
# Credentials deliberately do NOT appear here. They reach the build as
# a BuildKit secret mounted at /run/secrets/aws, so they never become
# a build arg and never land in image history or an ECR push.
variable "SCCACHE_BUCKET" {
  default = ""
}

variable "SCCACHE_REGION" {
  default = ""
}

# Namespaced separately from the WebDAV prefix: the two stores hold the
# same objects under different keys, and sharing a prefix name between
# them would make an S3 listing look like fleet traffic.
variable "SCCACHE_S3_KEY_PREFIX" {
  default = "rocm-pytorch"
}

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
    "rocm-runtime", "pytorch-src", "pytorch-base", "pytorch",
    "pytorch-wheel", "triton-wheel", "aiter-wheel",
    "torchvision-wheel", "atom-wheel",
    "cupy-wheel", "nixl-wheel", "vllm", "vllm-wheel",
    "lmcache", "lmcache-wheel",
  ]
}

# The wheel artifacts. Separate because each builds FROM an image that
# must already be published, so they cannot run from a cold registry.
group "wheels" {
  targets = [
    "pytorch-wheel", "triton-wheel", "aiter-wheel", "nixl-wheel",
    "torchvision-wheel", "atom-wheel", "cupy-wheel", "vllm-wheel",
    "lmcache-wheel",
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
  targets = ["torchvision-wheel", "cupy-wheel", "nixl-wheel", "vllm", "vllm-wheel", "lmcache", "lmcache-wheel"]
}

# The arch-free emulator lane. See docker/Dockerfile.vllm-emu.
#
# Deliberately in no other group. `default`, `wheels` and `serving` are
# all driven once per architecture — push-all runs them for each entry
# in ARCHES — and these two targets produce ONE artifact for every
# architecture at once. Joining those groups would rebuild and re-push
# identical bytes under identical tags, once per card, and the last
# writer would win a race nobody can observe.
#
# It is also the only group here that needs no GPU, no ROCm and no
# fleet: it builds from a manylinux base in minutes on any x86 node,
# which is what lets .github/workflows/emu.yml run the whole thing —
# build and smoke test — on a stock GitHub runner.
group "emu" {
  targets = ["vllm-emu", "vllm-emu-wheel"]
}

# There was an `attrs = { cache-from/cache-to }` block here pointing at
# a cache:main tag. `attrs` is not a bake keyword, nothing referenced
# it, and bake ignored it silently — Zot has no rocm-pytorch/cache repo
# at all, so it was never written in the lifetime of this file. Each
# target declares its own cache below.

# ─── Slim ROCm base ──────────────────────────────────────────────
# AMD's dev-ubuntu-26.04:10.1.0-full compresses to a single 8.67 GB
# layer carrying kernel libraries for every architecture it supports.
# Each image here is built for one. This target prunes it to that one
# and flattens the result — see docker/rocm-prune.sh — and everything
# downstream builds FROM it rather than from AMD's tag.
#
# Arch-scoped in the tag and in the cache, like every other target that
# compiles for a specific card: the content genuinely differs per
# architecture, and an unqualified tag would have one arch's base
# overwrite another's, which is the bug pytorch-run's tag already
# carries a comment about.
target "rocm-runtime" {
  dockerfile = "docker/Dockerfile.rocm-runtime"
  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/rocm-runtime:${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/rocm-runtime:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/rocm-runtime:${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])
  labels = merge(BASE_LABELS, {
    "org.opencontainers.image.title"       = "rocm-runtime"
    "org.opencontainers.image.description" = "ROCm ${ROCM_VERSION} pruned to ${PYTORCH_ROCM_ARCH}"
    "org.opencontainers.image.version"     = "${ROCM_VERSION}-${ARCH_TAG}"
  })
  platforms = ["linux/amd64"]

  cache-from = distinct(concat(cache_own("rocm-runtime-cache", CACHE_ARCH), [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/rocm-runtime-cache:latest${CACHE_ARCH},mode=max,registry.insecure=${REGISTRY_INSECURE}",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/rocm-runtime-cache:latest${CACHE_ARCH}-ref,mode=max,registry.insecure=${REGISTRY_INSECURE}",
  ]))
  cache-to = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/rocm-runtime-cache:latest${CACHE_ARCH}${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=${REGISTRY_INSECURE},ignore-error=true"]

  args = {
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/rocm-runtime/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    SOURCE_DATE_EPOCH   = EPOCH_ROCM
    ROCM_VERSION        = ROCM_VERSION
    PYTORCH_ROCM_ARCH   = PYTORCH_ROCM_ARCH
    ROCM_PRUNE_PROFILE  = ROCM_PRUNE_PROFILE
    # Byte-identical to Dockerfile.rocm-runtime's own ARG default when
    # DOCKERHUB is empty, so passing it changes no cache key.
    SDK_IMAGE = DOCKERHUB == "" ? "rocm/dev-ubuntu-26.04:${ROCM_VERSION}" : "${DOCKERHUB}/rocm/dev-ubuntu-26.04:${ROCM_VERSION}"
  }

  attest = NO_PROVENANCE

  output = ["type=image,compression=zstd"]
}

# ─── PyTorch source ──────────────────────────────────────────────
# The clone, once, as an artifact. Keyed on PYTORCH_VERSION and
# GIT_REF alone — see docker/Dockerfile.pytorch-src for why, and for
# what it cost to have the clone sitting on top of the base image
# instead.
#
# No arch in the tag and no arch in the cache ref, because there is
# nothing architecture-specific in a source tree. One build serves the
# whole fleet.
target "pytorch-src" {
  dockerfile = "docker/Dockerfile.pytorch-src"
  tags = compact([
    PUB_SRC,
    "${REGISTRY}/${REGISTRY_NAME}/pytorch-src:latest",
  ])
  labels = merge(BASE_LABELS, {
    "org.opencontainers.image.title"       = "pytorch-src"
    "org.opencontainers.image.description" = "PyTorch ${PYTORCH_VERSION} source tree"
    "org.opencontainers.image.version"     = PYTORCH_VERSION
  })
  platforms = ["linux/amd64"]

  cache-from = distinct(concat(cache_own("pytorch-src-cache", ""), [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-src-cache:latest,mode=max,registry.insecure=${REGISTRY_INSECURE}",
  ]))
  cache-to = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-src-cache:latest${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=${REGISTRY_INSECURE},ignore-error=true"]

  args = {
    # noarch in the arch slot rather than omitting it: the name is a
    # four-field contract that history.py splits on, and a
    # three-field one loses its arch and run-id columns. There is
    # genuinely no architecture here, and "noarch" says so.
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/pytorch-src/noarch/${RUN_ID}"
    SOURCE_DATE_EPOCH   = EPOCH_PYTORCH
    PYTORCH_VERSION     = PYTORCH_VERSION
    GIT_REF             = GIT_REF
    # Byte-identical to Dockerfile.pytorch-src's own ARG default when
    # DOCKERHUB is empty, so passing it changes no cache key.
    UBUNTU_IMAGE = DOCKERHUB == "" ? "ubuntu:26.04" : "${DOCKERHUB}/library/ubuntu:26.04"
  }

  attest = NO_PROVENANCE

  output = ["type=image,compression=zstd"]
}

# ─── Base ROCm image with dev toolchain ──────────────────────────
target "pytorch-base" {
  dockerfile = "docker/Dockerfile.base"
  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/base:${ROCM_VERSION}-${PYTHON_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/base:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/base:${ROCM_VERSION}-${PYTHON_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])
  labels = merge(BASE_LABELS, {
    "org.opencontainers.image.title"       = "rocm-pytorch base"
    "org.opencontainers.image.description" = "ROCm ${ROCM_VERSION} dev base with Python ${PYTHON_VERSION}"
    "org.opencontainers.image.version"     = "${ROCM_VERSION}-${PYTHON_VERSION}-${ARCH_TAG}"
  })
  platforms  = ["linux/amd64"]

  # Arch-scoped now, for the same reason the tag is: the apt and pip
  # layers on top are architecture-independent, but the ROCm underneath
  # them is not — so one arch reading another's cache would take the
  # wrong kernel libraries as a hit.
  cache-from = distinct(concat(cache_own("base-cache", CACHE_ARCH), [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest${CACHE_ARCH},mode=max,registry.insecure=${REGISTRY_INSECURE}",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest${CACHE_ARCH}-ref,mode=max,registry.insecure=${REGISTRY_INSECURE}",
  ]))
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest${CACHE_ARCH}${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=${REGISTRY_INSECURE},ignore-error=true"]

  # Same pattern as pytorch's base-img edge below: a named context, so
  # one bake invocation builds the ROCm base and consumes it rather than
  # silently picking up whatever was last published.
  contexts = USE_PUB ? {} : {
    rocm-img = "target:rocm-runtime"
  }

  args = {
    ROCM_BASE_IMAGE     = USE_PUB ? PUB_ROCM : "rocm-img"
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/base/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    SOURCE_DATE_EPOCH   = EPOCH_BASE
    ROCM_VERSION   = ROCM_VERSION
    PYTHON_VERSION = PYTHON_VERSION
  }

  attest = NO_PROVENANCE

  output = ["type=image,compression=zstd"]
}

# ─── Full PyTorch build ──────────────────────────────────────────
# Everything `pytorch` and `pytorch-wheel` share, and nothing either
# one owns. Abstract: it is in no group, so naming a group never builds
# it, and `target` is deliberately unset — each concrete target picks
# its own stage.
#
# This exists because `pytorch` needs a context on `pytorch-wheel` (see
# there) and `pytorch-wheel` used to `inherits = ["pytorch"]`. bake
# MERGES inherited contexts rather than letting a child replace them,
# so the wheel inherited a context pointing at itself and bake refused
# the whole file with "target pytorch-wheel cannot link to itself".
# Overriding `contexts` in the child does not help; only taking the
# inheritance edge off does. Hence a sibling, not a parent.
target "pytorch-common" {
  inherits = ["pytorch-base"]
  dockerfile = "docker/Dockerfile.pytorch"
  platforms  = ["linux/amd64"]

  # Inherit base cache + pytorch-specific cache. Both own-tiers, not
  # just pytorch-cache: this target reads base-cache too, and a lane
  # that rebuilt the base would otherwise import the fleet's copy of
  # it and miss its own.
  cache-from = distinct(concat(cache_own("pytorch-cache", CACHE_ARCH),
                      cache_own("base-cache", CACHE_ARCH), [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest${CACHE_ARCH},mode=max,registry.insecure=${REGISTRY_INSECURE}",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest${CACHE_ARCH}-ref,mode=max,registry.insecure=${REGISTRY_INSECURE}",
    # Transitional: the pre-arch-scoping ref, read-only. Every arch
    # starts cold without it. Delete once each arch in ARCHES has
    # been built once and has a warm ${CACHE_ARCH} cache.
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest,mode=max,registry.insecure=${REGISTRY_INSECURE}",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest,mode=max,registry.insecure=${REGISTRY_INSECURE}",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest-ref,mode=max,registry.insecure=${REGISTRY_INSECURE}",
  ]))
  # cache-to lives on the two concrete targets, not here. CI asserts
  # that a target's cache ref and its tags agree about the arch, and
  # this target has no tags of its own — it inherits pytorch-base's,
  # which are arch-independent — so an arch-scoped cache ref here reads
  # as a real disagreement. It is not one, but the check cannot know
  # that, and the check is worth more than the one line it costs to
  # move. PYTORCH_CACHE_TO keeps the two copies identical.

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
    pytorch-src   = "target:pytorch-src"
  }

  args = {
    TRITON_WHEEL_IMAGE  = USE_PUB ? PUB_TRITON : "triton-wheels"
    BASE_IMAGE          = USE_PUB ? PUB_BASE : "base-img"
    PYTORCH_SRC_IMAGE   = USE_PUB ? PUB_SRC : "pytorch-src"
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/pytorch/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    SOURCE_DATE_EPOCH   = EPOCH_PYTORCH
    ROCM_VERSION         = ROCM_VERSION
    PYTORCH_VERSION      = PYTORCH_VERSION
    PYTHON_VERSION       = PYTHON_VERSION
    PYTORCH_ROCM_ARCH    = PYTORCH_ROCM_ARCH
    USE_AITER            = USE_AITER
    USE_FLYDSL           = USE_FLYDSL
    USE_FLASH_ATTENTION  = USE_FLASH_ATTENTION
    USE_ROCM_CK_SDPA_GFX12 = CK_SDPA_GFX12
    GIT_REF              = GIT_REF

    # The compiler-cache settings are build ARGs, not env. A bake target
    # has no `env` attribute — the block that used to sit here was parsed
    # as nothing, which is why no build was ever compiler-cached. The
    # CMAKE_*_COMPILER_LAUNCHER values live in Dockerfile.pytorch; only
    # the port and the strictness toggle are worth overriding here.
    SCCACHE_WEBDAV_ENDPOINT = WEBDAV_ENDPOINT
    SCCACHE_WEBDAV_KEY_PREFIX = SCCACHE_WEBDAV_KEY_PREFIX
    # Empty on the fleet, which is how WebDAV above stays the backend.
    SCCACHE_BUCKET       = SCCACHE_BUCKET
    SCCACHE_REGION       = SCCACHE_REGION
    SCCACHE_S3_KEY_PREFIX = SCCACHE_S3_KEY_PREFIX
    SCCACHE_LOG          = SCCACHE_LOG
    MAX_JOBS            = MAX_JOBS
    SCCACHE_VERSION      = SCCACHE_VERSION
    FORCE_RECACHE        = FORCE_RECACHE
    REQUIRE_SCCACHE      = REQUIRE_SCCACHE
  }

  attest = NO_PROVENANCE

  output = ["type=image,compression=zstd"]
}

# The runnable image. It takes the torch wheel from `pytorch-wheel`
# rather than compiling its own, which is the whole point of the split
# above.
#
# Both stages used to COPY from `builder`, so `final` dragged the
# builder stage in and ran the compile step a second time. Serialising
# them (49a406b) stopped that being a true double-compile — sccache
# served the second — but the step still ran: measured on the gfx1201
# cold run 20261102T161307Z, 1035s for the wheel then 424s for this.
# Taking the wheel as a context removes the stage from this target
# altogether, so there is nothing left to re-run.
#
# Safe because the wheel image already carries everything `final` took
# from builder: /wheels (the dist) plus build.log and sccache-stats.txt,
# which `make build-report` reads.
target "pytorch" {
  inherits = ["pytorch-common"]
  cache-to = PYTORCH_CACHE_TO
  # Explicit: without it buildkit builds the LAST stage in the file, so
  # appending the wheel stage silently made this target publish a
  # scratch image with no shell.
  target   = "final"

  contexts = USE_PUB ? {} : {
    torch-wheels = "target:pytorch-wheel"
  }

  args = {
    TORCH_WHEEL_IMAGE = USE_PUB ? PUB_PYTORCH_WHEEL : "torch-wheels"
  }

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
}

# ─── PyTorch wheel artifact ──────────────────────────────────────
# Same idea as the aiter target: the wheel as its own image so it can
# live in Zot and be pulled without rebuilding PyTorch.
target "pytorch-wheel" {
  # Its own build record name. Inheriting the parent's meant this
  # target and pytorch shared one, so `docker buildx history` held a
  # single record for both: perftrace.py fetched it twice and the
  # report drew the same bands under both names, while build-status
  # could not tell which of the two a row described. Verified by
  # md5sum on run 20261030T182519Z — trace-pytorch.json and
  # trace-pytorch-wheel.json were byte-identical.
  #
  # Keeps the <repo>/<image>/<arch>/<run-id> shape history.py parses
  # for its arch and run-id columns. Costs nothing to change:
  # BUILDKIT_BUILD_NAME is a reserved frontend arg that no Dockerfile
  # declares, so it reaches no cache key.
  args = {
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/pytorch-wheel/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
  }

  inherits   = ["pytorch-common"]
  cache-to   = PYTORCH_CACHE_TO
  target     = "wheel"
  dockerfile = "docker/Dockerfile.pytorch"

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
  dockerfile = "docker/Dockerfile.triton"
  platforms  = ["linux/amd64"]
  target     = "wheel"

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/triton-wheel:${TRITON_VERSION}-${ROCM_VERSION}",
    "${REGISTRY}/${REGISTRY_NAME}/triton-wheel:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/triton-wheel:${TRITON_VERSION}-${ROCM_VERSION}-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "triton wheel"
    "org.opencontainers.image.description" = "Triton ${TRITON_VERSION} built for ROCm ${ROCM_VERSION}, ${PYTORCH_ROCM_ARCH}"
    "org.opencontainers.image.version"     = "${ROCM_VERSION}-${ARCH_TAG}"
  })

  cache-from = distinct(concat(cache_own("triton-wheel-cache", ""), [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/triton-wheel-cache:latest,mode=max,registry.insecure=${REGISTRY_INSECURE}",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/triton-wheel-cache:latest-ref,mode=max,registry.insecure=${REGISTRY_INSECURE}",
  ]))
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/triton-wheel-cache:latest${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=${REGISTRY_INSECURE},ignore-error=true"]

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
    # Empty on the fleet, which is how WebDAV above stays the backend.
    SCCACHE_BUCKET       = SCCACHE_BUCKET
    SCCACHE_REGION       = SCCACHE_REGION
    SCCACHE_S3_KEY_PREFIX = SCCACHE_S3_KEY_PREFIX
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
  dockerfile = "docker/Dockerfile.aiter"
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

  cache-from = distinct(concat(cache_own("aiter-wheel-cache", CACHE_ARCH), [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/aiter-wheel-cache:latest${CACHE_ARCH},mode=max,registry.insecure=${REGISTRY_INSECURE}",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/aiter-wheel-cache:latest${CACHE_ARCH}-ref,mode=max,registry.insecure=${REGISTRY_INSECURE}",
    # Transitional: the pre-arch-scoping ref, read-only. Every arch
    # starts cold without it. Delete once each arch in ARCHES has
    # been built once and has a warm ${CACHE_ARCH} cache.
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/aiter-wheel-cache:latest,mode=max,registry.insecure=${REGISTRY_INSECURE}",
  ]))
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/aiter-wheel-cache:latest${CACHE_ARCH}${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=${REGISTRY_INSECURE},ignore-error=true"]

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
    # Dockerfile.aiter puts this in the wheel's +rocm local version
    # segment. Without it the ARG default silently wins, so a build with
    # ROCM_VERSION overridden would stamp the wheel with the wrong ROCm.
    ROCM_VERSION        = ROCM_VERSION
    PREBUILD_KERNELS    = PREBUILD_LEVEL
    SCCACHE_VERSION     = SCCACHE_VERSION
    PYTORCH_ROCM_ARCH   = PYTORCH_ROCM_ARCH
    SCCACHE_WEBDAV_ENDPOINT = WEBDAV_ENDPOINT
    SCCACHE_WEBDAV_KEY_PREFIX = SCCACHE_WEBDAV_KEY_PREFIX
    # Empty on the fleet, which is how WebDAV above stays the backend.
    SCCACHE_BUCKET       = SCCACHE_BUCKET
    SCCACHE_REGION       = SCCACHE_REGION
    SCCACHE_S3_KEY_PREFIX = SCCACHE_S3_KEY_PREFIX
  }

  output = ["type=image,compression=zstd"]
}

# ─── torchvision wheel ───────────────────────────────────────────
# Builds FROM the pytorch image, like aiter-wheel, and for the same
# reason: setup.py imports torch to find the HIP toolchain and to
# decide it is building for ROCm at all.
#
# Unlike aiter-wheel this one is a vLLM input rather than an optional
# accelerator — timm pulls torchvision and transformers imports it at
# module scope, so without this target the published vLLM image
# carries PyPI's CUDA build and `import torchvision` fails on ROCm.
# Dockerfile.vllm takes it as a context.
target "torchvision-wheel" {
  dockerfile = "docker/Dockerfile.torchvision"
  # Pinned, not left to the last stage in the file — see aiter-wheel.
  target     = "wheel"
  platforms  = ["linux/amd64"]

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/torchvision-wheel:${TORCHVISION_REF}-${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/torchvision-wheel:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/torchvision-wheel:${TORCHVISION_REF}-${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "torchvision wheel"
    "org.opencontainers.image.description" = "torchvision ${TORCHVISION_REF} built against PyTorch ${PYTORCH_VERSION}, ${PYTORCH_ROCM_ARCH}"
    "org.opencontainers.image.version"     = "${TORCHVISION_REF}-${ROCM_VERSION}-${ARCH_TAG}"
  })

  cache-from = distinct(concat(cache_own("torchvision-wheel-cache", CACHE_ARCH), [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/torchvision-wheel-cache:latest${CACHE_ARCH},mode=max,registry.insecure=${REGISTRY_INSECURE}",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/torchvision-wheel-cache:latest${CACHE_ARCH}-ref,mode=max,registry.insecure=${REGISTRY_INSECURE}",
  ]))
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/torchvision-wheel-cache:latest${CACHE_ARCH}${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=${REGISTRY_INSECURE},ignore-error=true"]

  # No transitional un-arch-scoped cache ref, unlike the targets above:
  # this repo has never been published without ${CACHE_ARCH}, so there
  # is no pre-scoping cache to read and pointing at one would only cost
  # a registry round trip per build.

  contexts = USE_PUB ? {} : {
    pytorch-img = "target:pytorch"
  }

  args = {
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/torchvision-wheel/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    SOURCE_DATE_EPOCH   = EPOCH_TORCHVISION
    PYTORCH_IMAGE       = USE_PUB ? PUB_PYTORCH : "pytorch-img"
    TORCHVISION_REF     = TORCHVISION_REF
    PYTORCH_ROCM_ARCH   = PYTORCH_ROCM_ARCH
    ROCM_VERSION        = ROCM_VERSION
    SCCACHE_VERSION     = SCCACHE_VERSION
    SCCACHE_WEBDAV_ENDPOINT = WEBDAV_ENDPOINT
    SCCACHE_WEBDAV_KEY_PREFIX = SCCACHE_WEBDAV_KEY_PREFIX
    # Empty on the fleet, which is how WebDAV above stays the backend.
    SCCACHE_BUCKET       = SCCACHE_BUCKET
    SCCACHE_REGION       = SCCACHE_REGION
    SCCACHE_S3_KEY_PREFIX = SCCACHE_S3_KEY_PREFIX
    MAX_JOBS            = MAX_JOBS
  }

  output = ["type=image,compression=zstd"]
}

# ─── ATOM wheel artifact ─────────────────────────────────────────
# Arch-scoped in tag and cache like every other target, even though
# nothing in this wheel is architecture-specific — there is no device
# code in it, only a CPU-only Rust cdylib. The scoping is for the
# machinery around it (balance.sh, the cache refs, the perf report),
# which assumes every target is. Dockerfile.atom says the same at
# greater length.
target "atom-wheel" {
  dockerfile = "docker/Dockerfile.atom"
  # Pinned, not left to the last stage in the file — see aiter-wheel.
  target     = "wheel"
  platforms  = ["linux/amd64"]

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/atom-wheel:${ATOM_REF}-${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/atom-wheel:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/atom-wheel:${ATOM_REF}-${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "atom wheel"
    "org.opencontainers.image.description" = "ATOM ${ATOM_REF} built against PyTorch ${PYTORCH_VERSION}, ${PYTORCH_ROCM_ARCH}"
    "org.opencontainers.image.version"     = "${ATOM_REF}-${ROCM_VERSION}-${ARCH_TAG}"
  })

  cache-from = distinct(concat(cache_own("atom-wheel-cache", CACHE_ARCH), [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/atom-wheel-cache:latest${CACHE_ARCH},mode=max,registry.insecure=${REGISTRY_INSECURE}",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/atom-wheel-cache:latest${CACHE_ARCH}-ref,mode=max,registry.insecure=${REGISTRY_INSECURE}",
  ]))
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/atom-wheel-cache:latest${CACHE_ARCH}${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=${REGISTRY_INSECURE},ignore-error=true"]

  # No transitional un-arch-scoped cache ref: this target has never
  # been published, so there is no pre-scoping cache to read and
  # pointing at one would only cost a registry round trip per build.

  contexts = USE_PUB ? {} : {
    pytorch-img = "target:pytorch"
  }

  args = {
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/atom-wheel/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    SOURCE_DATE_EPOCH   = EPOCH_ATOM
    PYTORCH_IMAGE       = USE_PUB ? PUB_PYTORCH : "pytorch-img"
    ATOM_REF            = ATOM_REF
    ATOM_REPO           = ATOM_REPO
    ATOM_MESH_FEATURES  = ATOM_MESH_FEATURES
    PYTORCH_ROCM_ARCH   = PYTORCH_ROCM_ARCH
    ROCM_VERSION        = ROCM_VERSION
    RUST_VERSION        = RUST_VERSION
    SCCACHE_VERSION     = SCCACHE_VERSION
    SCCACHE_WEBDAV_ENDPOINT = WEBDAV_ENDPOINT
    SCCACHE_WEBDAV_KEY_PREFIX = SCCACHE_WEBDAV_KEY_PREFIX
    # Empty on the fleet, which is how WebDAV above stays the backend.
    SCCACHE_BUCKET       = SCCACHE_BUCKET
    SCCACHE_REGION       = SCCACHE_REGION
    SCCACHE_S3_KEY_PREFIX = SCCACHE_S3_KEY_PREFIX
  }

  output = ["type=image,compression=zstd"]
}

# ─── Minimal runtime image ───────────────────────────────────────
target "pytorch-run" {
  dockerfile = "docker/Dockerfile.runtime"
  # ARCH_TAG, like every other artifact. This target takes no
  # PYTORCH_ROCM_ARCH arg — it compiles nothing — but it COPYs the torch
  # wheel out of `pytorch`, so what it ships is as arch-specific as that
  # wheel is. Without the arch here, a gfx1201 runtime overwrote the
  # gfx950 one at the same tag and the only way to tell them apart was
  # the digest. Every other published repo already carried it; this one
  # was missed because its arch arrives through a context rather than
  # an arg.
  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/runtime:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/runtime:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/runtime:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])
  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "rocm-pytorch runtime"
    "org.opencontainers.image.description" = "Minimal PyTorch ${PYTORCH_VERSION} runtime for ROCm ${ROCM_VERSION}, ${PYTORCH_ROCM_ARCH}"
    "org.opencontainers.image.version"     = "${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}"
  })
  platforms  = ["linux/amd64"]

  # Inherit pytorch build cache
  cache-from = distinct(concat(cache_own("runtime-cache", CACHE_ARCH),
                      cache_own("pytorch-cache", CACHE_ARCH), [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/runtime-cache:latest${CACHE_ARCH},mode=max,registry.insecure=${REGISTRY_INSECURE}",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/runtime-cache:latest${CACHE_ARCH}-ref,mode=max,registry.insecure=${REGISTRY_INSECURE}",
    # Transitional: the pre-arch-scoping ref, read-only. Every arch
    # starts cold without it. Delete once each arch in ARCHES has
    # been built once and has a warm ${CACHE_ARCH} cache.
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/runtime-cache:latest,mode=max,registry.insecure=${REGISTRY_INSECURE}",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest${CACHE_ARCH},mode=max,registry.insecure=${REGISTRY_INSECURE}",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest${CACHE_ARCH}-ref,mode=max,registry.insecure=${REGISTRY_INSECURE}",
    # Transitional: the pre-arch-scoping ref, read-only. Every arch
    # starts cold without it. Delete once each arch in ARCHES has
    # been built once and has a warm ${CACHE_ARCH} cache.
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest,mode=max,registry.insecure=${REGISTRY_INSECURE}",
  ]))
  cache-to = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/runtime-cache:latest${CACHE_ARCH}${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=${REGISTRY_INSECURE},ignore-error=true"]

  args = {
    RUNTIME_BASE_IMAGE  = USE_PUB ? PUB_ROCM : "rocm-img"
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
  # rocm-img rides along in both modes for the same reason: it reaches
  # Dockerfile.runtime through an ARG, so under PUBLISHED_INPUTS the
  # published ref is used and the context is not needed — but the
  # unpublished path needs the edge or bake would schedule the two
  # concurrently.
  contexts = USE_PUB ? {
    pytorch = "docker-image://${PUB_PYTORCH}"
  } : {
    rocm-img = "target:rocm-runtime"
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
  dockerfile = "docker/Dockerfile.cupy"
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

  cache-from = distinct(concat(cache_own("cupy-wheel-cache", CACHE_ARCH), [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/cupy-wheel-cache:latest${CACHE_ARCH},mode=max,registry.insecure=${REGISTRY_INSECURE}",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/cupy-wheel-cache:latest${CACHE_ARCH}-ref,mode=max,registry.insecure=${REGISTRY_INSECURE}",
    # Transitional: the pre-arch-scoping ref, read-only. Every arch
    # starts cold without it. Delete once each arch in ARCHES has
    # been built once and has a warm ${CACHE_ARCH} cache.
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/cupy-wheel-cache:latest,mode=max,registry.insecure=${REGISTRY_INSECURE}",
  ]))
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/cupy-wheel-cache:latest${CACHE_ARCH}${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=${REGISTRY_INSECURE},ignore-error=true"]

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
    # Empty on the fleet, which is how WebDAV above stays the backend.
    SCCACHE_BUCKET       = SCCACHE_BUCKET
    SCCACHE_REGION       = SCCACHE_REGION
    SCCACHE_S3_KEY_PREFIX = SCCACHE_S3_KEY_PREFIX
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
  dockerfile = "docker/Dockerfile.nixl"
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

  cache-from = distinct(concat(cache_own("nixl-wheel-cache", CACHE_ARCH), [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/nixl-wheel-cache:latest${CACHE_ARCH},mode=max,registry.insecure=${REGISTRY_INSECURE}",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/nixl-wheel-cache:latest${CACHE_ARCH}-ref,mode=max,registry.insecure=${REGISTRY_INSECURE}",
    # Transitional: the pre-arch-scoping ref, read-only. Every arch
    # starts cold without it. Delete once each arch in ARCHES has
    # been built once and has a warm ${CACHE_ARCH} cache.
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/nixl-wheel-cache:latest,mode=max,registry.insecure=${REGISTRY_INSECURE}",
  ]))
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/nixl-wheel-cache:latest${CACHE_ARCH}${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=${REGISTRY_INSECURE},ignore-error=true"]

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
    # Empty on the fleet, which is how WebDAV above stays the backend.
    SCCACHE_BUCKET       = SCCACHE_BUCKET
    SCCACHE_REGION       = SCCACHE_REGION
    SCCACHE_S3_KEY_PREFIX = SCCACHE_S3_KEY_PREFIX
  }

  output = ["type=image,compression=zstd"]
}

# ─── vLLM ────────────────────────────────────────────────────────
# The serving image. Named contexts resolve to targets rather than
# registry refs, so a single bake invocation can build pytorch, triton,
# aiter, nixl and torchvision and hand each result straight in — same
# reasoning as aiter-wheel.
target "vllm" {
  dockerfile = "docker/Dockerfile.vllm"
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

  cache-from = distinct(concat(cache_own("vllm-cache", CACHE_ARCH), [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/vllm-cache:latest${CACHE_ARCH},mode=max,registry.insecure=${REGISTRY_INSECURE}",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/vllm-cache:latest${CACHE_ARCH}-ref,mode=max,registry.insecure=${REGISTRY_INSECURE}",
    # Transitional: the pre-arch-scoping ref, read-only. Every arch
    # starts cold without it. Delete once each arch in ARCHES has
    # been built once and has a warm ${CACHE_ARCH} cache.
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/vllm-cache:latest,mode=max,registry.insecure=${REGISTRY_INSECURE}",
  ]))
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/vllm-cache:latest${CACHE_ARCH}${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=${REGISTRY_INSECURE},ignore-error=true"]

  contexts = USE_PUB ? {} : {
    pytorch-img    = "target:pytorch"
    triton-wheels  = "target:triton-wheel"
    aiter-wheels   = "target:aiter-wheel"
    nixl-wheels    = "target:nixl-wheel"
    lmcache-wheels = "target:lmcache-wheel"
    torchvision-wheels = "target:torchvision-wheel"
  }

  args = {
    SOURCE_DATE_EPOCH       = EPOCH_VLLM
    BUILDKIT_BUILD_NAME     = "rocm-pytorch-build/vllm/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    PYTORCH_IMAGE           = USE_PUB ? PUB_PYTORCH : "pytorch-img"
    TRITON_WHEEL_IMAGE      = USE_PUB ? PUB_TRITON : "triton-wheels"
    AITER_WHEEL_IMAGE       = USE_PUB ? PUB_AITER : "aiter-wheels"
    NIXL_WHEEL_IMAGE        = USE_PUB ? PUB_NIXL : "nixl-wheels"
    TORCHVISION_WHEEL_IMAGE = USE_PUB ? PUB_TORCHVISION : "torchvision-wheels"
    LMCACHE_WHEEL_IMAGE     = USE_PUB ? PUB_LMCACHE : "lmcache-wheels"
    # Dockerfile.vllm has always declared `ARG MAX_JOBS=`, but this
    # target never passed it, so the one knob that bounds the heaviest
    # compile in the graph could not be set — `MAX_JOBS=8 make
    # push-vllm` was accepted and silently ignored, and the build chose
    # its own job count anyway.
    #
    # Found on gfx1151. Dockerfile.vllm uses MEM_PER_JOB_GB=1, where
    # every other Dockerfile here uses 2, because a measured gfx1201
    # run averaged 0.75GB per job. That arithmetic is right on a 128GB
    # node and wrong on snoc-strix, which has 30GB: the heuristic read
    # 21GB available, chose 20 jobs, and the first of the 7GB outliers
    # the comment at MEM_PER_JOB_GB itself warns about took the build
    # out with ResourceExhausted. Nothing could override it.
    MAX_JOBS                = MAX_JOBS
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
    # Empty on the fleet, which is how WebDAV above stays the backend.
    SCCACHE_BUCKET       = SCCACHE_BUCKET
    SCCACHE_REGION       = SCCACHE_REGION
    SCCACHE_S3_KEY_PREFIX = SCCACHE_S3_KEY_PREFIX
  }

  output = ["type=image,compression=zstd"]
}

# ─── vLLM + ATOM plugin ──────────────────────────────────────────
# The vllm image with ATOM's wheel installed into it, and a build-time
# gate on the version skew between the two. See Dockerfile.atom-vllm for
# what the gate does and — more importantly — what it does not.
#
# Not in ALL_TARGETS and not in the nightly: this lane exists so the
# combination is buildable and measured, not because anything depends on
# it. The plugin ships disabled (ATOM_DISABLE_VLLM_PLUGIN=1) and no model
# has been generated end-to-end through it, because ATOM needs
# gfx942/gfx950/gfx1250 and this fleet has none.
target "atom-vllm" {
  dockerfile = "docker/Dockerfile.atom-vllm"
  target     = "final"
  platforms  = ["linux/amd64"]

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/atom-vllm:${VLLM_REF}-${ATOM_REF}-${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/atom-vllm:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/atom-vllm:${VLLM_REF}-${ATOM_REF}-${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "atom-vllm"
    "org.opencontainers.image.description" = "vLLM ${VLLM_REF} with the ATOM ${ATOM_REF} plugin, ROCm ${ROCM_VERSION}, ${PYTORCH_ROCM_ARCH}"
    "org.opencontainers.image.version"     = "${VLLM_REF}-${ATOM_REF}-${ROCM_VERSION}-${ARCH_TAG}"
  })

  cache-from = [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/atom-vllm-cache:latest${CACHE_ARCH},mode=max,registry.insecure=${REGISTRY_INSECURE}",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/atom-vllm-cache:latest${CACHE_ARCH}-ref,mode=max,registry.insecure=${REGISTRY_INSECURE}",
  ]
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/atom-vllm-cache:latest${CACHE_ARCH}${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=${REGISTRY_INSECURE},ignore-error=true"]

  contexts = USE_PUB ? {} : {
    vllm-img    = "target:vllm"
    atom-wheels = "target:atom-wheel"
  }

  args = {
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/atom-vllm/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    # ATOM's epoch, not vLLM's: the only thing this target builds is the
    # install of the ATOM wheel on top of an image someone else made.
    SOURCE_DATE_EPOCH   = EPOCH_ATOM
    VLLM_IMAGE          = USE_PUB ? PUB_VLLM : "vllm-img"
    ATOM_WHEEL_IMAGE    = USE_PUB ? PUB_ATOM : "atom-wheels"
    VLLM_REF            = VLLM_REF
    ATOM_REF            = ATOM_REF
    ATOM_REPO           = ATOM_REPO
    PYTORCH_ROCM_ARCH   = PYTORCH_ROCM_ARCH
    ROCM_VERSION        = ROCM_VERSION
  }

  output = ["type=image,compression=zstd"]
}

# ─── vLLM wheel artifact ─────────────────────────────────────────
target "vllm-wheel" {
  # Its own build record name. Inheriting the parent's meant this
  # target and vllm shared one, so `docker buildx history` held a
  # single record for both: perftrace.py fetched it twice and the
  # report drew the same bands under both names, while build-status
  # could not tell which of the two a row described. Verified by
  # md5sum on run 20261030T182519Z — trace-pytorch.json and
  # trace-pytorch-wheel.json were byte-identical.
  #
  # Keeps the <repo>/<image>/<arch>/<run-id> shape history.py parses
  # for its arch and run-id columns. Costs nothing to change:
  # BUILDKIT_BUILD_NAME is a reserved frontend arg that no Dockerfile
  # declares, so it reaches no cache key.
  args = {
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/vllm-wheel/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
  }

  inherits   = ["vllm"]
  target     = "wheel"
  dockerfile = "docker/Dockerfile.vllm"

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

# ─── vLLM on the LLM-Emu path (arch-free) ────────────────────────
# One wheel for every architecture: vLLM built with
# VLLM_TARGET_DEVICE=empty, plus LLM-Emu and this repo's shim, so the
# result still serves — from a profile pack rather than a GPU. See
# docker/Dockerfile.vllm-emu for what that buys and what it does not.
#
# NO ARCH_TAG and NO CACHE_ARCH anywhere below, unlike every other
# target that compiles anything. That is not an oversight to be
# tidied: the wheel contains no device code at all (the build asserts
# it), so an arch-qualified tag would assert a property this artifact
# does not have, and an arch-scoped cache would split one build across
# three identical copies. triton-wheel's PUB_TRITON is the existing
# precedent for an unqualified tag — Triton is a compiler and ships one
# noarch wheel, and wheelhouse.py already parses tags without a gfx
# component.
#
# No `contexts` either: nothing in this lane builds FROM anything else
# this repo makes. It is the only target here that can run on a cold
# registry.
target "vllm-emu" {
  dockerfile = "docker/Dockerfile.vllm-emu"
  platforms  = ["linux/amd64"]
  target     = "final"

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/vllm-emu:${VLLM_REF}-emu",
    "${REGISTRY}/${REGISTRY_NAME}/vllm-emu:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/vllm-emu:${VLLM_REF}-emu-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "vllm-emu"
    "org.opencontainers.image.description" = "vLLM ${VLLM_REF} (+empty) on the LLM-Emu ${LLM_EMU_REF} path — no GPU, any architecture"
    "org.opencontainers.image.version"     = "${VLLM_REF}-emu"
  })

  cache-from = distinct(concat(cache_own("vllm-emu-cache", ""), [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/vllm-emu-cache:latest,mode=max,registry.insecure=${REGISTRY_INSECURE}",
  ]))
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/vllm-emu-cache:latest${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=${REGISTRY_INSECURE},ignore-error=true"]

  args = {
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/vllm-emu/noarch/${RUN_ID}"
    SOURCE_DATE_EPOCH   = EPOCH_VLLM_EMU
    MANYLINUX_IMAGE     = MANYLINUX_IMAGE
    PYTHON_VERSION      = PYTHON_VERSION
    VLLM_REF            = VLLM_REF
    LLM_EMU_REF         = LLM_EMU_REF
    LLM_EMU_REPO        = LLM_EMU_REPO
    RUST_VERSION        = RUST_VERSION
    # The same torch version every other lane builds against, taken
    # from the CPU index instead of ROCm's. There was a separate
    # TORCH_CPU_VERSION here, pinned to 2.14.0 to mirror vLLM's own
    # [build-system] requirement; a second torch version in a repo
    # whose entire point is building one is a drift liability, and
    # `make emu-index-check` resolved 2.15.0+cpu against this wheel
    # and imported it cleanly, so the mirror bought nothing.
    PYTORCH_VERSION     = PYTORCH_VERSION
  }

  output = ["type=image,compression=zstd"]
}

# ─── vLLM emu wheel artifact ─────────────────────────────────────
# Three wheels, not one: vllm (+empty, manylinux), llm_emu and
# vllm_emu_shim (both py3-none-any). They are published together
# because installing vllm without the other two gives a serving stack
# with no forward pass — an import that works and a server that cannot
# step.
target "vllm-emu-wheel" {
  # Its own build record name, for the reason spelled out on
  # vllm-wheel: an inherited one makes `docker buildx history` hold a
  # single record for both targets.
  args = {
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/vllm-emu-wheel/noarch/${RUN_ID}"
  }

  inherits   = ["vllm-emu"]
  target     = "wheel"
  dockerfile = "docker/Dockerfile.vllm-emu"

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/vllm-emu-wheel:${VLLM_REF}-emu",
    "${REGISTRY}/${REGISTRY_NAME}/vllm-emu-wheel:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/vllm-emu-wheel:${VLLM_REF}-emu-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "vllm emu wheel"
    "org.opencontainers.image.description" = "vLLM ${VLLM_REF} arch-free wheel, LLM-Emu ${LLM_EMU_REF}, rocm-bake shim"
    "org.opencontainers.image.version"     = "${VLLM_REF}-emu"
  })
}

# ─── LMCache (multi-process) ─────────────────────────────────────
# No aiter context: LMCache's extension is cache movement, not GEMMs,
# and it has no AITER code path.
target "lmcache" {
  dockerfile = "docker/Dockerfile.lmcache"
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

  cache-from = distinct(concat(cache_own("lmcache-cache", CACHE_ARCH), [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/lmcache-cache:latest${CACHE_ARCH},mode=max,registry.insecure=${REGISTRY_INSECURE}",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/lmcache-cache:latest${CACHE_ARCH}-ref,mode=max,registry.insecure=${REGISTRY_INSECURE}",
    # Transitional: the pre-arch-scoping ref, read-only. Every arch
    # starts cold without it. Delete once each arch in ARCHES has
    # been built once and has a warm ${CACHE_ARCH} cache.
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/lmcache-cache:latest,mode=max,registry.insecure=${REGISTRY_INSECURE}",
  ]))
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/lmcache-cache:latest${CACHE_ARCH}${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=${REGISTRY_INSECURE},ignore-error=true"]

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
    # Empty on the fleet, which is how WebDAV above stays the backend.
    SCCACHE_BUCKET       = SCCACHE_BUCKET
    SCCACHE_REGION       = SCCACHE_REGION
    SCCACHE_S3_KEY_PREFIX = SCCACHE_S3_KEY_PREFIX
  }

  output = ["type=image,compression=zstd"]
}

# ─── LMCache wheel artifact ──────────────────────────────────────
target "lmcache-wheel" {
  # Its own build record name. Inheriting the parent's meant this
  # target and lmcache shared one, so `docker buildx history` held a
  # single record for both: perftrace.py fetched it twice and the
  # report drew the same bands under both names, while build-status
  # could not tell which of the two a row described. Verified by
  # md5sum on run 20261030T182519Z — trace-pytorch.json and
  # trace-pytorch-wheel.json were byte-identical.
  #
  # Keeps the <repo>/<image>/<arch>/<run-id> shape history.py parses
  # for its arch and run-id columns. Costs nothing to change:
  # BUILDKIT_BUILD_NAME is a reserved frontend arg that no Dockerfile
  # declares, so it reaches no cache key.
  args = {
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/lmcache-wheel/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
  }

  inherits   = ["lmcache"]
  target     = "wheel"
  dockerfile = "docker/Dockerfile.lmcache"

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
#   make builder-snoc-strix    # snoc-strix: local, gfx1151, hosts Zot + sccache
#   make builder-snoc-think    # snoc-think: snoc-thinkstation over SSH, gfx1201
#   make builder-snoc-gaming   # snoc-gaming: over SSH, gfx1201
#   make builder-snoc-pool     # snoc-pool: all three as one builder
#
# Select one per invocation with --builder:
#   docker buildx bake -f rocm-bake.hcl --builder snoc-pool pytorch
