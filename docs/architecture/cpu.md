# CPU Serving: Real Tokens, No GPU

The ROCm serving stack needs a card. The [emulated one](emulation.md)
needs none, but loads no weights and emits a filler token. This lane is
the one in between: **vLLM and LMCache built for CPU, serving a real
model**, with weights loaded, a real forward pass, and KV blocks that
go to LMCache and come back.

```bash
make cpu-load      # build both images into the local docker daemon
make cpu-test      # serve a model, check the answer and the cache
```

## What It Is

Two images and two wheels, the bake group `cpu`, from
[`docker/Dockerfile.vllm-cpu`][df-vllm] and
[`docker/Dockerfile.lmcache-cpu`][df-lmcache]: vLLM v0.33.0 built with
`VLLM_TARGET_DEVICE=cpu`, LMCache v0.5.7 built with `NO_GPU_EXT=1`,
both on `torch==2.15.0+cpu`. No ROCm, NIXL, CuPy, AITER or ATOM
anywhere in it, and no `${ARCH}` in any tag.

| | `emu` | `cpu` | ROCm (`vllm`, `lmcache`) |
| --- | --- | --- | --- |
| Loads weights | no | yes | yes |
| Real tokens | no — a fixed filler token | yes | yes |
| Device latency | replayed from a profile pack | none | real |
| KV blocks through LMCache | no | yes | yes |
| Needs a card | no | no | yes |
| Tested end to end | yes, in CI | yes, on a local daemon; [the workflow][ci] has not run yet | not in CI — `make serve-test` on a GPU node |

So the two GPU-free lanes are complements. `emu` has timing and no
tokens; this has tokens and no timing. Neither says anything about a
ROCm kernel.

## How It Is Built

The non-obvious parts:

- **No ISA flag, because there is none to set.** At this ref the x86
  build always compiles three variants of its kernels with fixed
  flags — `_C` (AVX-512 + BF16 + VNNI + AMX), `_C_AVX512` and `_C_AVX2`
  — and picks one at runtime from CPUID. Nothing is `-march=native`.
  The floor is AVX2. The build asserts all three are in the wheel, and
  the image build loads `_C_AVX2` by name and computes with it.
- **`numactl-devel` is the one thing the manylinux base lacks.** Without
  it the build stops at `fatal error: numa.h: No such file or
  directory`. `auditwheel repair` then grafts `libnuma` into the wheel,
  which is not optional: `python:3.14-slim` has no system copy.
- **torch is consumed, not built.** The lane's point is to need nothing
  from the fleet, and PyTorch publishes `2.15.0+cpu` for cp314. Both
  wheels pin it: vLLM's `requirements/cpu.txt` is moved from
  `2.14.0+cpu`, and LMCache's bare `torch` — which alone resolves
  PyPI's CUDA build, under extensions that link `libtorch_cpu` — becomes
  `torch==2.15.0+cpu`. The build fails if either `sed` matches nothing.
- **The version keeps `+cpu`.** It is how vLLM selects `CpuPlatform`;
  the image build asserts that with `VLLM_TARGET_DEVICE` unset, which
  is how an installed wheel runs. Every other platform imports
  `vllm._C` unconditionally (read from source), and that extension is a
  SIGILL — not an `ImportError` — without AVX-512 (measured on the bare
  extension under qemu, not through the package). The image sets
  `VLLM_TARGET_DEVICE=cpu` as well. LMCache is versioned
  `0.5.7+cpu` to match. Note `vllm.__version__` says `0.33.0`; the
  suffix is in the distribution version (`vllm --version`).
- **No Rust frontend.** With no `rustc` on `PATH`, `setup.py` skips the
  optional `vllm-rs` binary.
- **The runtime image carries `g++`** (+277 MB). vLLM's CPU path
  compiles at serve time. With no compiler the default mode dies in
  warmup (`InvalidCxxCompiler: No working C++ compiler found`), and
  `--enforce-eager` only moves the failure to the first request
  (`Failed to find C compiler`, HTTP 500).
