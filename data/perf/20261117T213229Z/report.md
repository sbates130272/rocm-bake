# Warm parallel wheel build — 20261117T213229Z

- **started** Tue 17 Nov 2026 15:32:29 CST
- **arch** `gfx1151` · **commit** `fcd5d44`
- **wall clock** 25m24s · **exit** 0
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
| snoc-strix | 100% | 14% | 6.1GB | 15.8GB |
| snoc-think | 100% | 39% | 72.0GB | 15.9GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| triton-wheel | snoc-strix | 00:00:02 | 2m24s | 7m20s | 7m24s | -1% | 2/27 |
| cupy-wheel | snoc-think | 00:00:03 | 6m33s | 7m16s | 4m23s | +66% | 1/27 |
| pytorch-wheel | snoc-strix | 00:07:24 | 2m49s | 4m02s | 4m40s | -13% | 4/34 |
| pytorch | snoc-think | 00:11:38 | 34s | 1m05s | 1m21s | -19% | 2/22 |
| nixl-wheel | snoc-strix | 00:12:55 | 1m54s | 2m04s | 1m48s | +15% | 1/30 |
| atom-wheel | snoc-think | 00:12:56 | 4m33s | 6m10s | 5m31s | +12% | 2/32 |
| aiter-wheel | snoc-strix | 00:15:01 | 48s | 1m27s | 1m20s | +9% | 3/32 |
| lmcache-wheel | snoc-strix | 00:16:29 | 1m18s | 1m31s | 1m40s | -9% | 3/34 |
| torchvision-wheel | snoc-strix | 00:18:01 | 18s | 29s | 29s | -3% | 2/26 |
| vllm-wheel | snoc-strix | 00:18:37 | 5m54s | 6m46s | 5m45s | +17% | 4/41 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261117T204334Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 141 | 129.1MB | +18s | +23m53s |
| Zot blobs (layer cache) | 209 | 25.4GB | +2m32s | +25m24s |

## Published artifacts

```
  pytorch-wheel  438.4 MB  (61 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:43  gfx1151   device-gfx1151   2.15.0    10.1.0-full    438.4 MB  -                torch-2.15.0a0+git31a77fc.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 59 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  431.2 MB  (52 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:43  noarch    -                3.9.0     10.1.0-full    431.2 MB  -                triton-3.9.0+gitaad2a60d.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 50 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  135.0 MB  (52 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:43  gfx1151   device-gfx1151   2.15.0    10.1.0-full    135.0 MB  -                amd_aiter-0.1.29.post2.dev0+gcfd296392.d20261117.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 50 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  12.2 MB  (55 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:43  gfx1151   device-gfx1151   v1.5.2    10.1.0-full     12.2 MB  -                nixl-1.5.2+rocm10.1.0-py3-none-any.whl
      … 53 older tag(s); ZOT_TAGS=0 for all
      latest
  torchvision-wheel  1.6 MB  (33 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:43  gfx1151   device-gfx1151   v0.29.2   10.1.0-full      1.6 MB  -                torchvision-0.29.2+rocm10.1.0-py3-none-manylinux_2_39_x86_64.whl
      … 31 older tag(s); ZOT_TAGS=0 for all
      latest
  atom-wheel  28.6 MB  (31 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:43  gfx1151   device-gfx1151   v0.1.10   10.1.0-full     28.6 MB  -                atom-0.1.10+rocm10.1.0-cp314-none-manylinux_2_38_x86_64.whl
      … 29 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.3 MB  (55 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:43  gfx1151   device-gfx1151   v14.2.0   10.1.0-full     41.3 MB  -                cupy-14.2.0+rocm10.1.0-cp314-cp314-manylinux_2_39_x86_64.whl
      … 53 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  85.1 MB  (55 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:43  gfx1151   device-gfx1151   v0.34.0   10.1.0-full     85.1 MB  -                vllm-0.34.0+rocm101-cp314-cp314-linux_x86_64.whl
      … 53 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  8.9 MB  (60 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:43  gfx1151   device-gfx1151   v0.5.7.post1 10.1.0-full      8.9 MB  -                lmcache-0.5.7.post1+rocm10.1.0-cp314-cp314-manylinux_2_39_x86_64.whl
      … 58 older tag(s); ZOT_TAGS=0 for all
      latest
```

