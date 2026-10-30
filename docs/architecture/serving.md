# Serving stack

vLLM, LMCache and NIXL, built from source against this repository's
torch rather than installed from published wheels.

They have to be. Their native extensions link against torch's C++ ABI,
so a wheel built for AMD's ROCm 7.x torch and one built here cannot
share a process — the same constraint that forces AITER to be built
here.

## What gets built

| Target | What it is |
| --- | --- |
| `nixl-wheel` | NIXL plus UCX, compiled from source with `--with-rocm` |
| `cupy-wheel` | CuPy for ROCm; LMCache's MP server imports it at module scope |
| `vllm` / `vllm-wheel` | The serving image and its wheel |
| `lmcache` / `lmcache-wheel` | The multi-process cache runtime and its wheel |

```bash
make push-serving              # nixl + cupy + vllm + lmcache, built and pushed
make build-vllm                # just vLLM, single builder, no push
make build-lmcache             # just LMCache
make fetch-nixl-wheel          # pull a wheel artifact into ./dist
```

Refs are overridable per invocation and default to the latest release of
each:

```bash
make push-serving VLLM_REF=v0.31.0 NIXL_REF=v1.5.0
```

All four refs are release tags, never branches. A moving ref would be
served from the layer cache indefinitely once built, so an "update"
would silently be a no-op.

### NIXL bundles its own UCX

Ubuntu's `libucx` is compiled without ROCm memory-type support, so
without a source build every device-memory transfer bounces through host
staging. `docker/Dockerfile.nixl` compiles UCX with `--with-rocm` and
`auditwheel` bundles it, so installing the wheel is all a consumer
needs. NIXL is built once and consumed by both vLLM and LMCache.

## Running it

`serving/docker-compose.yml` runs vLLM and the LMCache MP server as a
pair over `DOCKER_HOST=ssh://$GPU_HOST`, so the file stays here under
version control while the engine runs on the machine with the GPU.

```bash
make serve-stack               # vLLM + LMCache MP
make serve-vllm                # vLLM alone — the no-offload baseline
make serve-wait                # block until /health answers
make serve-test                # prove the cache is actually working
make serve-test-baseline       # the same, for a serve-vllm stack
make serve-test-l2             # prove the disk tier serves blocks
make serve-logs                # both containers, merged, live
make serve-logs-cache          # the same, filtered to hit/miss/store
make serve-logs-sorted         # a snapshot merged in timestamp order
make serve-status              # what is running on GPU_HOST
make serve-down                # stop and remove
```

The compose file owns the runtime defaults the way `rocm-bake.hcl` owns
the build ones, and the Makefile reads `${NAME:-default}` out of it
rather than keeping a second copy. `make list-vars` prints them with
their source marked `(compose)`.

| Variable | Default | What it does |
| --- | --- | --- |
| `KV_TIER` | `cpu` | `cpu` = L1 only, `file` = L1 plus an L2 on disk |
| `TRANSFER_MODE` | `lmcache_driven` | `auto`, `engine_driven` or `lmcache_driven` |
| `HSA_IPC_LEGACY` | `1` | Required for cross-container HIP IPC |
| `VLLM_DEV_MODE` | `0` | `1` exposes `/reset_prefix_cache`, which `serve-test` needs |
| `L1_SIZE_GB` | `8` | LMCache's host-RAM tier |
| `CHUNK_SIZE` | `256` | Tokens per cached chunk |
| `MAX_MODEL_LEN` | `8192` | |
| `GPU_UTIL` | `0.90` | |
| `SERVE_MODEL` | `Qwen/Qwen2.5-3B-Instruct` | |
| `VLLM_BIND` | `0.0.0.0` from the Makefile, `127.0.0.1` in the compose file | |

A variable is passed only when actually set. An exported empty variable
is still *set*, so `VAR=` would override the compose file's own default
with `""`; `$(if …)` omits it instead.

`VLLM_BIND` differs deliberately. The compose file's `127.0.0.1` is
right for someone running it locally; driving it from another machine
needs the port off loopback. Narrow it again, or tunnel, if the host is
not on a trusted network.

!!! danger "`HSA_ENABLE_IPC_MODE_LEGACY` decides whether this works at all"
    It governs whether the two containers can share KV memory. When it
    is wrong the stack fails at startup, and no amount of
    `TRANSFER_MODE` tuning will fix it.

