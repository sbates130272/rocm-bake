# Warm parallel wheel build — 20261104T164632Z

- **started** Wed 04 Nov 2026 10:46:32 CST
- **arch** `gfx1201` · **commit** `a311e86`
- **wall clock** 27m13s · **exit** 0
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
| snoc-gaming | 31% | 4% | 13.6GB | 3.5GB |
| snoc-strix | 19% | 6% | 19.2GB | 24.7GB |
| snoc-think | 99% | 8% | 103.8GB | 6.5GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| cupy-wheel | snoc-strix | 00:00:03 | 0s | 5s | 3m25s | -97% | 11/22 |
| triton-wheel | snoc-think | 00:00:03 | 1m51s | 7m55s | 8m05s | -2% | 2/23 |
| pytorch-wheel | snoc-think | 00:08:00 | 3m03s | 4m42s | 6m45s | -30% | 3/30 |
| pytorch | snoc-think | 00:12:43 | 19s | 47s | 48s | -2% | 2/22 |
| nixl-wheel | snoc-strix | 00:13:31 | 3m34s | 3m46s | 2m11s | +73% | 0/28 |
| torchvision-wheel | snoc-think | 00:13:31 | 26s | 1m15s | - | - | 2/26 |
| aiter-wheel | snoc-gaming | 00:13:32 | 3m58s | 8m42s | 2m21s | +270% | 2/27 |
| lmcache-wheel | snoc-think | 00:17:19 | 1m08s | 1m30s | 1m45s | -14% | 3/31 |
| vllm-wheel | snoc-think | 00:22:19 | 3m20s | 4m54s | 4m27s | +10% | 4/38 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261104T054722Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 24 | 5.5MB | +10s | +25m12s |
| Zot blobs (layer cache) | 92 | 11.6GB | +2m01s | +27m13s |

## Published artifacts

```
  pytorch-wheel  382.9 MB  (34 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-04 10:39  gfx1201   device-gfx1201   2.15.0    10.1.0-full    382.9 MB  -                torch-2.15.0a0+git31a77fc-cp314-cp314-linux_x86_64.whl
      … 32 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  431.0 MB  (39 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-04 10:39  noarch    -                3.9.0     10.1.0-full    431.0 MB  -                triton-3.9.0+gitaad2a60d-cp314-cp314-linux_x86_64.whl
      … 37 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  133.7 MB  (26 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-04 10:39  gfx1201   device-gfx1201   2.15.0    10.1.0-full    133.7 MB  -                amd_aiter-0.1.29.dev0+gf1965cd26.d20261104-cp314-cp314-linux_x86_64.whl
      … 24 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  12.2 MB  (28 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-04 10:39  gfx1201   device-gfx1201   v1.5.2    10.1.0-full     12.2 MB  -                nixl-1.5.2-py3-none-any.whl
      … 26 older tag(s); ZOT_TAGS=0 for all
      latest
  torchvision-wheel  1.6 MB  (5 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-04 10:39  gfx1201   device-gfx1201   v0.29.2   10.1.0-full      1.6 MB  -                torchvision-0.29.2+rocm10.1.0-py3-none-manylinux_2_39_x86_64.whl
      … 3 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.5 MB  (27 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-04 10:39  gfx1201   device-gfx1201   v14.2.0   10.1.0-full     41.5 MB  -                cupy-14.2.0-cp314-cp314-linux_x86_64.whl
      … 25 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  74.8 MB  (26 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-04 10:39  gfx1201   device-gfx1201   v0.33.0   10.1.0-full     74.8 MB  -                vllm-0.33.0+rocm101-cp314-cp314-linux_x86_64.whl
      … 24 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  8.6 MB  (27 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-04 10:39  gfx1201   device-gfx1201   v0.5.6    10.1.0-full      8.7 MB  -                lmcache-0.5.6-cp314-cp314-linux_x86_64.whl
      … 25 older tag(s); ZOT_TAGS=0 for all
      latest
```

