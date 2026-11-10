# ATOM and vLLM: the skew, and what checks it

ATOM ships a vLLM V1 platform plugin. This repo builds both. They are pinned
independently, they move independently, and until now nothing in either tree
noticed when they moved apart.

## The problem, stated precisely

`ATOM_REF = v0.1.9` declares its target vLLM in
`atom/plugin/vllm/vllm-version.env`:

```
VLLM_COMMIT=db9527a46873454610df6dbedf79a36d6bf1a7f6
VLLM_VERSION=0.31.0
```

`VLLM_REF = v0.33.0`. Two minor releases apart.

Nothing catches that. There is no reference to `vllm.__version__` anywhere
under ATOM's `atom/`, and ATOM's `pyproject.toml` declares no `vllm` dependency
at all, so pip installs any pairing happily. Meanwhile the plugin makes **~320
import sites across 150 distinct private vLLM symbols** and monkeypatches **48
call sites**, almost all into `vllm.v1.*`.

Installing the ATOM wheel next to vLLM is enough to arm it. ATOM's
`pyproject.toml` declares two entry points vLLM discovers automatically:

```
[project.entry-points."vllm.platform_plugins"]  atom = ...:register_platform
[project.entry-points."vllm.general_plugins"]   atom_model_registry = ...:register_model
```

so there is no "install it and decide later".

## Three failure modes, in rising order of nastiness

**Loud.** A symbol moved, the import raises, somebody reads a traceback.

**Silent — the module survived and its contents did not.**
`vllm.v1.core.kv_cache_utils` still exists at 0.33. All seven functions ATOM
monkeypatches onto it (`get_kv_cache_groups`,
`get_kv_cache_config_from_groups`, `_max_memory_usage_bytes_from_groups`,
`_pool_bytes_per_block`, `get_kv_cache_configs`, `_auto_fit_max_model_len`,
`may_override_num_blocks`) moved to `vllm.v1.core.kv_cache_planning`. An
installer guarded by `try: import ... except ImportError` sails straight
through, finds nothing to patch, and returns. ATOM v0.1.9 has two such
installers: one raises `AttributeError` at startup, the other uses
`getattr(module, name, None)` and simply does not install — leaving DeepSeek
V4.1's `--max-model-len -1` to fit against a pool whose STATE tail has not been
taken out yet. No error. Wrong number.

**Silent and arithmetic.** `_pool_bytes_per_block` both moved *and* gained a
`vllm_config` first parameter. Fix only the path and the call passes the groups
list where the config belongs, raises nothing, and returns wrong bytes-per-block.

ATOM's own `register.py` documents an instance of the second kind in its own
history: "the dummy-run marking once covered nothing while the synthetic
batches went on taking real STATE slots."

## What checks it now

Two tools, in the ATOM fork
([sbates130272/ATOM](https://github.com/sbates130272/ATOM), branch
`v0.1.9-vllm0.33`), both upstreamable as-is.

| | `compat_check` | `doctor` |
| --- | --- | --- |
| asks | can the symbol be found? | did the patch actually go in? |
| method | AST on both sides, no import | runs both registration hooks |
| needs | nothing — no vLLM, torch, GPU | the whole stack, a GPU |
| runs | in the `atom-vllm` build, in CI | `make atom-vllm-doctor` |
| misses | patches that stand down | symbols it never reaches |

`compat_check` reports four things and exits non-zero on any of them:
unresolved imports (counting `try/except ImportError` ladders as one group, and
skipping `if TYPE_CHECKING:` blocks, which never execute); monkeypatch targets
that no longer exist; the state of every entry in the relocation table; and
arity drift on relocated symbols.

That last pair is the forward-looking half. Once a call site is rewritten to go
through the shim it contains no `from vllm... import` for a scanner to find, so
the table is resolved directly — otherwise the check would go quiet on exactly
the symbols most likely to move again.

`doctor` prints one row per patch: installed, stood down with a reason, or
raised. It exits non-zero when a patch did not install **and gave no reason**.

## Where it is wired in

- **`ATOM_REPO`** (`rocm-bake.hcl`) selects which ATOM to build. Upstream by
  default. Pair it with an `ATOM_REF` that is a *tag* on the fork — the clone
  in `Dockerfile.atom` is layer-cached on the ref string, so a branch name
  builds once and then never updates.
- **`atom-vllm`** (`docker/Dockerfile.atom-vllm`) is the vLLM image with the
  ATOM wheel installed and `compat_check` run against it as a build gate. A
  future `VLLM_REF` bump that moves a symbol fails that build with a named
  list. It needs no GPU, so it runs on the fleet and on CodeBuild alike.
- **`make atom-vllm-doctor`** is the on-hardware half, run deliberately.

The plugin ships **disabled** (`ATOM_DISABLE_VLLM_PLUGIN=1`). Enabling it
replaces vLLM's model classes for 30 architectures.

## What none of this establishes

**That a model generates tokens through the plugin.** ATOM's kernels need
gfx942, gfx950 or gfx1250; `manifests/snoc.yml` has gfx1151 and gfx1201 and
nothing else. A clean `compat_check` means nothing will fail to import. A clean
`doctor` means the patches installed. Neither is evidence about numerics, and
the gap is not closable on this fleet.

## LMCache MP, since it comes up

Three separate things get conflated:

1. **ATOM's own `lmcache_mp` connector is not reachable from plugin mode.** It
   is registered in *ATOM's* connector factory and serves the native engine; in
   plugin mode vLLM resolves connectors through its own registry, where ATOM
   exposes only `AtomLMCacheOffloadConnector`. ATOM says so itself in
   `atom/plugin/vllm/platform.py`.
2. **The cupy blocker ATOM documents is stale.** The connector docstring says
   LMCache's ROCm platform does not provide cupy. At LMCache v0.5.6
   `RocmDeviceSpec` subclasses `CudaDeviceSpec` and inherits the cupy cache
   context; cupy maps `launch_host_func` to `hipLaunchHostFunc` for HIP >= 5.4
   (we are on ROCm 10.1); and this repo already builds that ROCm cupy wheel.
   The default IPC path is PyTorch storage IPC, not cupy IPC.
3. **LMCache v0.5.6 imports clean against vLLM 0.33.0.** Measured with the same
   checker pointed at it: 79 import sites, 53 distinct symbols, one unresolved
   — `vllm.attention:Attention` in a FlashInfer module never loaded on ROCm.

The real constraint is layout, not version. LMCache's GPU connectors take one
clean NHD/HND format for the whole model; ATOM's plugin-mode KV tensors for
MLA/DSA models are not that, which is why ATOM wrote its own byte-codec
connector. So LMCache MP alongside the ATOM plugin is sound for models whose
ATOM layout is plain NHD/HND and unsound for MLA/M3/DSA ones — and that is true
of 0.31 and 0.33 equally.

## AITER

ATOM declares no `aiter` constraint either — no version, no range, ~700 call
sites. `compat_check --package aiter` covers it with the same code, and the
`atom-vllm` build runs it. Not as a gate yet: it has never been measured, so
the first findings are information rather than grounds to fail a vLLM build.

The `v0.1.28` -> `v0.1.28.post1` bump does not change any of this. It touches
`aiter/ops/topk_select.py`, but only to widen `_SUPPORTED_GFX` from
`("gfx942", "gfx950", "gfx1250")` to add `"gfx1250-strict"`. Still no RDNA, so
`docker/atom-topk-fallback.py` and its reasoning stand unchanged.
