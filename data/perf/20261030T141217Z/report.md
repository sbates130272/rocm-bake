# Cold parallel wheel build — 20261030T141217Z

- **started** Fri 30 Oct 2026 08:12:17 MDT
- **arch** `gfx1201` · **commit** `403ac85` (dirty)
- **wall clock** 38m28s · **exit** 0
- **sample interval** 5s · **sccache prefix** `perf-20261030T141217Z`

> Throughput, not isolated per-target cost: the builds ran concurrently and shared the sccache store and registry, both on Strix, which is also a build node. For clean per-wheel numbers use `bench.sh cold`, which serialises on purpose.

## CPU busy by builder

![CPU busy by builder](cpu.svg)

## Network receive by builder

![Network receive by builder](net.svg)

## Build steps by builder

![Build steps by builder](timeline.svg)

## Interactive chart

![Interactive chart](index.html)

## Cache bytes written (cumulative)

![Cache bytes written (cumulative)](writes.svg)

## Per-builder totals

| builder | peak CPU | mean CPU | min free mem | net received |
|---|---|---|---|---|
| snoc-gaming | 99% | 5% | 8.8GB | 670.4MB |
| snoc-strix | 35% | 28% | 5.5GB | 3.3GB |
| snoc-think | 100% | 15% | 69.2GB | 2.6GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| pytorch-wheel | snoc-strix | 00:00:02 | 38m25s | 38m25s | 38m33s | -0% | 2/25 |
| vllm-wheel | snoc-think | 00:00:03 | 23m19s | 23m19s | - | - | 5/38 |
| cupy-wheel | snoc-gaming | 00:00:07 | 3m45s | 3m45s | 3m24s | +10% | 2/21 |
| nixl-wheel | snoc-gaming | 00:03:54 | 3m36s | 3m36s | 2m33s | +41% | 1/27 |
| aiter-wheel | snoc-gaming | 00:07:31 | 55s | 56s | 44s | +26% | 3/25 |
| lmcache-wheel | snoc-gaming | 00:08:28 | 1m36s | 1m36s | - | - | 3/33 |
| triton-wheel | snoc-think | 00:23:23 | 6m25s | 6m25s | 17m18s | -63% | 3/22 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261030T111221Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 3729 | 787.5MB | +23s | +37m50s |
| Zot blobs (layer cache) | 0 | - | - | - |

## Published artifacts

```
  pytorch-wheel  382.9 MB  (15 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-10-30 06:35  gfx1201   device-gfx1201   2.15.0    10.1.0-full    382.9 MB  -                torch-2.15.0a0+git31a77fc-cp314-cp314-linux_x86_64.whl
      … 13 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  431.0 MB  (21 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-10-30 06:35  noarch    -                3.9.0     10.1.0-full    431.0 MB  -                triton-3.9.0+gitaad2a60d-cp314-cp314-linux_x86_64.whl
      … 19 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  131.2 MB  (9 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-10-30 06:35  gfx1201   device-gfx1201   2.15.0    10.1.0-full    131.2 MB  -                amd_aiter-0.1.27-cp314-cp314-linux_x86_64.whl
      … 7 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  12.2 MB  (9 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-10-30 06:35  gfx1201   device-gfx1201   v1.5.2    10.1.0-full     12.2 MB  -                nixl-1.5.2-py3-none-any.whl
      … 7 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.4 MB  (5 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-10-30 06:35  gfx1201   device-gfx1201   v14.2.0   10.1.0-full     41.4 MB  -                cupy-14.2.0-cp314-cp314-linux_x86_64.whl
      … 3 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  67.4 MB  (7 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-10-30 06:35  gfx1201   device-gfx1201   v0.32.0   10.1.0-full     67.4 MB  -                vllm-0.32.0+rocm101-cp314-cp314-linux_x86_64.whl
      … 5 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  8.6 MB  (8 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-10-30 06:35  gfx1201   device-gfx1201   v0.5.6    10.1.0-full      8.7 MB  -                lmcache-0.5.6-cp314-cp314-linux_x86_64.whl
      … 6 older tag(s); ZOT_TAGS=0 for all
      latest
```

