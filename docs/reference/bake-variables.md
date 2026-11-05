# Bake Variables

`rocm-bake.hcl` declares 52 variables and is the single source for every
value a build reads. The Makefile parses the `variable` blocks at parse
time and reads the defaults out, so `make build-pytorch` and a bare
`docker buildx bake pytorch` always agree; `check-defaults.py` fails CI
if they drift. `make list-vars` prints what is actually in effect, and
is authoritative if this page has aged.

## Versions And Refs

<!-- BEGIN BAKE_VERSIONS -->

| Variable | Default |
| --- | --- |
| `PYTORCH_VERSION` | `2.15.0` |
| `ROCM_VERSION` | `10.1.0-full` |
| `PYTHON_VERSION` | `3.14` |
| `TRITON_VERSION` | `3.9.0` |
| `TRITON_REF` | `aad2a60d958f945420c5c40936b37d411fb02e89` |
| `AITER_REF` | `v0.1.28` |
| `TORCHVISION_REF` | `v0.29.2` |
| `ATOM_REF` | `v0.1.9` |
| `NIXL_REF` | `v1.5.2` |
| `UCX_REF` | `v1.22.0` |
| `VLLM_REF` | `v0.33.0` |
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

`RUST_VERSION` tracks the channel in vLLM's `rust-toolchain.toml`, which
v0.33 still pins to 1.95; `setup.py` builds `vllm/vllm-rs`.

## Registry

| Variable | Default |
| --- | --- |
| `REGISTRY` | `snoc-strix.fold-leaffish.ts.net:8080` |
| `REGISTRY_NAME` | `rocm-pytorch` |
| `REGISTRY_INSECURE` | `true` |
| `SOURCE_URL` | `https://github.com/sbates130272/rocm-pytorch-build` |

`REGISTRY_INSECURE` is `true` for the fleet's Zot, which serves plain
HTTP on a tailnet. Set it `false` for any registry with TLS and auth —
ECR, GHCR, Docker Hub. It reaches the `registry.insecure=` field of
every `cache-from` and `cache-to` in the file, and leaving it `true`
against an HTTPS registry fails the cache export rather than falling
back, which `ignore-error=true` then swallows.

## Architecture And Build Shape

| Variable | Default | |
| --- | --- | --- |
| `PYTORCH_ROCM_ARCH` | `gfx950` | Semicolon-separated list; a list produces one fat binary |
| `USE_AITER` | `ON` | |
| `USE_FLYDSL` | `ON` | |
| `USE_FLASH_ATTENTION` | `ON` | |
| `USE_ROCM_CK_SDPA_GFX12` | `""` | RDNA4 Composable Kernel SDPA, new in PyTorch 2.15 and `OFF` upstream. `ON` takes effect only on a gfx12 RDNA4 target; anywhere else it stays `OFF` |
| `MAX_JOBS` | `""` | Empty derives it per node from `MemAvailable` |
| `PREBUILD_KERNELS` | `""` | Empty means 0, on every architecture. Level 2 builds no wheel at all on `gfx1201` or `gfx125x` |
| `ROCM_PRUNE_PROFILE` | `keep-toolchain` | How hard `docker/rocm-prune.sh` cuts the ROCm SDK down. `minimal` also drops the headers and the HIP cmake package — see [Image sizes](image-sizes.md) |

The prebuild level no longer derives from the architecture; it is 0
everywhere unless pinned. See
[Multiple GFX targets](../architecture/multi-arch.md) for what the
architecture still does decide.

## Compiler Cache

