# Warm parallel wheel build — 20261104T052554Z

- **started** Tue 03 Nov 2026 23:25:54 CST
- **arch** `gfx1201` · **commit** `331544a`
- **wall clock** 21m14s · **exit** 0
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
| snoc-gaming | 7% | 2% | 14.0GB | 20.0MB |
| snoc-strix | 21% | 6% | 18.3GB | 19.9GB |
| snoc-think | 98% | 10% | 108.6GB | 6.6GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| cupy-wheel | snoc-strix | 00:00:03 | 3m21s | 3m36s | 3m08s | +15% | 0/22 |
| triton-wheel | snoc-think | 00:00:03 | 1m49s | 7m46s | 8m11s | -5% | 3/23 |
| pytorch-wheel | snoc-think | 00:07:50 | 3m02s | 4m45s | 4m57s | -4% | 3/30 |
| pytorch | snoc-think | 00:12:37 | 19s | 51s | 51s | +1% | 2/22 |
| aiter-wheel | snoc-strix | 00:13:30 | 1m34s | 2m12s | 2m02s | +9% | 0/27 |
| nixl-wheel | snoc-think | 00:13:30 | 1m31s | 1m57s | 1m54s | +2% | 1/28 |
| lmcache-wheel | snoc-think | 00:15:28 | 1m07s | 1m27s | 1m26s | +1% | 3/31 |
| vllm-wheel | snoc-think | 00:16:57 | 2m44s | 4m16s | 4m26s | -4% | 4/36 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261104T050340Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 11 | 5.2MB | +9s | +19m15s |
| Zot blobs (layer cache) | 103 | 15.9GB | +1m58s | +21m04s |

## Published artifacts

```
  pytorch-wheel  382.9 MB  (32 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 23:03  gfx1201   device-gfx1201   2.15.0    10.1.0-full    382.9 MB  -                torch-2.15.0a0+git31a77fc-cp314-cp314-linux_x86_64.whl
      … 30 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  431.0 MB  (38 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 23:03  noarch    -                3.9.0     10.1.0-full    431.0 MB  -                triton-3.9.0+gitaad2a60d-cp314-cp314-linux_x86_64.whl
      … 36 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  133.5 MB  (24 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 23:03  gfx1201   device-gfx1201   2.15.0    10.1.0-full    133.5 MB  -                amd_aiter-0.1.29.dev0+gf1965cd26.d20261104-cp314-cp314-linux_x86_64.whl
      … 22 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  12.2 MB  (26 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 23:03  gfx1201   device-gfx1201   v1.5.2    10.1.0-full     12.2 MB  -                nixl-1.5.2-py3-none-any.whl
      … 24 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.5 MB  (25 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 23:03  gfx1201   device-gfx1201   v14.2.0   10.1.0-full     41.5 MB  -                cupy-14.2.0-cp314-cp314-linux_x86_64.whl
      … 23 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  74.8 MB  (24 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 23:03  gfx1201   device-gfx1201   v0.33.0   10.1.0-full     74.8 MB  -                vllm-0.33.0+rocm101-cp314-cp314-linux_x86_64.whl
      … 22 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  8.6 MB  (25 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 23:03  gfx1201   device-gfx1201   v0.5.6    10.1.0-full      8.7 MB  -                lmcache-0.5.6-cp314-cp314-linux_x86_64.whl
      … 23 older tag(s); ZOT_TAGS=0 for all
      latest
```

