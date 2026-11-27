# Cold parallel wheel build — 20261102T183000Z

- **started** Mon 02 Nov 2026 12:30:00 CST
- **arch** `gfx1201` · **commit** `35ba321`
- **wall clock** 8m05s · **exit** 0
- **sample interval** 5s · **sccache prefix** ``

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
| snoc-gaming | 3% | 1% | 14.2GB | 4.1MB |
| snoc-strix | 15% | 4% | 22.7GB | 4.4GB |
| snoc-think | 99% | 12% | 112.0GB | 1.6GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| cupy-wheel | snoc-strix | 00:00:02 | 0s | 6s | 3m00s | -97% | 11/22 |
| triton-wheel | snoc-think | 00:00:03 | 0s | 5s | 7m34s | -99% | 13/23 |
| pytorch-wheel | snoc-think | 00:00:09 | 0s | 5s | 6m56s | -99% | 13/26 |
| pytorch | snoc-think | 00:00:15 | 0s | 6s | 1m14s | -91% | 8/24 |
| aiter-wheel | snoc-strix | 00:00:21 | 43s | 1m17s | 1m17s | +0% | 1/26 |
| nixl-wheel | snoc-think | 00:00:22 | 1m30s | 1m44s | 2m03s | -15% | 1/28 |
| lmcache-wheel | snoc-think | 00:02:07 | 1m07s | 1m27s | 1m43s | -16% | 3/34 |
| vllm-wheel | snoc-think | 00:03:35 | 3m00s | 4m30s | 15m12s | -70% | 3/39 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261102T175351Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 4 | 576B | +48s | +5m00s |
| Zot blobs (layer cache) | 86 | 5.5GB | +8s | +8m05s |

## Published artifacts

```
  pytorch-wheel  382.9 MB  (20 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-02 12:25  gfx1201   device-gfx1201   2.15.0    10.1.0-full    382.9 MB  -                torch-2.15.0a0+git31a77fc-cp314-cp314-linux_x86_64.whl
      … 18 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  431.0 MB  (25 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-02 12:25  noarch    -                3.9.0     10.1.0-full    431.0 MB  -                triton-3.9.0+gitaad2a60d-cp314-cp314-linux_x86_64.whl
      … 23 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  133.5 MB  (13 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-02 12:25  gfx1201   device-gfx1201   2.15.0    10.1.0-full    133.5 MB  -                amd_aiter-0.1.28-cp314-cp314-linux_x86_64.whl
      … 11 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  12.2 MB  (14 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-02 12:25  gfx1201   device-gfx1201   v1.5.2    10.1.0-full     12.2 MB  -                nixl-1.5.2-py3-none-any.whl
      … 12 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.5 MB  (10 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-02 12:25  gfx1201   device-gfx1201   v14.2.0   10.1.0-full     41.5 MB  -                cupy-14.2.0-cp314-cp314-linux_x86_64.whl
      … 8 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  67.4 MB  (11 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-02 12:25  gfx1201   device-gfx1201   v0.32.0   10.1.0-full     67.4 MB  -                vllm-0.32.0+rocm101-cp314-cp314-linux_x86_64.whl
      … 9 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  8.6 MB  (13 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-02 12:25  gfx1201   device-gfx1201   v0.5.6    10.1.0-full      8.7 MB  -                lmcache-0.5.6-cp314-cp314-linux_x86_64.whl
      … 11 older tag(s); ZOT_TAGS=0 for all
      latest
```

