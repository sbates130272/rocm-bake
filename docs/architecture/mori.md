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

## vLLM Talks To This Pool, And It Works

vLLM 0.34.0 ships a `UMBPStoreConnector` whose `standalone` runtime
attaches to exactly the server this image runs, over the Unix socket.
Its own docstring: *"The server owns one DRAM pool per host. Every
engine, data-parallel rank, and worker on that host attaches to it
over a Unix-domain socket, so KV stored by one engine is reusable by
the others and survives engine restarts."*

Measured end to end on snoc-thinkstation (gfx1201) on 2026-11-26, with
the pool in this image's container and vLLM in another joined to its
IPC namespace:

```json
{"kv_connector": "UMBPStoreConnector", "kv_role": "kv_both",
 "kv_connector_extra_config": {
   "mode": "standalone",
   "endpoint": "/run/umbp/standalone/node0.grpc.sock"}}
```

| | engine A | engine B, a fresh process |
| --- | --- | --- |
| transfers | 80 stores | **80 loads** |
| bytes | 62,914,560 | **62,914,560** |
| failed | 0 | 0 |

Engine A was removed and a new one started against the same pool. It
loaded back byte-for-byte what A had stored, so KV genuinely survives
an engine restart here. Note the test has to be shaped that way:
`/reset_prefix_cache` is **404** on this build even with
`VLLM_DEV_MODE=1`, so a repeat against the same engine is answered
from VRAM and proves nothing — every counter stays `operation="store"`.
That is the same "stored but served none" trap `make serve-test`
exists for on the LMCache side.

No speed-up was demonstrated. 1.14s against 1.22s on a 0.5B model is
noise; this establishes the path is correct, not that it is worth
having.

### One Medium Per Node, And What That Costs Here

UMBP is **not** LMCache's L1/L2. There is no DRAM tier with spill to
disk inside one server — a node serves exactly one medium, and the
server says so at startup if you try:

```
UMBP_SSD_ENABLED is set but no medium was selected. A node serves one
medium: set UMBP_DISTRIBUTED_MEDIUM=SSD (with UMBP_SSD_DIR /
UMBP_SSD_CAPACITY) to serve storage, or unset UMBP_SSD_ENABLED to
serve DRAM.
```

Tiering is a *cluster* property: a master routes puts across nodes of
different media (`UMBP_ROUTE_PUT_SELECT_ALGO`). Measured on
snoc-thinkstation on 2026-11-26, that is out of reach on this fleet,
and the walk to the wall is worth recording because each step looks
like a configuration problem until the last one:

| attempt | result |
| --- | --- |
| DRAM node, SSD disabled | **works** — 804 stores, 603.0 MiB, 0 failed, nothing on the NVMe |
| pure-SSD node, vLLM attached to it | `MORI UMBP failed to register KV storage 0x…` in `register_kv_caches`, and the server logs nothing. Staging buffers (`UMBP_DISTRIBUTED_SSD_STAGING_*`) do not change it. The GPU-facing attach point wants DRAM |
| master + DRAM node + SSD node | `master-backed standalone server requested but missing required env: UMBP_IO_ENGINE_HOST` |
| …with the IO engine set | `backend initialization failed: no active RDMA device on this host; set MORI_DISABLE_AUTO_XGMI=0 to enable XGMI-only fallback` |
| …with `MORI_DISABLE_AUTO_XGMI=0` | the node **hangs**: still running, no socket, no further log line at all |

So the master-backed path — the only one that gives more than one
medium — needs an RDMA NIC or XGMI. snoc-thinkstation has a single
consumer GPU and neither. **L2 on the spare NVMe is not reachable with
MORI on this fleet**, and that is a hardware gap rather than a
configuration mistake. It is the same hardware assumption upstream
states for MORI generally: IBGDA-capable NICs.

What does work here is the single DRAM node, and it works well — see
the round trip above.

!!! warning "The pool pins engine VRAM and does not give it back"
    Workers register their GPU KV allocations with the server through
    HIP IPC. When the engine dies the server keeps holding them.
    Measured on a 15.92 GiB card:

    | state | VRAM used |
    | --- | --- |
    | pool alone | 0.07 GiB |
    | engine serving | 15.23 GiB |
    | engine removed, pool still up | **4.88 GiB, stable for 60s** |
    | pool restarted | 0.06 GiB |

    That residue is enough to stop the next engine starting: a restart
    at `--gpu-memory-utilization 0.70` failed with *"Free memory on
    device cuda:0 (7.17/15.92 GiB) on startup is less than desired GPU
    memory utilization (0.7, 11.15 GiB)"*. Restarting the pool frees
    it. Anything that cycles vLLM against a long-lived pool needs
    either headroom or a pool restart in the loop.

**What this does not include.** `mori` is not installed in
`docker/Dockerfile.vllm`, so none of the above works with the
published serving image as it stands — the measurement used a
throwaway image with the mori wheel added. Installing the client there
is a deliberate decision that has not been taken. It would be the
*client* library only; the pool stays a separate container, which is
the whole point of standalone mode.

There is a second, unrelated MORI integration in vLLM: the `moriio`
connector, which uses `mori.io` to move KV between prefill and decode
instances. It is not this, it needs `msgpack` which the image does not
have, and it has not been tried.

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
| `gfx950` | **Builds.** In upstream's fallback list |
| `gfx1250` | **Builds.** In upstream's fallback list |
| `gfx1201` | **Builds**, despite not being claimed upstream (RDNA4) |
| `gfx1151` | **Builds**, despite not being claimed upstream (RDNA3.5) |

All four measured 2026-11-26 on snoc-think against ROCm 10.2.0, and
all four are identical where it counts: 13 extensions in the wheel,
exactly one offload bundle and it is the architecture asked for, both
UMBP binaries present and resolving, and an auditwheel repair to
`manylinux_2_39`. All four are published to Zot.

The two architectures upstream does not claim behave no differently
from the two it does. See the note below on why there is so little
arch-specific code for them to differ in.

!!! warning "Compiling for RDNA is not the same as working on RDNA"
    The gfx1201 result says the source compiles and the wheel carries
    gfx1201 device code. It does **not** say the kernels are correct
    there, that the EP dispatch/combine paths work, or that anything
    has been run on a card — nothing in this repo has executed MORI on
    any GPU yet. Upstream still lists only MI308X/MI300X/MI325X/MI355X,
    and its RDMA paths additionally want an IBGDA-capable NIC that this
    fleet does not have.

    What *has* been run on RDNA4 (gfx1201): `make mori-serve-test`,
    and the full vLLM round trip above — a real engine registered its
    KV allocations with the pool, stored 80 blocks, and a second
    engine loaded them back byte-for-byte. So the data path works on
    an architecture upstream does not claim.

    So the honest state is: the build gate is not needed, the service
    and its KV round trip work on RDNA4, and what remains open is
    MORI's EP/RDMA kernels, which this fleet cannot exercise — it has
    no IBGDA-capable NIC and nothing here has run a MoE
    dispatch/combine.

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