- **vLLM and LMCache are installed in one resolve.** One after the
  other, LMCache's `opentelemetry-api<=1.40` cap leaves `pip check`
  failing.

### The connector on CPU

`serving/docker-compose.cpu.yml` passes the bare
`"kv_connector":"LMCacheMPConnector"`. With LMCache installed vLLM
resolves that to LMCache's own class (`Using external
LMCacheMPConnector`); no `kv_connector_module_path` is needed. Measured
on a repeated 1280-token prefix:

| Configuration | Result |
| --- | --- |
| `TRANSFER_MODE=lmcache_driven` (default) | works — stored in 0.021 s, retrieved in 0.014 s; moves vLLM's whole KV cache into `/dev/shm`, so `SHM_SIZE` must exceed `KV_CACHE_GB`. The default so the lane exercises the shared-memory IPC path |
| `TRANSFER_MODE=engine_driven` | works — 0.191 s and 0.050 s, inline over ZMQ, no shared memory |
| `TRANSFER_MODE=auto` | works; the worker picks `engine_driven` |
| `LMCACHE_USE_UPSTREAM_MP=1` | dies at startup: `TypeError: LMCacheMPSchedulerAdapter.__init__() got an unexpected keyword argument 'server_url'` |
| server `lmcache_driven`, worker `auto` | dies at startup: `LMCache server rejected RPC 'register_kv_cache_engine_driven_context' (operation_not_enabled)` |

The last row is why one variable sets the mode on both services.

## Running It

```bash
make cpu-load                    # vllm-cpu and lmcache-cpu, into the local daemon
make cpu-serve                   # compose up on THIS machine, port 8000
make cpu-logs CPU_LOG_ARGS='-f vllm'
make cpu-down
make cpu-test CPU_TEST_ARGS=--l2 # its own project and port (8012)
```

`BUILDER` defaults to a fleet builder; off the fleet, pass your own.
The compose file owns the runtime defaults, the model included
(`HuggingFaceTB/SmolLM2-135M-Instruct`; `CPU_SERVE_MODEL=` overrides
it). The ones worth knowing: `KV_TIER=cpu|file`, `TRANSFER_MODE`,
`KV_CACHE_GB` (1 — unset, vLLM sizes the KV cache from 92% of RAM,
its default `--gpu-memory-utilization`; read from source, not measured),
`KV_OFFLOAD=0` for a no-connector baseline, `VLLM_EXTRA_ARGS`, and
`CPUSET` / `VLLM_MEM_LIMIT` / `LMCACHE_MEM_LIMIT` to make a large
machine look like a 4 vCPU runner. With the defaults: vLLM 3.7–3.9 GiB,
LMCache about 1.4 GiB, 67–76 s to healthy on four cores of an AVX-512
host. `VLLM_EXTRA_ARGS=--enforce-eager` cuts that to 27 s and puts a
~5 s kernel compile on the first request.

### On The Serving Host

Those rules use this machine's docker daemon, which is what CI and a
laptop have. The `serve-*` rules run the same compose file on
`GPU_HOST` instead, over `DOCKER_HOST=ssh://`, when given
`SERVE_DEVICE=cpu`:

```bash
make serve-stack SERVE_DEVICE=cpu VLLM_DEV_MODE=1 \
     KV_TIER=file KV_STORE=/mnt/kv-nvme/rocm-bake-l2
make serve-test  SERVE_DEVICE=cpu    # also serve-test-l2, serve-test-baseline
make serve-logs
make serve-down  SERVE_DEVICE=cpu
```

- **Pass it to every rule.** The CPU stack is its own compose project,
  `rocm-serving-cpu`, so `serve-down` without it stops the ROCm one.
  `VLLM_PORT=8001` moves it off the ROCm stack's port 8000 (`serve-wait`
  run on its own needs that too), but take the CPU stack down before
  running the ROCm `serve-test*`: `serve-test.sh` picks LMCache
  containers by name, so it would read the CPU stack's log and, for
  `serve-test-l2`, try to clear the CPU stack's L1.
