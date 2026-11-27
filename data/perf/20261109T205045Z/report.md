# Warm parallel wheel build — 20261109T205045Z

- **started** Mon 09 Nov 2026 14:50:45 CST
- **arch** `gfx1151` · **commit** `c890784`
- **wall clock** 31m15s · **exit** 0
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
| snoc-strix | 7% | 1% | 7.4GB | 28.5GB |
| snoc-think | 98% | 9% | 72.7GB | 20.2GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| triton-wheel | snoc-think | 00:00:02 | 1m43s | 7m56s | 9m06s | -13% | 2/24 |
| pytorch-wheel | snoc-think | 00:07:59 | 3m01s | 4m43s | 8m26s | -44% | 3/31 |
| pytorch | snoc-think | 00:12:44 | 19s | 53s | 57s | -6% | 2/22 |
| cupy-wheel | snoc-think | 00:13:38 | 3m02s | 3m19s | 3m29s | -5% | 2/27 |
| nixl-wheel | snoc-think | 00:16:59 | 1m32s | 1m57s | 1m52s | +4% | 1/30 |
| atom-wheel | snoc-think | 00:18:57 | 2m43s | 3m43s | 3m55s | -5% | 3/32 |
| aiter-wheel | snoc-think | 00:22:42 | 44s | 1m51s | 1m49s | +2% | 3/29 |
| lmcache-wheel | snoc-think | 00:24:34 | 1m19s | 1m40s | 1m37s | +3% | 3/34 |
| torchvision-wheel | snoc-think | 00:26:16 | 19s | 36s | 33s | +8% | 2/26 |
| vllm-wheel | snoc-think | 00:26:53 | 2m47s | 4m21s | 4m18s | +1% | 4/38 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261109T193315Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 19 | 5.2MB | +9s | +29m14s |
| Zot blobs (layer cache) | 196 | 25.2GB | +1m52s | +31m15s |

## Published artifacts

```
  pytorch-wheel  438.4 MB  (48 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  gfx1151   device-gfx1151   2.15.0    10.1.0-full    438.4 MB  -                torch-2.15.0a0+git31a77fc.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 46 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  431.2 MB  (46 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  noarch    -                3.9.0     10.1.0-full    431.2 MB  -                triton-3.9.0+gitaad2a60d.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 44 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  133.8 MB  (39 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  gfx1151   device-gfx1151   2.15.0    10.1.0-full    133.8 MB  -                amd_aiter-0.1.29.dev0+gf1965cd26.d20261109.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 37 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  12.2 MB  (41 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  gfx1151   device-gfx1151   v1.5.2    10.1.0-full     12.2 MB  -                nixl-1.5.2+rocm10.1.0-py3-none-any.whl
      … 39 older tag(s); ZOT_TAGS=0 for all
      latest
  torchvision-wheel  1.6 MB  (19 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  gfx1151   device-gfx1151   v0.29.2   10.1.0-full      1.6 MB  -                torchvision-0.29.2+rocm10.1.0-py3-none-manylinux_2_39_x86_64.whl
      … 17 older tag(s); ZOT_TAGS=0 for all
      latest
  atom-wheel  22.9 MB  (15 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  gfx1151   device-gfx1151   v0.1.9    10.1.0-full     22.9 MB  -                atom-0.1.9+rocm10.1.0-cp314-none-manylinux_2_38_x86_64.whl
      … 13 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.3 MB  (41 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  gfx1151   device-gfx1151   v14.2.0   10.1.0-full     41.3 MB  -                cupy-14.2.0+rocm10.1.0-cp314-cp314-manylinux_2_39_x86_64.whl
      … 39 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  80.7 MB  (39 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  gfx1151   device-gfx1151   v0.33.0   10.1.0-full     80.7 MB  -                vllm-0.33.0+rocm101-cp314-cp314-linux_x86_64.whl
      … 37 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  8.6 MB  (40 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-09 13:19  gfx1151   device-gfx1151   v0.5.6    10.1.0-full      8.7 MB  -                lmcache-0.5.6+rocm10.1.0-cp314-cp314-manylinux_2_39_x86_64.whl
      … 38 older tag(s); ZOT_TAGS=0 for all
      latest
```

