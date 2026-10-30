# Bake variables

`rocm-bake.hcl` declares 45 variables and is the single source for every
value a build reads. The Makefile parses the `variable` blocks at make
parse time and reads the defaults out, so `make build-pytorch` and a
bare `docker buildx bake pytorch` always agree.

`make list-vars` prints the values actually in effect and is
authoritative if this page has aged. `.builders/check-defaults.py` fails
CI if a default is re-declared in the Makefile, or if the Makefile reads
a variable that `rocm-bake.hcl` does not define.

Change a default by editing its `variable` block.

## Versions and refs

<!-- BEGIN BAKE_VERSIONS -->

| Variable | Default |
| --- | --- |
| `PYTORCH_VERSION` | `2.15.0` |
| `ROCM_VERSION` | `10.1.0-full` |
| `PYTHON_VERSION` | `3.14` |
| `TRITON_VERSION` | `3.9.0` |
| `TRITON_REF` | `aad2a60d958f945420c5c40936b37d411fb02e89` |
| `AITER_REF` | `v0.1.27` |
| `NIXL_REF` | `v1.5.2` |
| `UCX_REF` | `v1.22.0` |
| `VLLM_REF` | `v0.32.0` |
| `CUPY_REF` | `v14.2.0` |
| `LMCACHE_REF` | `v0.5.6` |
| `RUST_VERSION` | `1.95` |
| `GIT_REF` | `""` - a specific PyTorch ref to build |

<!-- END BAKE_VERSIONS -->

This table is generated from `rocm-bake.hcl` by `make version-scrub`, and
`make version-scrub-check` fails CI if it drifts. `make version-check`
compares each of these against the latest upstream release and against the
wheels published in the registry.

The four serving-stack refs are release tags, never branches. A moving
ref would be served from the layer cache indefinitely once built, so an
"update" would silently be a no-op.

`RUST_VERSION` tracks the channel in vLLM's `rust-toolchain.toml`; v0.32
builds `vllm/vllm-rs` during `setup.py`.

## Registry

| Variable | Default |
| --- | --- |
| `REGISTRY` | `snoc-strix.fold-leaffish.ts.net:8080` |
| `REGISTRY_NAME` | `rocm-pytorch` |
| `SOURCE_URL` | `https://github.com/sbates130272/rocm-pytorch-build` |

## Architecture and build shape

| Variable | Default | |
| --- | --- | --- |
| `PYTORCH_ROCM_ARCH` | `gfx950` | Semicolon-separated list; a list produces one fat binary |
| `USE_AITER` | `ON` | |
| `USE_FLYDSL` | `ON` | |
| `USE_FLASH_ATTENTION` | `ON` | |
| `USE_ROCM_CK_SDPA_GFX12` | `""` | RDNA4 Composable Kernel SDPA, new in PyTorch 2.15 and `OFF` upstream. `ON` takes effect only on a gfx12 RDNA4 target; anywhere else it stays `OFF` |
| `MAX_JOBS` | `""` | Empty derives it per node from `MemAvailable` |
| `PREBUILD_KERNELS` | `""` | Empty derives it from the architecture: 0 on RDNA, 2 on CDNA |

See [Multiple GFX targets](../architecture/multi-arch.md) for why the
architecture decides the prebuild level, and why `gfx125x` is a special
case.

## Compiler cache

| Variable | Default | |
| --- | --- | --- |
| `SCCACHE_WEBDAV_HOST` | `snoc-strix.fold-leaffish.ts.net` | The nginx WebDAV store |
| `SCCACHE_WEBDAV_PORT` | `8081` | |
| `SCCACHE_WEBDAV_ENDPOINT` | `""` | Composed from host and port; the Makefile supplies a resolved address |
| `SCCACHE_WEBDAV_KEY_PREFIX` | `rocm-pytorch` | Namespace within the store |
| `SCCACHE_LOG` | `warn` | `debug` reveals what "Cache errors" is counting |
| `SCCACHE_VERSION` | `0.19.0` | 0.8.0 is the floor for caching `hipcc -x hip` |
| `REQUIRE_SCCACHE` | `1` | Refuse to compile when the store is unreachable |
| `FORCE_RECACHE` | `false` | `true` recompiles everything, ignoring sccache |