- **Nothing is asked of the host's GPU.** No `/dev/kfd` probe, no
  `rocminfo`: the tags are `${VLLM_REF}-cpu` and `${LMCACHE_REF}-cpu`,
  and the model is this compose file's default unless `SERVE_MODEL=`
  says otherwise.
- **It pulls before it serves, and stops if it cannot.** The compose
  file has no `pull_policy` because CI loads its images, so a served
  host would otherwise keep its first image for good. `SERVE_PULL=0`
  serves images loaded onto the host by hand.
- **`serve-stack` replaces a running CPU stack**, down then up, once
  the pull has succeeded. vLLM's KV segment sits in LMCache's
  `/dev/shm` and outlives a recreated vllm; `up` on a live stack left
  one behind each time, and the third start died with `Insufficient
  space in /dev/shm`. Settings are not remembered: repeat `KV_TIER`,
  `KV_STORE` and the rest on every `serve-stack`.
- **`serve-test` is `cpu-test.sh --attach`**, not `serve-test.sh`. It
  runs the checks below against the stack already up, reading the
  containers through docker on the host, and starts and stops nothing.
  A host or a project it cannot find is a failure, not a skip.
- **The cache check needs `VLLM_DEV_MODE=1`** on the stack, passed to
  `serve-stack`, not to `serve-test`, and fails saying so without it.
  `serve-test-baseline`, for a stack from `serve-vllm`, skips the cache
  checks; `serve-test-l2` needs `KV_TIER=file` and empties LMCache's
  L1. `KV_TIER` on a `serve-test*` line is ignored: the tier is read
  from the stack.
- `emu-capture-*` refuse: a capture records a card.

### What The Test Checks

[`.builders/cpu-test.sh`][test] starts the stack, tests it and removes
it (`--keep`, `--l2`, `--baseline`, `--attach PROJECT`,
`--endpoint URL`). `/health` and a non-empty completion only prove the
HTTP stack is up, so the checks that matter are the later ones:

| Check | What it proves |
| --- | --- |
| `cpu` | prints this host's ISA flags first, so a SIGILL is attributable |
| `health`, `models`, `completion` | the server is up and serving the model asked for |
| `inference` | a temperature-0 question is answered correctly, and the log shows weights were loaded |
| `same-server` | with `--attach`: the container found through docker is the one that answered — its access log carries this run's tag. Otherwise `--endpoint` at another stack of the same model passes |
| `isa` | which `vllm/_C*.abi3.so` the engine actually mapped |
| `no-device` | no CUDA or HIP in torch, no `/dev/kfd`, no `/dev/dri` |
| `cache` | a repeated prefix is served from LMCache with vLLM's own prefix cache emptied; the answer and every logprob match; LMCache logged the store and the retrieve |
| `l2` | with `--l2`: the file tier holds the blocks and serves them with L1 emptied |

The `cache` check compares the LMCache answer against the one from
vLLM's own prefix cache, not against the first, computed one. Computed
and cached answers differed on 8 of 130 prompts on 32 threads with
nothing wrong; own-cache against LMCache was bit-identical 100 of 100.
With `KV_OFFLOAD=0` the check fails, as it should; `--baseline` says
that was the intent and skips it.

## Installing From The `cpu` Index

```bash
make push-cpu           # the whole group; the only rule that pushes both wheels
make cpu-index          # fetch from Zot, build the PEP 503 index
make cpu-index-check    # install it in a throwaway venv, refuse any nvidia-*
make cpu-publish-dry
make cpu-publish
```

Not published yet: the URL below is where `make cpu-publish` will put
it, and it returns 404 until then.

The index carries vLLM and LMCache and no torch. Two steps, with pip:

```bash
pip install --index-url https://download.pytorch.org/whl/cpu "torch==2.15.0+cpu"

pip install \
  --index-url https://sbates130272.github.io/rocm-bake/data/wheels/cpu/ \
  --extra-index-url https://pypi.org/simple \
  --extra-index-url https://download.pytorch.org/whl/cpu \
  "rocm-torch[device-cpu]"
```

