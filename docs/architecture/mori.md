# MORI And UMBP

[MORI](https://github.com/ROCm/mori) is AMD's GPU communication
library: peer-to-peer and RDMA/IBGDA transports, SDMA, and the MoE
dispatch/combine kernels. What this repo builds it for is **UMBP**, its
unified memory buffer pool — a pair of long-lived processes that hand
memory to workers over gRPC.

Two artifacts come out of `docker/Dockerfile.mori`:

| Target | What it is |
| --- | --- |
| `mori-wheel` | A `scratch` image carrying `amd_mori-*.whl`, for the per-arch pip index |
| `mori` | A runnable image: the wheel installed, plus the shared libraries the UMBP binaries link, behind one entrypoint |

## Why It Is Built From Source

PyPI publishes `amd_mori` for cp310 and cp312. This stack is cp314, so
there is no wheel to install and the sdist would compile anyway. Same
situation as CuPy, and the same answer.

## Why It Is Not In The vLLM Image

UMBP in multi-process mode is a *pool*, shared by several workers. Put
it inside a worker image and its lifetime is tied to one of them, and
every serving image on every architecture carries a library most of
them cannot use. So `mori` is its own image, in `default` but
deliberately not in the `serving` group, and nothing in
`docker/Dockerfile.vllm` installs it.

## `BUILD_UMBP` Is The Whole Point

Upstream defaults `BUILD_UMBP=OFF`. With it off the wheel still builds,
still imports, and still passes every other check — it simply contains
no `mori/umbp_master` and no `mori/umbp_standalone_server`, which are
the two processes this image exists to run.

"Builds fine, useless" is the failure mode, so the build asserts it:
after the wheel is produced it is unpacked, both binaries are confirmed
present and confirmed to be ELF, and `ldd` is run against each so that
an unresolvable `libgrpc++` fails here rather than on a host hours
later. The `ldd` output travels with both published images as
`/wheels-umbp.txt`.

`BUILD_TORCH_SYMM=OFF` is the other build-time decision. It turns off
MORI's torch SymmetricMemory backend, which is what lets this target
hang off `pytorch-base` rather than queueing behind the PyTorch
compile. Left at its `AUTO` default the contents of the wheel would
depend on whether the base image happened to have torch.

## Running It

The role is the first argument. `standalone` is the default, because a
single-node pool needs no master.

```bash
# The node-local buffer pool.
docker run --rm \
    --device=/dev/kfd --device=/dev/dri \
    --group-add video --security-opt seccomp=unconfined \
    --ipc=host --shm-size=16g \
    -v /run/umbp:/run/umbp \
    snoc-strix.fold-leaffish.ts.net:8080/rocm-pytorch/mori:latest standalone

# The cross-node control plane.
docker run --rm -p 15558:15558 \
    snoc-strix.fold-leaffish.ts.net:8080/rocm-pytorch/mori:latest master

# What the entrypoint resolved, with no GPU and no devices.
make mori-check                  # the binaries and their paths
make mori-check MORI_MODE=env    # the UMBP settings a container starts with
```

Anything that is not a role runs verbatim, so
`docker run <img> python -c 'import mori'` and `docker run <img> bash`
behave as they would on the base image.

### Configuration Is Environment, Not Flags

UMBP takes no command-line configuration; everything is an environment
variable, documented upstream in `src/umbp/doc/runtime-env-vars.md`.
The entrypoint passes every argument after the role through untouched
and sets only defaults that would otherwise be unset:

| Variable | What the image does |
| --- | --- |
| `UMBP_MASTER_BIN` | Set to the binary inside the installed package, so a worker that auto-starts a master finds it |
| `UMBP_MASTER_LISTEN` | Defaults to `0.0.0.0:15558` — a container's loopback is reachable from nowhere a peer could be |
| `UMBP_SSD_DIR` | Defaults to `/tmp/umbp_ssd`, and is created before the server starts |
| `UMBP_STANDALONE_ADDRESS` | Left to upstream's default, `unix:///run/umbp/standalone/<node_id>.grpc.sock`, with a sibling `.fd.sock` for the file-descriptor handoff |
| `UMBP_MASTER_ADDRESS` | Left unset, which is upstream's embedded mode: no routing and no registration |

`/run/umbp/standalone` exists in the image so a container that mounts
nothing still starts. Sharing the pool between containers means
bind-mounting a host directory over it.

## Architecture Support Is An Open Question

Upstream lists MI308X, MI300X, MI325X and MI355X as the supported
hardware, and MORI's own fallback target list is
`gfx942;gfx950;gfx1250` — all CDNA or CDNA-next. This fleet's `ARCHES`
is `gfx950 gfx1201 gfx1151 gfx1250`, so two of the four are RDNA and
are not among the architectures upstream claims.

The target is built for all four anyway. That is deliberate: the
alternative is gating it on an assumption, and a failed RDNA build is a
measurement where the assumption is not. **If a gfx1201 or gfx1151
build fails, record what it did in `docker/Dockerfile.mori` and gate it
then.** This is the same shape as the `PREBUILD_KERNELS` note in
`rocm-bake.hcl`, which exists because two architectures were found to
be unable to take level 2 — by building them.

| Architecture | Status |
| --- | --- |
| `gfx950` | **Builds.** 113s for the full `mori` target, 13 extensions, one offload bundle and it is `gfx950` |
| `gfx1201` | **Builds**, despite not being claimed upstream. Same 13 extensions, one offload bundle and it is `gfx1201`; the UMBP binaries are present and resolve |
| `gfx1250` | Untried. In upstream's own fallback list, so expected to work |
| `gfx1151` | Untried |

Both measured 2026-11-26 on snoc-think against ROCm 10.2.0.

!!! warning "Compiling for RDNA is not the same as working on RDNA"
    The gfx1201 result says the source compiles and the wheel carries
    gfx1201 device code. It does **not** say the kernels are correct
    there, that the EP dispatch/combine paths work, or that anything
    has been run on a card — nothing in this repo has executed MORI on
    any GPU yet. Upstream still lists only MI308X/MI300X/MI325X/MI355X,
    and its RDMA paths additionally want an IBGDA-capable NIC that this
    fleet does not have.

    So the honest state is: the build gate is not needed, and the
    runtime question is open. Treat a gfx1201 or gfx1151 image as
    unproven until something runs on one.

Only one or two of the 140 compile requests are HIP; the rest are C++,
which is why a cold build is minutes rather than the hours AITER
takes. It also means almost none of the build is architecture-specific,
which is the most likely reason gfx1201 compiles at all. Most of MORI's kernel surface is JIT-compiled through hipRTC at
run time, which is also why the offload-bundle check here is the soft
CuPy-shaped one.

`MORI_GPU_ARCHS` is set explicitly from `PYTORCH_ROCM_ARCH` for the
reason AITER and CuPy both have equivalents of: `setup.py` otherwise
shells out to `rocm_agent_enumerator`, a BuildKit `RUN` has no
`/dev/kfd`, and the build would silently fall back to a three-arch fat
binary unrelated to the tag it is published under.

## Two Things The Base Image Does Not Provide

Both were found by building, on 2026-11-26, and both are about ROCm's
own tree rather than about MORI.

**`libdrm-dev`.** MORI includes `rocm_smi.h`, which includes
`kfd_ioctl.h`, whose line 26 is `#include <libdrm/drm.h>`. The first
compile of the build dies without it. The stock
`rocm/dev-ubuntu-26.04` image carries the package and our pruned base
does not, which is why it is absent from the recipe this target was
written from. ROCm *does* ship a copy under `rocm_sysdeps/include`,
but that directory also holds `elf.h`, `zlib.h`, `bzlib.h`, `expat.h`
and `curses.h`, so putting it on the include path would shadow glibc's
and ncurses' headers for every translation unit. One apt package beats
a shadowed include path.

**`/opt/rocm/lib/rocm_sysdeps/lib` on the loader path.**
`CMAKE_PREFIX_PATH` names `rocm_sysdeps`, so MORI's `find_package`
calls resolve zlib and libnuma to ROCm's copies and the UMBP binaries
link `librocm_sysdeps_z.so.1` and `librocm_sysdeps_numa.so.1`. Nothing
can load them: that directory is on no loader path in this base. Both
the builder and the runtime stage add an `ld.so.conf.d` entry.

Adding the whole directory is safe, and that was checked rather than
assumed: 36 of the 37 real sonames there are renamed with a
`librocm_sysdeps_` prefix — the entire purpose of that prefix — so they
cannot shadow the system's zlib, numa or ncurses. The one exception is
`libiberty.so.0`, and this base ships no system `libiberty` at all.

## Memory, Not Cores

MORI's `setup.py` runs `cmake --build . -j {os.cpu_count()}` with the
count baked into the argument, so neither `MAX_JOBS` nor
`CMAKE_BUILD_PARALLEL_LEVEL` reaches it. The lever that works is
`PYTHON_CPU_COUNT`, added in Python 3.13, which changes what
`os.cpu_count()` itself returns — so that is what `Dockerfile.mori`
exports from `docker/max-jobs.sh`'s answer.

Without it a 32-core node runs 32 concurrent HIP compiles regardless of
its memory, which is the shape of the outage recorded in the header of
`docker/max-jobs.sh`.
