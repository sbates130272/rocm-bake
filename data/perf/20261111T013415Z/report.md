# Warm parallel wheel build — 20261111T013415Z

- **started** Tue 10 Nov 2026 19:34:15 CST
- **arch** `gfx1250` · **commit** `e3f1c3c`
- **wall clock** 22m17s · **exit** 0
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
| snoc-strix | 99% | 9% | 10.2GB | 7.9GB |
| snoc-think | 48% | 7% | 98.3GB | 8.1GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| triton-wheel | snoc-strix | 00:00:14 | 2m55s | 7m51s | 6m58s | +13% | 2/27 |
| cupy-wheel | snoc-think | 00:00:15 | 58s | 1m04s | 3m55s | -73% | 16/27 |
| pytorch-wheel | snoc-strix | 00:08:11 | 2m57s | 4m05s | 5m08s | -21% | 4/34 |
| pytorch | snoc-think | 00:12:18 | 27s | 52s | 57s | -8% | 2/22 |
| nixl-wheel | snoc-strix | 00:13:22 | 1m32s | 1m42s | 1m47s | -5% | 1/30 |
| atom-wheel | snoc-think | 00:13:23 | 2m48s | 3m47s | 3m47s | +0% | 1/32 |
| aiter-wheel | snoc-strix | 00:15:17 | 47s | 1m28s | 1m28s | +0% | 3/32 |
| lmcache-wheel | snoc-strix | 00:16:53 | 1m31s | 1m41s | 1m55s | -12% | 3/34 |
| torchvision-wheel | snoc-think | 00:17:12 | 20s | 34s | 33s | +1% | 2/26 |
| vllm-wheel | snoc-strix | 00:18:35 | 2m44s | 3m42s | 3m56s | -6% | 4/41 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261111T010231Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 18 | 5.2MB | +37s | +20m50s |
| Zot blobs (layer cache) | 183 | 22.0GB | +1m18s | +22m17s |

## Published artifacts

```
  pytorch-wheel  344.2 MB  (56 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  gfx1250   device-gfx1250   2.15.0    10.1.0-full    344.2 MB  -                torch-2.15.0a0+git31a77fc.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 54 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  431.2 MB  (49 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  noarch    -                3.9.0     10.1.0-full    431.2 MB  -                triton-3.9.0+gitaad2a60d.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 47 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  134.9 MB  (47 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  gfx1250   device-gfx1250   2.15.0    10.1.0-full    134.9 MB  -                amd_aiter-0.1.30.dev0+ga0c4b69c1.d20261111.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 45 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  12.2 MB  (49 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  gfx1250   device-gfx1250   v1.5.2    10.1.0-full     12.2 MB  -                nixl-1.5.2+rocm10.1.0-py3-none-any.whl
      … 47 older tag(s); ZOT_TAGS=0 for all
      latest
  torchvision-wheel  1.6 MB  (27 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  gfx1250   device-gfx1250   v0.29.2   10.1.0-full      1.6 MB  -                torchvision-0.29.2+rocm10.1.0-py3-none-manylinux_2_39_x86_64.whl
      … 25 older tag(s); ZOT_TAGS=0 for all
      latest
  atom-wheel  22.9 MB  (23 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  gfx1250   device-gfx1250   v0.1.9    10.1.0-full     22.9 MB  -                atom-0.1.9+rocm10.1.0-cp314-none-manylinux_2_38_x86_64.whl
      … 21 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.4 MB  (49 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  gfx1250   device-gfx1250   v14.2.0   10.1.0-full     41.5 MB  -                cupy-14.2.0+rocm10.1.0-cp314-cp314-manylinux_2_39_x86_64.whl
      … 47 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  63.0 MB  (47 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  gfx1250   device-gfx1250   v0.33.0   10.1.0-full     63.0 MB  -                vllm-0.33.0+rocm101-cp314-cp314-linux_x86_64.whl
      … 45 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  8.9 MB  (51 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-10 19:00  gfx1250   device-gfx1250   v0.5.7    10.1.0-full      8.9 MB  -                lmcache-0.5.7+rocm10.1.0-cp314-cp314-manylinux_2_39_x86_64.whl
      … 49 older tag(s); ZOT_TAGS=0 for all
      latest
```