- **Pass both extra indexes.** The vLLM wheel requires
  `torch==2.15.0+cpu` plus torchvision, torchaudio and torchcodec, and
  their CPU builds are on PyTorch's index only. With torch already
  installed pip does not stop without it: it resolves and takes PyPI's
  builds of those three instead, which this lane has not tested. Only
  with step one skipped as well does it fail, at `Could not find a
  version that satisfies the requirement torch==2.15.0+cpu`.
- **Install through the metapackage, or pin both wheels yourself in one
  command.** An unpinned `vllm` resolves to PyPI's newer CUDA build and
  its `nvidia-*` stack.
- **The metapackage is still called `rocm-torch`.** The name and its
  ROCm-derived version come from the shared publishing machinery.
  `rocm-torch[device-cpu]` pins `vllm==0.33.0+cpu` and
  `lmcache==0.5.7+cpu`; nothing in either contains or needs ROCm.
- **uv refuses it.** vLLM's CPU requirements name `triton-cpu` by direct
  URL, kept as upstream has it. pip fetches it from github.com; uv
  0.13.8 stops with `Package triton was included as a URL dependency`.

It has its own index for the reason `emu` does: `vllm 0.33.0+cpu` must
never sit beside `vllm 0.33.0+rocm101`.

## What It Does Not Tell You

- **Nothing about performance.** No number on this page is a benchmark.
  The timings came from a shared host and say nothing about a GPU or
  about this repo's ROCm stack.
- **The AVX2 path has not run on AVX2-only hardware.** `_C_AVX2` loaded
  and computed one op under `qemu-x86_64 -cpu EPYC-Milan`, and served
  end to end with the CPUID selection forced on an AVX-512 host. Every
  real run here mapped `vllm/_C.abi3.so`. The first hosted runner
  without AVX-512 is the confirmation; `cpu-test.sh` prints which
  variant it got.
- **Not yet run on a hosted runner at all.** [`cpu.yml`][ci] builds
  both images and runs `cpu-test.sh` on a stock runner, and has never
  executed. `CPUSET=0-3` on a fast AVX-512 machine stood in for one;
  build and startup time there are unmeasured.
- **`SERVE_DEVICE=cpu` has run on one serving host.** `serve-stack`
  and `serve-test-l2` passed all 14 checks against snoc-thinkstation
  over `DOCKER_HOST=ssh://`, file tier on a dedicated NVMe. That host
  has AVX-512, like every other machine this lane has run on.
- **The model is tiny.** 135M parameters and one checkable question.
  That proves weights load and tokens are real, not that a model you
  care about fits or is usable on CPU.
- **Bit-identical logprobs held on one model, on AVX-512.** Unverified
  on AVX2 or anything else. If vLLM's own prefix cache is disabled the
  same-answer check reports SKIP, not FAIL.
- **Nothing about the connector on a GPU.** The bare connector name
  resolving to LMCache's class was measured on CPU only.
- **Nothing has been published.** `push-cpu`, `cpu-index` and
  `cpu-publish` have not been run; the index check's recipe passed by
  hand against this lane's wheels in a container, not through `make`.
- **Unverified:** reproducibility of the two wheels;
  `LMCACHE_USE_UPSTREAM_MP=1` with `lmcache_driven`; the reduced op set
  upstream documents for AVX2 hosts (read from source, not exercised);
  Docker Engine older than 25, which lacks the healthchecks'
  `start_interval`.

[df-vllm]: https://github.com/sbates130272/rocm-bake/blob/main/docker/Dockerfile.vllm-cpu
[df-lmcache]: https://github.com/sbates130272/rocm-bake/blob/main/docker/Dockerfile.lmcache-cpu
[test]: https://github.com/sbates130272/rocm-bake/blob/main/.builders/cpu-test.sh
[ci]: https://github.com/sbates130272/rocm-bake/blob/main/.github/workflows/cpu.yml
