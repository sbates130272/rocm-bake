# Warm parallel wheel build — 20261117T201441Z

- **started** Tue 17 Nov 2026 14:14:41 CST
- **arch** `gfx1201` · **commit** `3e9e8a4` (dirty)
- **wall clock** 16m26s · **exit** 0
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
| snoc-strix | 100% | 17% | 5.8GB | 6.5GB |
| snoc-think | 97% | 12% | 96.6GB | 20.8GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| triton-wheel | snoc-strix | 00:00:08 | 2s | 8s | 7m16s | -98% | 16/27 |
| cupy-wheel | snoc-think | 00:00:08 | 1m00s | 1m05s | 1m05s | +1% | 16/27 |
| pytorch-wheel | snoc-strix | 00:00:20 | 2m34s | 3m23s | 4m09s | -18% | 1/34 |
| pytorch | snoc-think | 00:03:44 | 1m10s | 1m37s | 1m34s | +3% | 1/22 |
| nixl-wheel | snoc-strix | 00:05:22 | 1m19s | 1m29s | 1m45s | -15% | 1/30 |
| atom-wheel | snoc-think | 00:05:22 | 4m33s | 5m37s | 4m06s | +37% | 1/32 |
| aiter-wheel | snoc-strix | 00:06:52 | 41s | 1m17s | 1m27s | -12% | 3/32 |
| lmcache-wheel | snoc-strix | 00:08:10 | 1m07s | 1m23s | 1m36s | -14% | 3/34 |
| torchvision-wheel | snoc-strix | 00:09:34 | 18s | 28s | 37s | -24% | 2/26 |
| vllm-wheel | snoc-strix | 00:10:14 | 5m21s | 6m11s | 3m40s | +69% | 4/41 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261113T155030Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 965 | 441.3MB | +1m09s | +15m00s |
| Zot blobs (layer cache) | 168 | 16.6GB | +15s | +16m25s |

## Published artifacts

```
  pytorch-wheel  383.9 MB  (59 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:03  gfx1201   device-gfx1201   2.15.0    10.1.0-full    383.9 MB  -                torch-2.15.0a0+git31a77fc.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 57 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  431.2 MB  (51 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:03  noarch    -                3.9.0     10.1.0-full    431.2 MB  -                triton-3.9.0+gitaad2a60d.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 49 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  135.0 MB  (50 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:03  gfx1201   device-gfx1201   2.15.0    10.1.0-full    135.0 MB  -                amd_aiter-0.1.29.post2.dev0+gcfd296392.d20261117.rocm10.1.0-cp314-cp314-linux_x86_64.whl
      … 48 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  12.2 MB  (53 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:03  gfx1201   device-gfx1201   v1.5.2    10.1.0-full     12.2 MB  -                nixl-1.5.2+rocm10.1.0-py3-none-any.whl
      … 51 older tag(s); ZOT_TAGS=0 for all
      latest
  torchvision-wheel  1.6 MB  (31 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:03  gfx1201   device-gfx1201   v0.29.2   10.1.0-full      1.6 MB  -                torchvision-0.29.2+rocm10.1.0-py3-none-manylinux_2_39_x86_64.whl
      … 29 older tag(s); ZOT_TAGS=0 for all
      latest
  atom-wheel  28.6 MB  (27 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:03  gfx1201   device-gfx1201   v0.1.10   10.1.0-full     28.6 MB  -                atom-0.1.10+rocm10.1.0-cp314-none-manylinux_2_38_x86_64.whl
      … 25 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.5 MB  (53 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:03  gfx1201   device-gfx1201   v14.2.0   10.1.0-full     41.5 MB  -                cupy-14.2.0+rocm10.1.0-cp314-cp314-manylinux_2_39_x86_64.whl
      … 51 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  79.7 MB  (51 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:03  gfx1201   device-gfx1201   v0.34.0   10.1.0-full     79.7 MB  -                vllm-0.34.0+rocm101-cp314-cp314-linux_x86_64.whl
      … 49 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  8.9 MB  (56 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-17 14:03  gfx1201   device-gfx1201   v0.5.7.post1 10.1.0-full      8.9 MB  -                lmcache-0.5.7.post1+rocm10.1.0-cp314-cp314-manylinux_2_39_x86_64.whl
      … 54 older tag(s); ZOT_TAGS=0 for all
      latest
```

