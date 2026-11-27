# Warm parallel wheel build — 20261104T054722Z

- **started** Tue 03 Nov 2026 23:47:22 CST
- **arch** `gfx1250` · **commit** `bdf2333`
- **wall clock** 24m14s · **exit** 0
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
| snoc-gaming | 5% | 2% | 14.1GB | 22.7MB |
| snoc-strix | 20% | 6% | 18.3GB | 27.8GB |
| snoc-think | 100% | 13% | 77.9GB | 6.6GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| cupy-wheel | snoc-strix | 00:00:04 | 3m11s | 3m25s | 3m36s | -5% | 0/22 |
| triton-wheel | snoc-think | 00:00:04 | 1m51s | 8m05s | 7m46s | +4% | 2/23 |
| pytorch-wheel | snoc-think | 00:08:11 | 4m49s | 6m45s | 4m45s | +42% | 3/30 |
| pytorch | snoc-think | 00:14:57 | 19s | 48s | 51s | -6% | 2/22 |
| aiter-wheel | snoc-strix | 00:15:47 | 1m39s | 2m21s | 2m12s | +6% | 0/27 |
| nixl-wheel | snoc-think | 00:15:47 | 1m29s | 2m11s | 1m57s | +12% | 1/28 |
| lmcache-wheel | snoc-think | 00:18:00 | 1m08s | 1m45s | 1m27s | +20% | 3/31 |
| vllm-wheel | snoc-think | 00:19:46 | 2m39s | 4m27s | 4m16s | +4% | 4/36 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261104T052554Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 106 | 25.6MB | +10s | +21m59s |
| Zot blobs (layer cache) | 141 | 29.3GB | +2m00s | +24m14s |

## Published artifacts

```
  pytorch-wheel  343.3 MB  (33 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 23:03  gfx1201   device-gfx1201   2.15.0    10.1.0-full    382.9 MB  -                torch-2.15.0a0+git31a77fc-cp314-cp314-linux_x86_64.whl
      … 31 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  431.0 MB  (38 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 23:03  noarch    -                3.9.0     10.1.0-full    431.0 MB  -                triton-3.9.0+gitaad2a60d-cp314-cp314-linux_x86_64.whl
      … 36 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  133.7 MB  (25 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 23:03  gfx1201   device-gfx1201   2.15.0    10.1.0-full    133.5 MB  -                amd_aiter-0.1.29.dev0+gf1965cd26.d20261104-cp314-cp314-linux_x86_64.whl
      … 23 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  12.2 MB  (27 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 23:03  gfx1201   device-gfx1201   v1.5.2    10.1.0-full     12.2 MB  -                nixl-1.5.2-py3-none-any.whl
      … 25 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.5 MB  (26 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 23:03  gfx1201   device-gfx1201   v14.2.0   10.1.0-full     41.5 MB  -                cupy-14.2.0-cp314-cp314-linux_x86_64.whl
      … 24 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  63.0 MB  (25 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 23:03  gfx1201   device-gfx1201   v0.33.0   10.1.0-full     74.8 MB  -                vllm-0.33.0+rocm101-cp314-cp314-linux_x86_64.whl
      … 23 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  8.6 MB  (26 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-03 23:03  gfx1201   device-gfx1201   v0.5.6    10.1.0-full      8.7 MB  -                lmcache-0.5.6-cp314-cp314-linux_x86_64.whl
      … 24 older tag(s); ZOT_TAGS=0 for all
      latest
```

