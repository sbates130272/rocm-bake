# Cold parallel wheel build — 20261103T220209Z

- **started** Tue 03 Nov 2026 16:02:09 CST
- **arch** `gfx1201` · **commit** `deb8737`
- **wall clock** 41m23s · **exit** 0
- **sample interval** 5s · **sccache prefix** `perf-20261103T220209Z`

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
| snoc-gaming | 8% | 2% | 14.1GB | 33.0MB |
| snoc-strix | 37% | 5% | 17.1GB | 5.2GB |
| snoc-think | 100% | 54% | 69.2GB | 7.7GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| cupy-wheel | snoc-strix | 00:00:03 | 4m15s | 4m20s | 5s | +4274% | 0/21 |
| triton-wheel | snoc-think | 00:00:03 | 7m12s | 7m22s | 5s | +8015% | 2/22 |
| pytorch-wheel | snoc-think | 00:07:27 | 18m47s | 18m57s | 5s | +19664% | 2/29 |
| pytorch | snoc-think | 00:26:25 | 19s | 41s | 50s | -19% | 2/21 |
| aiter-wheel | snoc-strix | 00:27:07 | 1m36s | 1m42s | 4m02s | -58% | 0/26 |
| nixl-wheel | snoc-think | 00:27:07 | 2m47s | 2m52s | 3m45s | -23% | 1/27 |
| lmcache-wheel | snoc-think | 00:30:01 | 1m07s | 1m12s | 1m40s | -27% | 2/30 |
| vllm-wheel | snoc-think | 00:31:15 | 10m02s | 10m08s | 6m44s | +50% | 4/35 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261103T212238Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 5432 | 1.1GB | +54s | +40m52s |
| Zot blobs (layer cache) | 28 | 1.4GB | +26m19s | +41m23s |

## Published artifacts

```
  pytorch-wheel  382.9 MB  (3 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 15:58  gfx1201   device-gfx1201   2.15.0    10.1.0-full    382.9 MB  -                torch-2.15.0a0+git31a77fc-cp314-cp314-linux_x86_64.whl
      … 1 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  431.0 MB  (3 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 15:58  noarch    -                3.9.0     10.1.0-full    431.0 MB  -                triton-3.9.0+gitaad2a60d-cp314-cp314-linux_x86_64.whl
      … 1 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  133.7 MB  (3 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 15:58  gfx1201   device-gfx1201   2.15.0    10.1.0-full    133.7 MB  -                amd_aiter-0.1.29.dev0+gf1965cd26.d20261103-cp314-cp314-linux_x86_64.whl
      … 1 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  12.2 MB  (3 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 15:58  gfx1201   device-gfx1201   v1.5.2    10.1.0-full     12.2 MB  -                nixl-1.5.2-py3-none-any.whl
      … 1 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.5 MB  (3 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 15:58  gfx1201   device-gfx1201   v14.2.0   10.1.0-full     41.5 MB  -                cupy-14.2.0-cp314-cp314-linux_x86_64.whl
      … 1 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  74.8 MB  (3 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 15:58  gfx1201   device-gfx1201   v0.33.0   10.1.0-full     74.8 MB  -                vllm-0.33.0+rocm101-cp314-cp314-linux_x86_64.whl
      … 1 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  8.6 MB  (3 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 15:58  gfx1201   device-gfx1201   v0.5.6    10.1.0-full      8.7 MB  -                lmcache-0.5.6-cp314-cp314-linux_x86_64.whl
      … 1 older tag(s); ZOT_TAGS=0 for all
      latest
```