| Variable | Default | |
| --- | --- | --- |
| `SCCACHE_WEBDAV_HOST` | `snoc-strix.fold-leaffish.ts.net` | The nginx WebDAV store |
| `SCCACHE_WEBDAV_PORT` | `8081` | |
| `SCCACHE_WEBDAV_ENDPOINT` | `""` | Composed from host and port; the Makefile supplies a resolved address |
| `SCCACHE_WEBDAV_KEY_PREFIX` | `rocm-pytorch` | Namespace within the store |
| `SCCACHE_BUCKET` | `""` | S3 store, for builds off the fleet. Empty selects WebDAV |
| `SCCACHE_REGION` | `""` | Required whenever `SCCACHE_BUCKET` is set |
| `SCCACHE_S3_KEY_PREFIX` | `rocm-pytorch` | Namespace within the bucket |
| `SCCACHE_LOG` | `warn` | `debug` reveals what "Cache errors" is counting |
| `SCCACHE_VERSION` | `0.19.0` | 0.8.0 is the floor for caching `hipcc -x hip` |
| `REQUIRE_SCCACHE` | `1` | Refuse to compile when the store is unreachable |

### WebDAV On The Fleet, S3 Off It

The WebDAV store is nginx on the services node, reached over the
tailnet; a rented machine has neither, so it needs a store that outlives
it — hence S3. See [Building on AWS](../operations/aws.md).

The two coexist. sccache ranks S3 above WebDAV and treats an empty
`SCCACHE_BUCKET` as unset, so the S3 variables are inert on SNOC.
Verified against sccache 0.19.0: unset and `""` both select WebDAV, a
non-empty bucket selects S3.

**Credentials are not variables.** They reach the build as a BuildKit
secret mounted for the life of the instruction, so they never become a
build arg and never land in image history or a published tag:

```bash
aws configure export-credentials --format env-no-export > /tmp/awscreds
docker buildx bake -f rocm-bake.hcl --set '*.secrets=id=aws,src=/tmp/awscreds' \
  cupy-wheel
shred -u /tmp/awscreds
```

!!! warning "A readable-but-unwritable bucket caches nothing, silently"
    `REQUIRE_SCCACHE=1` catches bad credentials and a missing bucket —
    sccache probes at server start and aborts. What it cannot catch is
    a policy granting reads but not writes. Grant `s3:ListBucket` too:
    without it a missing key returns `403` rather than `404`, and the
    probe fails for the wrong reason.

!!! note "Session credentials expire"
    Credentials from the environment carry no expiry hint for sccache
    to refresh against, so a build longer than the session turns every
    later cache operation into a `403` *after* the preflight passed.
    Prefer an `sts:assume-role` with an explicit long
    `--duration-seconds`.
| `FORCE_RECACHE` | `false` | `true` recompiles everything, ignoring sccache |

!!! warning "There is deliberately no `SCCACHE_SERVER_PORT`"
    Build containers reach their sccache server over a unix socket,
    because the builders run with `network=host` and a fixed port would
    be shared fleet-wide. See
    [Caching](../architecture/caching.md#3-the-compiler-cache).

    Setting `SCCACHE_WEBDAV_ENDPOINT` yourself only affects a bare bake
    — the Makefile exports its own resolved form unconditionally.

## Reproducibility

| Variable | Default | |
| --- | --- | --- |
| `SDE_EPOCH` | `1700000000` | `SOURCE_DATE_EPOCH` pinned into every image config |
| `SDE_BASE` … `SDE_TORCHVISION` | `""` | Per-image overrides; empty means use `SDE_EPOCH` |
| `VCS_REF` | `""` | Supplied by the Makefile; gets a `-dirty` suffix |
| `BUILD_DATE` | `""` | Supplied by the Makefile as the commit's own timestamp |

The eleven per-image variables are `SDE_ROCM`, `SDE_BASE`,
`SDE_PYTORCH`, `SDE_TRITON`, `SDE_AITER`, `SDE_RUNTIME`, `SDE_NIXL`,
`SDE_VLLM`, `SDE_LMCACHE`, `SDE_CUPY` and `SDE_TORCHVISION`. See
[Reproducibility](../architecture/reproducibility.md) for why the epoch
is a constant.

## Caching And Scheduling

| Variable | Default | |
| --- | --- | --- |
| `CACHE_TAG_SUFFIX` | `""` | Empty writes the rolling tag; `-ref` refreshes the frozen baseline |
| `PUBLISHED_INPUTS` | `""` | `1` resolves sibling inputs from the registry instead of `target:` contexts |
| `RUN_ID` | `dev` | Stamped into every BuildKit history record name |

## Overriding Without Editing

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
