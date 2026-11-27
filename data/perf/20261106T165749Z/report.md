# Warm parallel wheel build — 20261106T165749Z

- **started** Fri 06 Nov 2026 10:57:49 CST
- **arch** `gfx1250` · **commit** `a7daef0` (dirty)
- **wall clock** 41m45s · **exit** 0
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
| snoc-strix | 99% | 20% | 7.8GB | 16.1GB |
| snoc-think | 43% | 2% | 115.5GB | 1.9GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| triton-wheel | snoc-strix | 00:00:02 | 2s | 5m09s | 2m31s | +104% | 10/23 |
| cupy-wheel | snoc-think | 00:00:02 | 0s | 17s | 3m04s | -91% | 12/22 |
| pytorch-wheel | snoc-strix | 00:05:12 | 2s | 23m26s | - | - | 1/30 |
| pytorch | snoc-think | 00:28:40 | 0s | 1m09s | - | - | 2/22 |
| nixl-wheel | snoc-strix | 00:30:00 | 0s | 1m40s | - | - | 0/28 |
| atom-wheel | snoc-think | 00:30:01 | 2m45s | 4m43s | - | - | 1/30 |
| aiter-wheel | snoc-strix | 00:31:42 | 0s | 1m44s | - | - | 2/27 |
| lmcache-wheel | snoc-strix | 00:33:27 | 1m27s | 1m37s | - | - | 0/31 |
| torchvision-wheel | snoc-think | 00:34:45 | 0s | 42s | - | - | 1/26 |
| vllm-wheel | snoc-strix | 00:35:28 | 5m11s | 6m16s | - | - | 4/38 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261106T160458Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 708 | 189.9MB | +7m19s | +40m10s |
| Zot blobs (layer cache) | 185 | 26.5GB | +27m22s | +41m44s |

## Published artifacts

```
  pytorch-wheel  344.2 MB  (44 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  gfx1151   device-gfx1151   2.15.0    10.1.0-full    438.4 MB  -                torch-2.15.0a0+git31a77fc-cp314-cp314-linux_x86_64.whl
      … 42 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  431.0 MB  (43 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  noarch    -                3.9.0     10.1.0-full    431.0 MB  -                triton-3.9.0+gitaad2a60d-cp314-cp314-linux_x86_64.whl
      … 41 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  133.6 MB  (36 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  gfx1151   device-gfx1151   2.15.0    10.1.0-full    133.6 MB  -                amd_aiter-0.1.29.dev0+gf1965cd26.d20261105-cp314-cp314-linux_x86_64.whl
      … 34 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  12.2 MB  (38 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  gfx1151   device-gfx1151   v1.5.2    10.1.0-full     12.2 MB  -                nixl-1.5.2-py3-none-any.whl
      … 36 older tag(s); ZOT_TAGS=0 for all
      latest
  torchvision-wheel  1.6 MB  (16 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  gfx1151   device-gfx1151   v0.29.2   10.1.0-full      1.6 MB  -                torchvision-0.29.2+rocm10.1.0-py3-none-manylinux_2_39_x86_64.whl
      … 14 older tag(s); ZOT_TAGS=0 for all
      latest
  atom-wheel  19.9 MB  (12 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  gfx1151   device-gfx1151   v0.1.9    10.1.0-full     19.9 MB  -                atom-0.1.9+rocm10.1.0-cp314-none-linux_x86_64.whl
      … 10 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.5 MB  (37 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  gfx1151   device-gfx1151   v14.2.0   10.1.0-full     41.3 MB  -                cupy-14.2.0-cp314-cp314-linux_x86_64.whl
      … 35 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  63.0 MB  (36 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  gfx1151   device-gfx1151   v0.33.0   10.1.0-full     80.7 MB  -                vllm-0.33.0+rocm101-cp314-cp314-linux_x86_64.whl
      … 34 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  8.6 MB  (37 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-05 13:47  gfx1151   device-gfx1151   v0.5.6    10.1.0-full      8.7 MB  -                lmcache-0.5.6-cp314-cp314-linux_x86_64.whl
      … 35 older tag(s); ZOT_TAGS=0 for all
      latest
```

