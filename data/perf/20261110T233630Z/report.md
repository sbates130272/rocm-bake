# Warm parallel wheel build — 20261110T233630Z

- **started** Tue 10 Nov 2026 17:36:30 CST
- **arch** `gfx1201` · **commit** `cd6c178` (dirty)
- **wall clock** 27m59s · **exit** 0
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
| snoc-strix | 99% | 10% | 5.5GB | 8.4GB |
| snoc-think | 54% | 12% | 94.9GB | 15.9GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| triton-wheel | snoc-strix | 00:00:02 | 2m47s | 7m38s | 7m27s | +2% | 2/27 |
| cupy-wheel | snoc-think | 00:00:02 | 46s | 51s | 3m24s | -75% | 16/27 |
| pytorch-wheel | snoc-strix | 00:07:47 | 7m17s | 8m26s | 13m09s | -36% | 3/34 |
| pytorch | snoc-think | 00:16:15 | 1m08s | 1m34s | 53s | +78% | 1/22 |
| nixl-wheel | snoc-strix | 00:17:50 | 2m08s | 2m19s | 1m40s | +39% | 1/30 |
| atom-wheel | snoc-think | 00:17:50 | 2m53s | 3m56s | 3m44s | +5% | 1/32 |
| aiter-wheel | snoc-strix | 00:20:10 | 56s | 1m38s | 1m18s | +25% | 3/32 |
| torchvision-wheel | snoc-strix | 00:21:58 | 22s | 32s | 35s | -9% | 2/26 |
| lmcache-wheel | snoc-think | 00:21:59 | 1m28s | 1m47s | 1m54s | -6% | 2/34 |
| vllm-wheel | snoc-strix | 00:23:46 | 3m07s | 4m11s | 3m55s | +7% | 3/41 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261109T220619Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 134 | 28.6MB | +26s | +26m16s |
| Zot blobs (layer cache) | 183 | 22.7GB | +54s | +27m58s |

## Published artifacts

```
  pytorch-wheel  383.9 MB  (54 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 17:25  gfx1201   device-gfx1201   2.15.0    10.1.0-full    383.9 MB  -                torch-2.15.0a0+git31a77fc.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 52 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  431.2 MB  (48 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 17:25  noarch    -                3.9.0     10.1.0-full    431.2 MB  -                triton-3.9.0+gitaad2a60d.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 46 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  134.9 MB  (45 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 17:25  gfx1201   device-gfx1201   2.15.0    10.1.0-full    134.9 MB  -                amd_aiter-0.1.30.dev0+ga0c4b69c1.d20261110.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 43 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  12.2 MB  (47 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 17:25  gfx1201   device-gfx1201   v1.5.2    10.1.0-full     12.2 MB  -                nixl-1.5.2+rocm10.1.0-py3-none-any.whl
      … 45 older tag(s); ZOT_TAGS=0 for all
      latest
  torchvision-wheel  1.6 MB  (25 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 17:25  gfx1201   device-gfx1201   v0.29.2   10.1.0-full      1.6 MB  -                torchvision-0.29.2+rocm10.1.0-py3-none-manylinux_2_39_x86_64.whl
      … 23 older tag(s); ZOT_TAGS=0 for all
      latest
  atom-wheel  22.9 MB  (21 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 17:25  gfx1201   device-gfx1201   v0.1.9    10.1.0-full     22.9 MB  -                atom-0.1.9+rocm10.1.0-cp314-none-manylinux_2_38_x86_64.whl
      … 19 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.5 MB  (47 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 17:25  gfx1201   device-gfx1201   v14.2.0   10.1.0-full     41.5 MB  -                cupy-14.2.0+rocm10.1.0-cp314-cp314-manylinux_2_39_x86_64.whl
      … 45 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  74.8 MB  (45 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 17:25  gfx1201   device-gfx1201   v0.33.0   10.1.0-full     74.8 MB  -                vllm-0.33.0+rocm101-cp314-cp314-linux_x86_64.whl
      … 43 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  8.9 MB  (47 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 17:25  gfx1201   device-gfx1201   v0.5.7    10.1.0-full      8.9 MB  -                lmcache-0.5.7+rocm10.1.0-cp314-cp314-manylinux_2_39_x86_64.whl
      … 45 older tag(s); ZOT_TAGS=0 for all
      latest
```

