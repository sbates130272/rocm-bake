# Emulated Serving: One vLLM Wheel, No GPU

Every other vLLM artifact here is welded to one card. The HIP
extensions carry code objects for a single architecture, so `gfx950`
and `gfx1201` need separate wheels, separate indexes and separate
releases — and a machine with no supported AMD GPU can install none of
them.

This lane builds the other kind: **one wheel for every architecture,
with no device code at all**, and an emulator that makes it still
serve.

```bash
make push-emu BUILDER=snoc-pool    # build and publish both targets
make emu-load && make emu-test     # serve a model and prove it emulated
```

## What It Is

Two things, built together by
[`docker/Dockerfile.vllm-emu`](https://github.com/sbates130272/rocm-bake/blob/main/docker/Dockerfile.vllm-emu):

**vLLM with no backend.** `VLLM_TARGET_DEVICE=empty` takes `setup.py`
down its `_no_device()` path — no CMake, no HIP, no CUDA, requirements
collapsed to `requirements/common.txt`, and the version suffixed
`+empty`. The result contains no compiled code at all, so it ships as
`py3-none-any`: not merely independent of the card, independent of the
machine.

That is one better than intended. The aim was a manylinux wheel, on
the theory that `setup.py`'s Rust frontend extension would be the one
piece of native code left. It is not: that extension is built with
`optional=not should_require_rust_frontend()` and
`VLLM_REQUIRE_RUST_FRONTEND` is unset, so it is skipped — and it is
opt-in at runtime too (`VLLM_USE_RUST_FRONTEND` defaults to `0`; only
`--grpc-port` and `vllm bench serve` consult it). Forcing it to build
would buy an unused feature at the cost of pinning the wheel to
x86_64. The build decides the tag by looking inside the archive rather
than asserting it, and keeps the auditwheel path for the day upstream
makes the extension mandatory.

**[LLM-Emu](https://github.com/AKafakA/llm-emu).** A profile-driven
emulator, from the MLArchSys@ISCA poster of the same name. It replaces
vLLM's GPU forward pass with a latency draw from a *profile pack*
captured once on real hardware. The scheduler, HTTP stack, admission
control, tokenizer and output pipeline are vLLM's own code, running
unmodified. Weights are never materialised — `GPUModelRunner.load_model`
is stubbed — so nothing is downloaded beyond a model's config and
tokenizer, and nothing is allocated on a device that is not there.

The result serves. It schedules, batches, admits, streams, and answers
`/v1/completions`, on any x86 box.

## Why This Repo Wants It

Three things it buys that nothing else here can:

**A serving lane that can actually be exercised.** No node on the
fleet currently has a usable GPU. `vllm`'s verification stops at "it
imports"; `atom-vllm` ships with its plugin disabled and says so. This
is the only serving artifact in the repo that is tested end to end
before it is published — and the test runs in CI, on a free runner.
See [`.github/workflows/emu.yml`][ci].

**An installable vLLM for machines without AMD hardware.** Laptops,
CI, a developer reading the scheduler. Published under its own index;
see [below](#publishing).

**A scheduler and serving-stack testbed.** Admission policy, batching
behaviour, queueing under load — all of that is vLLM's real code here,
and all of it is observable without a card.

## What It Does Not Tell You

Worth being blunt, because the output looks like a benchmark:

- **It is not a measurement of this repo's stack.** The emulated device
  presents as an **AMD Instinct MI455X** — 432 GiB of HBM4 and 256 CDNA 5
  compute units, AMD's published figures — but every latency in the pack
  was captured on an **NVIDIA A40**. The pack is relabelled, not
  re-measured, and says so in its own `rocm_bake_provenance` block.
  Nothing in it tells you anything about MI455X, gfx1250, our PyTorch,
  our AITER or our Triton. More accurate estimates are expected later;
  until then these are placeholders.
- **The memory figure is a datasheet number, not a measured one.** A
  real device reports less than its nominal capacity once ECC and
  firmware reservations come out — the A40 this pack came from is a
  48 GiB card reporting 47,709,159,424 bytes, which is 44.43 GiB, or
  92.6%. So the KV cache sized from 432 GiB is optimistic, and
  `rocminfo` should replace it as soon as anyone has the part.
- **No kernel runs.** There is nothing here to profile, optimise or
  regress. A faster kernel changes nothing a run reports.
- **No accuracy signal.** The emulator emits a fixed filler token. The
  text coming back is not model output and is not meant to be read.
- **Fidelity is the pack's, not ours.** Upstream reports TPOT and ITL
  within ~1% of real runs and TTFT within ~10% at low request rates —
  for the model and hardware a pack was captured on. Serving a model
  the pack does not describe is extrapolation.

Capturing our own pack needs `StepCycleTracer` and a real GPU, so that
waits for a node with a card.

### The shipped pack is reduced

Upstream's file is 11 MB; the one in the image is 836 KB. Half of that
saving is lossless: `step_cycle_2d_distribution` is a verbatim
duplicate of the prefill and decode tables merged — 46,166 + 232,234 =
278,400 samples — and the oracle never reads it while both of those
exist. The build refuses to drop it when they do not.

The rest is quantisation. Each bucket keeps 64 quantiles of itself
rather than all 556,800 raw measurements, which samples the same
distribution: the oracle draws with `random.choice()`, so a uniform
draw over evenly spaced quantiles is inverse-transform sampling of the
empirical CDF. Min and max are preserved exactly, so the tails survive.
Measured over 20,000 draws per query against the original, medians
agree within 0.01% on the common decode buckets; the worst case is
−0.75% on the median and +2.47% at p95, on the heaviest prefill bucket.

64 is not arbitrary. Adaptive-K pooling grows its neighbourhood until
the cumulative sample count reaches
`VLLM_EMULATOR_ORACLE_MIN_SAMPLES` — default 30 — and counts
`len(samples)`, so anything at or above that floor leaves pooling
decisions unchanged. Below it, the oracle would quietly start merging
neighbouring batch shapes.

### Two known defects in the emulator's output

Found by audit rather than by hitting them, both in LLM-Emu's executor
hook, both non-fatal and both invisible to a short smoke test. Neither
is fixed yet; they are recorded here so results are not read as cleaner
than they are.

**Chunked prefill emits a phantom token.** The hook decides which
requests are mid-prefill by iterating `scheduled_new_reqs` only, so
chunks 2..n of a long prompt — which arrive in `scheduled_cached_reqs`
— are treated as decode steps and get a filler token appended. A prompt
longer than the per-step token budget therefore accumulates extra
output tokens mid-prefill, and can reach `max_tokens` or a stop check
early. Short prompts never hit it.

**Logprobs rows are indexed against the wrong batch.** The hook builds
its `LogprobsLists` arrays with one row per request that produced a
token, while vLLM's scheduler indexes them by position in the full
batch. With logprobs requested and any request mid-prefill in the same
step, rows are attributed to the wrong requests.

## How The Wiring Works

LLM-Emu ships its vLLM integration as a unified diff against vLLM
**0.18.1**; this repo pins **v0.33.0**. Measured against our tag, five
of seven hunks in `vllm/v1/engine/core.py` and one of four in
`vllm/v1/executor/uniproc_executor.py` fail to apply, and the
`scheduler.py` hunk turns out to add an unused import and two blank
lines. Upstream says as much: regenerating the patch is expected on
every vLLM bump.

Doing that each time is what this repo avoids. Instead
[`docker/vllm-emu-shim/`][shim] applies the wiring to vLLM's *classes*
at plugin-load time, through the same meta-path import hook LLM-Emu
already uses for `GPUModelRunner` and `gpu_worker` in `cuda_mock.py`.
Nothing patches vLLM's source, so a `VLLM_REF` bump cannot leave a
stale diff behind.

It also turns out to need far less than the diff carries. Of ~170
patched lines, about 25 matter for emulation:

| What | Where |
| --- | --- |
| attach the executor hook | `UniProcExecutor.__init__` |
| hand the step to the oracle | `UniProcExecutor.execute_model` |
| return the oracle's pending Future | `UniProcExecutor.sample_tokens` |
| release it | `UniProcExecutor.shutdown` |
| survive an empty batch | `EngineCore.step_with_batch_queue` |

The rest is `StepCycleTracer` instrumentation for *capturing* a pack on
a real GPU, which we consume rather than produce.

The third row is not cosmetic: the async engine needs a **pending**
Future while the next batch is scheduled, so the hook's timer Future
has to reach the engine rather than a resolved stand-in.

### When vLLM moves

The shim makes assumptions — that those methods still take `non_block`,
that `EngineCore` still raises `RuntimeError("unexpected error")` on
the empty-batch path. Assumptions in a comment are facts about one day,
so `vllm-emu-selftest` re-measures each of them, the same way
`docker/wheel-verdict.py` re-measures the manylinux verdicts. It runs
inside the image build and again at the top of `make emu-test`, so a
bump that invalidates one fails loudly rather than serving wrongly.

## Publishing

The wheels go out under the pseudo-architecture **`emu`**:

```bash
make emu-index          # fetch from Zot, build the PEP 503 index
make emu-index-check    # install it in a throwaway venv and import it
make emu-publish-dry
make emu-publish        # release + gh-pages index
```

### Installing from it needs a torch

The index does not contain one, and the metapackage does not pin one:

```text
rocm-torch 10.1.0+emu.<digest>  (extra: device-emu)
  llm-emu==0.1.0
  vllm==0.33.0+empty
  vllm-emu-shim==0.1.0
  vllm-emu-pack-gfx1250==0.1.0+<ref>
```

vLLM built with `VLLM_TARGET_DEVICE=empty` resolves its dependencies
from `requirements/common.txt`, which names no torch at all, so nothing
drags one in behind the metapackage. Installing it alone gives you a
vLLM that cannot `import vllm`.

(The fourth wheel is the profile pack. It ships separately from the
shim because a pack describes one device and the shim describes none —
the shim is byte-identical whatever is being emulated, so bundling
would give two devices the same wheel filename with different
contents. The pack registers a `vllm_emu_shim.profile_packs` entry
point and the shim resolves it at interpreter startup, through a
`.pth` file, so installing it is the whole configuration step; install
two and the shim says so and asks you to set
`VLLM_EMULATOR_PROFILE_PACK` yourself. Startup rather than the shim's
own import, because LLM-Emu reads the variable when vLLM loads platform
plugins, which is earlier: resolved any later, the API server and the
engine core disagree about which device they are emulating. The `.pth`
does nothing unless the emulator is switched on.)

That is deliberate rather than an omission. PyPI's torch for linux
x86-64 is the CUDA build, and pinning it would pull the whole `nvidia-*`
dependency set into a lane whose entire point is that it needs no GPU.
Which torch belongs here is yours to choose — the CPU build, or this
repo's ROCm one from a per-card index if you want the emulator beside a
real stack. So the install is two steps:

```bash
pip install --index-url https://download.pytorch.org/whl/cpu torch

pip install \
  --index-url https://sbates130272.github.io/rocm-bake/data/wheels/emu/ \
  --extra-index-url https://pypi.org/simple \
  "rocm-torch[device-emu]"
```

`make emu-index-check` runs exactly that against the freshly built
index, then imports vLLM and runs `vllm-emu-selftest` — because an
index that resolves and cannot run is the failure this check exists to
catch, and `pip list` alone never notices it.

Nothing in `wheelindex.py` or `wheelpublish.sh` inspects the
architecture string beyond using it — it becomes the index directory,
the `device-<arch>` extra, and the release name — so the existing
machinery carries this lane unchanged.

**It is deliberately not in the per-arch indexes.** An index holding
both `vllm 0.33.0+rocm10.1.0` and `vllm 0.33.0+empty` would let pip
resolve the emulator build for someone installing
`rocm-torch[device-gfx950]`: a vLLM that cannot run a kernel, handed to
someone who asked for a card. One name, one index, no overlap — which
is also why `vllm-emu-wheel` is absent from `WHEEL_REPOS`.

## Running It

```bash
docker run --rm -p 8000:8000 \
  snoc-strix.fold-leaffish.ts.net:8080/rocm-pytorch/vllm-emu:latest \
  serve Qwen/Qwen3-8B --host 0.0.0.0 --max-model-len 2048
```

No `--device`, no `/dev/kfd`, no `/dev/dri`. The image sets the
emulator environment itself:

| Variable | Default in the image | |
| --- | --- | --- |
| `VLLM_EMULATOR_ENABLE_ORACLE` | `1` | the master switch; unset, everything is inert and vLLM behaves normally |
| `VLLM_EMULATOR_PROFILE_PACK` | resolved from the installed pack wheel | the step latencies |
| `VLLM_EMULATOR_MOCK_CUDA` | `1` | stub `torch.cuda`, skip weight loading |
| `VLLM_EMULATOR_MODE` | `realtime` | `accelerated` resolves steps immediately for fast simulation |
| `VLLM_EMULATOR_MEMORY` | from the pack | override the emulated device's memory |
| `CUDA_VISIBLE_DEVICES` | `""` | belt and braces — no real device is reachable |

`make emu-test` is the five-check version of the same thing. Its last
two checks are the ones that matter: that no weights were loaded, and
that wall-clock tracked the latencies the oracle predicted. Everything
before them only proves the HTTP stack is alive, which it would be even
if the emulator had never attached.

[ci]: https://github.com/sbates130272/rocm-bake/blob/main/.github/workflows/emu.yml
[shim]: https://github.com/sbates130272/rocm-bake/tree/main/docker/vllm-emu-shim
