# Warm parallel wheel build — 20261105T233543Z

- **started** Thu 05 Nov 2026 17:35:43 CST
- **arch** `gfx1151` · **commit** `a7daef0` (dirty)
- **wall clock** 21m42s · **exit** 0
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
| snoc-strix | 99% | 12% | 14.0GB | 8.9GB |
| snoc-think | 49% | 4% | 110.7GB | 4.6GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| triton-wheel | snoc-strix | 00:00:02 | 2m17s | 7m15s | 6s | +7127% | 1/23 |
| cupy-wheel | snoc-think | 00:00:02 | 3m11s | 3m28s | 5s | +3758% | 1/22 |
| pytorch-wheel | snoc-strix | 00:07:18 | 3m13s | 4m21s | 16m18s | -73% | 2/30 |
| pytorch | snoc-think | 00:11:41 | 27s | 57s | 55s | +3% | 2/22 |
| nixl-wheel | snoc-strix | 00:12:39 | 1m35s | 1m49s | 1m54s | -5% | 0/28 |
| atom-wheel | snoc-think | 00:12:39 | 2m39s | 3m42s | 4m06s | -10% | 2/30 |
| aiter-wheel | snoc-strix | 00:14:39 | 1m02s | 1m42s | 1m25s | +20% | 0/27 |
| torchvision-wheel | snoc-strix | 00:16:22 | 25s | 34s | 38s | -12% | 2/26 |
| lmcache-wheel | snoc-think | 00:16:23 | 1m07s | 1m27s | 1m25s | +3% | 3/31 |
| vllm-wheel | snoc-strix | 00:17:51 | 2m51s | 3m51s | 9m45s | -60% | 0/38 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261105T221617Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 14 | 5.2MB | +10s | +20m15s |
| Zot blobs (layer cache) | 121 | 19.6GB | +7m17s | +21m42s |

## Published artifacts

```
  pytorch-wheel  438.4 MB  (43 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  gfx1151   device-gfx1151   2.15.0    10.1.0-full    438.4 MB  -                torch-2.15.0a0+git31a77fc-cp314-cp314-linux_x86_64.whl
      … 41 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  431.0 MB  (43 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  noarch    -                3.9.0     10.1.0-full    431.0 MB  -                triton-3.9.0+gitaad2a60d-cp314-cp314-linux_x86_64.whl
      … 41 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  133.6 MB  (35 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  gfx1151   device-gfx1151   2.15.0    10.1.0-full    133.6 MB  -                amd_aiter-0.1.29.dev0+gf1965cd26.d20261105-cp314-cp314-linux_x86_64.whl
      … 33 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  12.2 MB  (37 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  gfx1151   device-gfx1151   v1.5.2    10.1.0-full     12.2 MB  -                nixl-1.5.2-py3-none-any.whl
      … 35 older tag(s); ZOT_TAGS=0 for all
      latest
  torchvision-wheel  1.6 MB  (15 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  gfx1151   device-gfx1151   v0.29.2   10.1.0-full      1.6 MB  -                torchvision-0.29.2+rocm10.1.0-py3-none-manylinux_2_39_x86_64.whl
      … 13 older tag(s); ZOT_TAGS=0 for all
      latest
  atom-wheel  19.9 MB  (10 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  gfx1151   device-gfx1151   v0.1.9    10.1.0-full     19.9 MB  -                atom-0.1.9+rocm10.1.0-cp314-none-linux_x86_64.whl
      … 8 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.3 MB  (36 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  gfx1151   device-gfx1151   v14.2.0   10.1.0-full     41.3 MB  -                cupy-14.2.0-cp314-cp314-linux_x86_64.whl
      … 34 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  80.7 MB  (35 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  gfx1151   device-gfx1151   v0.33.0   10.1.0-full     80.7 MB  -                vllm-0.33.0+rocm101-cp314-cp314-linux_x86_64.whl
      … 33 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  8.6 MB  (36 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  gfx1151   device-gfx1151   v0.5.6    10.1.0-full      8.7 MB  -                lmcache-0.5.6-cp314-cp314-linux_x86_64.whl
      … 34 older tag(s); ZOT_TAGS=0 for all
      latest
```

