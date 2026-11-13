# Warm parallel wheel build — 20261111T010231Z

- **started** Tue 10 Nov 2026 19:02:31 CST
- **arch** `gfx950` · **commit** `e3f1c3c`
- **wall clock** 22m47s · **exit** 0
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
| snoc-strix | 99% | 9% | 8.1GB | 8.2GB |
| snoc-think | 39% | 5% | 96.6GB | 7.3GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| triton-wheel | snoc-strix | 00:00:02 | 2m04s | 6m58s | 7m38s | -9% | 2/27 |
| cupy-wheel | snoc-think | 00:00:02 | 3m38s | 3m55s | 51s | +354% | 1/27 |
| pytorch-wheel | snoc-strix | 00:07:05 | 4m01s | 5m08s | 8m26s | -39% | 4/34 |
| pytorch | snoc-think | 00:12:15 | 27s | 57s | 1m34s | -40% | 2/22 |
| nixl-wheel | snoc-strix | 00:13:24 | 1m37s | 1m47s | 2m19s | -22% | 1/30 |
| atom-wheel | snoc-think | 00:13:25 | 2m47s | 3m47s | 3m56s | -4% | 1/32 |
| aiter-wheel | snoc-strix | 00:15:19 | 49s | 1m28s | 1m38s | -10% | 3/32 |
| lmcache-wheel | snoc-strix | 00:16:54 | 1m45s | 1m55s | 1m47s | +7% | 3/34 |
| torchvision-wheel | snoc-think | 00:17:14 | 19s | 33s | 32s | +4% | 2/26 |
| vllm-wheel | snoc-strix | 00:18:50 | 2m52s | 3m56s | 4m11s | -6% | 4/41 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261110T233630Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 20 | 5.3MB | +10s | +21m13s |
| Zot blobs (layer cache) | 198 | 22.5GB | +2m12s | +22m46s |

## Published artifacts

```
  pytorch-wheel  340.5 MB  (55 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  gfx950    device-gfx950    2.15.0    10.1.0-full    340.5 MB  -                torch-2.15.0a0+git31a77fc.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 53 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  431.2 MB  (49 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  noarch    -                3.9.0     10.1.0-full    431.2 MB  -                triton-3.9.0+gitaad2a60d.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 47 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  135.0 MB  (46 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  gfx950    device-gfx950    2.15.0    10.1.0-full    135.0 MB  -                amd_aiter-0.1.30.dev0+ga0c4b69c1.d20261111.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 44 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  12.2 MB  (48 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  gfx950    device-gfx950    v1.5.2    10.1.0-full     12.2 MB  -                nixl-1.5.2+rocm10.1.0-py3-none-any.whl
      … 46 older tag(s); ZOT_TAGS=0 for all
      latest
  torchvision-wheel  1.6 MB  (26 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  gfx950    device-gfx950    v0.29.2   10.1.0-full      1.6 MB  -                torchvision-0.29.2+rocm10.1.0-py3-none-manylinux_2_39_x86_64.whl
      … 24 older tag(s); ZOT_TAGS=0 for all
      latest
  atom-wheel  22.9 MB  (22 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  gfx950    device-gfx950    v0.1.9    10.1.0-full     22.9 MB  -                atom-0.1.9+rocm10.1.0-cp314-none-manylinux_2_38_x86_64.whl
      … 20 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.2 MB  (48 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  gfx950    device-gfx950    v14.2.0   10.1.0-full     41.2 MB  -                cupy-14.2.0+rocm10.1.0-cp314-cp314-manylinux_2_39_x86_64.whl
      … 46 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  76.1 MB  (46 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  gfx950    device-gfx950    v0.33.0   10.1.0-full     76.1 MB  -                vllm-0.33.0+rocm101-cp314-cp314-linux_x86_64.whl
      … 44 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  8.9 MB  (49 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  gfx950    device-gfx950    v0.5.7    10.1.0-full      8.9 MB  -                lmcache-0.5.7+rocm10.1.0-cp314-cp314-manylinux_2_39_x86_64.whl
      … 47 older tag(s); ZOT_TAGS=0 for all
      latest
```