### The tags come from the GPU host

`SERVE_ARCH` asks `GPU_HOST` which GPU it has, via `rocminfo` over SSH,
the same way `GPU_RENDER_GID` asks it for the render group. The build
default is `gfx950` while the serving host here is a `gfx1201`
RX 9070 XT, and deriving the serving tag from the build architecture
asked Zot for an image nobody had built — the only symptom being a pull
failure naming a plausible-looking tag.

It falls back to the build architecture when the host is unreachable or
has no `rocminfo`, which is the right answer when someone is driving
this against a single machine.

## `/health` is not evidence

LMCache on ROCm has a failure mode where the endpoint serves every
request correctly and caches nothing. In
[LMCache#4419](https://github.com/LMCache/LMCache/issues/4419) a
reporter ran eight days at a zero hit rate with no error anywhere.

`make serve-test` sends the same long prefix twice, requires the second
prefill to be measurably cheaper, and then reads LMCache's own log for
the store and the retrieve — because vLLM's own prefix caching can make
the timing alone look fine.

`serve-test-l2` goes further: it empties LMCache's L1 as well as vLLM's
VRAM between the two requests, so a hit can only have come off disk. It
needs `KV_TIER=file`.

`make serve-logs` merges both containers' streams tagged by container,
rather than using `compose logs`. The useful lines alternate — vLLM says
what it asked for, LMCache says whether it had it — and reading them
apart hid a failure once already: LMCache died on a missing CuPy and
vLLM spent five minutes waiting before reporting a generic engine error.

## Running the images directly

```bash
# vLLM. AITER is installed but off by default.
docker run --rm --device /dev/kfd --device /dev/dri -p 8000:8000 \
    -e VLLM_ROCM_USE_AITER=1 \
    snoc-strix.fold-leaffish.ts.net:8080/rocm-pytorch/vllm:latest \
    serve Qwen/Qwen3-8B

# LMCache's multi-process deployment: a controller holding the
# cluster-wide index, and one or more cache servers holding the blocks.
# The image has no default role — name the CLI you want.
docker run --rm -p 9000:9000 \
    snoc-strix.fold-leaffish.ts.net:8080/rocm-pytorch/lmcache:latest \
    lmcache_controller --host 0.0.0.0 --port 9000

docker run --rm --device /dev/kfd --device /dev/dri -p 8100:8100 \
    snoc-strix.fold-leaffish.ts.net:8080/rocm-pytorch/lmcache:latest \
    lmcache_server 0.0.0.0 8100 cpu
```

!!! warning "The two LMCache CLIs take arguments differently"
    `lmcache_controller` takes flags. `lmcache_server` takes three
    positional arguments — host, port, storage. Giving the server flags
    makes it print a usage line and exit 1.

## Three upstream constraints

**LMCache declares `requires-python >=3.10,<3.14`.** This lane is cp314,
because Ubuntu 26.04 — the only base AMD publishes ROCm 10.1 for —
ships no other Python. The wheel is installed with
`--ignore-requires-python`; the extension is compiled here against this
interpreter, so the ABI matches by construction. Revisit when upstream
raises the bound.

**Both projects' requirement files carry CUDA-only or x86-wheel-only
pins** — `cufile-python`, `nvtx`, `tilelang`, `amd-quark`,
`mooncake-transfer-engine-rocm` and others. These are stripped before
the build, which also keeps them out of the wheel's `install_requires`.
The lists are build args, `VLLM_DROP_REQS` and `LMCACHE_DROP_REQS`, so a
dependency can be let back in once it has a usable wheel.

**`torchvision` is a CUDA wheel in these images, and that is not fixed
here.** `/etc/pip-constraints.txt` pins torch and triton to the ROCm
builds, but there is no ROCm torchvision in this pipeline — it is
resolved from PyPI by `docker/Dockerfile.pytorch`'s optional-extras
step, and vLLM's `requirements/rocm.txt` keeps it reachable through
`timm`. Its `_C_stable.so` links `libtorch_cuda` and `libc10_cuda`, so
`import torchvision` fails at load time. Nothing in the text-model
serving path touches it, which is why the build and the import checks
stay green — but vision and video models will fail at serve time until a
ROCm torchvision is built the way torch and triton are.