!!! warning "There is deliberately no `SCCACHE_SERVER_PORT`"
    Build containers reach their sccache server over a unix socket,
    because the builders run with `network=host` and a fixed port would
    be shared fleet-wide. See
    [Caching](../architecture/caching.md#3-the-compiler-cache). The
    host-level daemon in `deploy-sccache.sh` does use a port, which is
    fine — it is not in a container, and builds do not use it.

!!! note
    Setting `SCCACHE_WEBDAV_ENDPOINT` yourself only affects a bare bake.
    The Makefile exports its own resolved-address form unconditionally.

## Reproducibility

| Variable | Default | |
| --- | --- | --- |
| `SDE_EPOCH` | `1700000000` | `SOURCE_DATE_EPOCH` pinned into every image config |
| `SDE_BASE` … `SDE_CUPY` | `""` | Per-image overrides; empty means use `SDE_EPOCH` |
| `VCS_REF` | `""` | Supplied by the Makefile; gets a `-dirty` suffix |
| `BUILD_DATE` | `""` | Supplied by the Makefile as the commit's own timestamp |

The nine per-image variables are `SDE_BASE`, `SDE_PYTORCH`,
`SDE_TRITON`, `SDE_AITER`, `SDE_RUNTIME`, `SDE_NIXL`, `SDE_VLLM`,
`SDE_LMCACHE` and `SDE_CUPY`. See
[Reproducibility](../architecture/reproducibility.md) for why the epoch
is a constant rather than a date from git history.

## Caching and scheduling

| Variable | Default | |
| --- | --- | --- |
| `CACHE_TAG_SUFFIX` | `""` | Empty writes the rolling tag; `-ref` refreshes the frozen baseline |
| `PUBLISHED_INPUTS` | `""` | `1` resolves sibling inputs from the registry instead of `target:` contexts |
| `RUN_ID` | `dev` | Stamped into every BuildKit history record name |

## Overriding without editing

```bash
# A different PyTorch version
docker buildx bake -f rocm-bake.hcl \
  --set "*.args.PYTORCH_VERSION=2.13.0" pytorch

# A different ROCm base
docker buildx bake -f rocm-bake.hcl \
  --set "*.args.ROCM_VERSION=7.14" pytorch

# A different registry
docker buildx bake -f rocm-bake.hcl \
  --set "*.args.REGISTRY=myregistry.com:5000" \
  --set "*.args.REGISTRY_NAME=rocm-pytorch" pytorch

# A specific PyTorch ref
docker buildx bake -f rocm-bake.hcl \
  --set "*.args.GIT_REF=refs/heads/develop" pytorch

# Build even though the compiler cache is unreachable
docker buildx bake -f rocm-bake.hcl \
  --set "*.args.REQUIRE_SCCACHE=0" pytorch
```

!!! danger "`--set` on a bake *variable* is not the same as on an arg"
    `SCCACHE_WEBDAV_ENDPOINT`, `SCCACHE_LOG`, `PUBLISHED_INPUTS`,
    `RUN_ID`, `CACHE_TAG_SUFFIX` and the `SDE_*` family are bake
    variables read from the environment. Using `--set '*.args.X=…'` for
    one of them adds the arg to **every** target and changes their
    cache keys. Use the environment:

    ```bash
    SCCACHE_WEBDAV_ENDPOINT=http://other-host:8081 \
      docker buildx bake -f rocm-bake.hcl pytorch
    ```

Through the Makefile, `BAKE_EXTRA` passes arbitrary flags to any target:

```bash
make build-pytorch BAKE_EXTRA='--set pytorch.args.SOURCE_DATE_EPOCH=1700000001'
```
