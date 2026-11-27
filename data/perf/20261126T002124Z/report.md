# Warm parallel wheel build — 20261126T002124Z

- **started** Wed 25 Nov 2026 18:21:24 CST
- **arch** `gfx1250` · **commit** `f755c04`
- **wall clock** 35m32s · **exit** 0
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
| snoc-gaming | 25% | 2% | 12.5GB | 2.9GB |
| snoc-strix | 99% | 11% | 95.3GB | 11.2GB |
| snoc-think | 69% | 19% | 36.7GB | 79.5GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| triton-wheel | snoc-strix | 00:00:02 | 2m59s | 7m45s | 7m26s | +4% | 2/27 |
| cupy-wheel | snoc-think | 00:00:03 | 14m43s | 15m01s | 14m50s | +1% | 2/27 |
| pytorch-wheel | snoc-strix | 00:07:48 | 7m29s | 8m28s | 9m28s | -10% | 3/34 |
| pytorch | snoc-strix | 00:16:19 | 24s | 35s | 2m03s | -71% | 2/22 |
| torchvision-wheel | snoc-strix | 00:16:55 | 3m41s | 3m52s | 4m46s | -19% | 2/27 |
| aiter-wheel | snoc-think | 00:16:56 | 1m08s | 2m18s | 2m20s | -2% | 1/32 |
| nixl-wheel | snoc-gaming | 00:16:57 | 10m16s | 12m13s | 9m17s | +31% | 1/33 |
| atom-wheel | snoc-think | 00:19:15 | 4m35s | 5m42s | 5m48s | -2% | 2/33 |
| lmcache-wheel | snoc-strix | 00:29:10 | 1m41s | 1m53s | 2m12s | -14% | 3/35 |
| vllm-wheel | snoc-strix | 00:31:04 | 3m36s | 4m26s | 4m45s | -7% | 4/41 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261125T233651Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 145 | 33.7MB | +19s | +34m09s |
| Zot blobs (layer cache) | 202 | 22.9GB | +3m08s | +35m30s |

## Published artifacts

```
  pytorch-wheel  338.9 MB  (77 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-25 17:45  gfx1250   device-gfx1250   2.15.0    10.2.0-full    338.9 MB  -                torch-2.15.0a0+git31a77fc.rocm10.2.0-cp314-cp314-linux_x86_64.whl
      … 75 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  431.2 MB  (61 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-25 17:45  noarch    -                3.9.0     10.2.0-full    431.2 MB  -                triton-3.9.0+gitaad2a60d.rocm10.2.0-cp314-cp314-linux_x86_64.whl
      … 59 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  149.7 MB  (68 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-25 17:45  gfx1250   device-gfx1250   2.15.0    10.2.0-full    149.7 MB  -                amd_aiter-0.1.30+rocm10.2.0-cp314-cp314-linux_x86_64.whl
      … 66 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  13.7 MB  (71 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-25 17:45  gfx1250   device-gfx1250   v1.5.2    10.2.0-full     13.7 MB  -                nixl-1.5.2+rocm10.2.0-py3-none-any.whl
      … 69 older tag(s); ZOT_TAGS=0 for all
      latest
  torchvision-wheel  1.6 MB  (49 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-25 17:45  gfx1250   device-gfx1250   v0.29.2   10.2.0-full      1.6 MB  -                torchvision-0.29.2+rocm10.2.0-py3-none-manylinux_2_39_x86_64.whl
      … 47 older tag(s); ZOT_TAGS=0 for all
      latest
  atom-wheel  28.6 MB  (50 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-25 17:45  gfx1250   device-gfx1250   v0.1.10   10.2.0-full     28.6 MB  -                atom-0.1.10+rocm10.2.0-cp314-none-manylinux_2_38_x86_64.whl
      … 48 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.6 MB  (71 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-25 17:45  gfx1250   device-gfx1250   v14.2.0   10.2.0-full     41.6 MB  -                cupy-14.2.0+rocm10.2.0-cp314-cp314-manylinux_2_39_x86_64.whl
      … 69 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  67.1 MB  (72 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-25 17:45  gfx1250   device-gfx1250   v0.34.0   10.2.0-full     67.1 MB  -                vllm-0.34.0+rocm102-cp314-cp314-linux_x86_64.whl
      … 70 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  10.1 MB  (85 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-25 17:45  gfx1250   device-gfx1250   v0.5.8    10.2.0-full     10.1 MB  -                lmcache-0.5.8+rocm10.2.0-cp314-cp314-manylinux_2_39_x86_64.whl
      … 83 older tag(s); ZOT_TAGS=0 for all
      latest
```

