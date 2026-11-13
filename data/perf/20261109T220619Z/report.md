# Warm parallel wheel build — 20261109T220619Z

- **started** Mon 09 Nov 2026 16:06:19 CST
- **arch** `gfx1250` · **commit** `c890784`
- **wall clock** 30m45s · **exit** 0
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
| snoc-strix | 99% | 8% | 1.6GB | 8.2GB |
| snoc-think | 39% | 3% | 73.5GB | 10.2GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| triton-wheel | snoc-strix | 00:00:08 | 2m40s | 7m27s | 7m56s | -6% | 2/24 |
| cupy-wheel | snoc-think | 00:00:08 | 3m06s | 3m24s | 3m19s | +2% | 2/27 |
| pytorch-wheel | snoc-strix | 00:07:36 | 12m14s | 13m09s | 4m43s | +179% | 2/31 |
| pytorch | snoc-think | 00:20:47 | 26s | 53s | 53s | -1% | 2/22 |
| nixl-wheel | snoc-strix | 00:21:49 | 1m28s | 1m40s | 1m57s | -14% | 1/30 |
| atom-wheel | snoc-think | 00:21:50 | 2m45s | 3m44s | 3m43s | +0% | 2/32 |
| aiter-wheel | snoc-strix | 00:23:30 | 42s | 1m18s | 1m51s | -29% | 2/29 |
| lmcache-wheel | snoc-strix | 00:24:54 | 1m44s | 1m54s | 1m40s | +13% | 3/34 |
| torchvision-wheel | snoc-think | 00:25:36 | 20s | 35s | 36s | -1% | 2/26 |
| vllm-wheel | snoc-strix | 00:26:49 | 2m43s | 3m55s | 4m21s | -10% | 4/38 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261109T205045Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 148 | 29.0MB | +15s | +28m59s |
| Zot blobs (layer cache) | 196 | 23.9GB | +2m54s | +30m44s |

## Published artifacts

```
  pytorch-wheel  344.2 MB  (49 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  gfx1151   device-gfx1151   2.15.0    10.1.0-full    438.4 MB  -                torch-2.15.0a0+git31a77fc.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 47 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  431.2 MB  (46 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  noarch    -                3.9.0     10.1.0-full    431.2 MB  -                triton-3.9.0+gitaad2a60d.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 44 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  133.6 MB  (40 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  gfx1151   device-gfx1151   2.15.0    10.1.0-full    133.8 MB  -                amd_aiter-0.1.29.dev0+gf1965cd26.d20261109.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 38 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  12.2 MB  (42 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  gfx1151   device-gfx1151   v1.5.2    10.1.0-full     12.2 MB  -                nixl-1.5.2+rocm10.1.0-py3-none-any.whl
      … 40 older tag(s); ZOT_TAGS=0 for all
      latest
  torchvision-wheel  1.6 MB  (20 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  gfx1151   device-gfx1151   v0.29.2   10.1.0-full      1.6 MB  -                torchvision-0.29.2+rocm10.1.0-py3-none-manylinux_2_39_x86_64.whl
      … 18 older tag(s); ZOT_TAGS=0 for all
      latest
  atom-wheel  22.9 MB  (16 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  gfx1151   device-gfx1151   v0.1.9    10.1.0-full     22.9 MB  -                atom-0.1.9+rocm10.1.0-cp314-none-manylinux_2_38_x86_64.whl
      … 14 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.4 MB  (42 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  gfx1151   device-gfx1151   v14.2.0   10.1.0-full     41.3 MB  -                cupy-14.2.0+rocm10.1.0-cp314-cp314-manylinux_2_39_x86_64.whl
      … 40 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  63.0 MB  (40 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  gfx1151   device-gfx1151   v0.33.0   10.1.0-full     80.7 MB  -                vllm-0.33.0+rocm101-cp314-cp314-linux_x86_64.whl
      … 38 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  8.6 MB  (41 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  gfx1151   device-gfx1151   v0.5.6    10.1.0-full      8.7 MB  -                lmcache-0.5.6+rocm10.1.0-cp314-cp314-manylinux_2_39_x86_64.whl
      … 39 older tag(s); ZOT_TAGS=0 for all
      latest
```

