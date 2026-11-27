# Cold parallel wheel build — 20261102T203308Z

- **started** Mon 02 Nov 2026 14:33:08 CST
- **arch** `gfx1201` · **commit** `2822a93`
- **wall clock** 21m55s · **exit** 0
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
| snoc-gaming | 3% | 1% | 14.2GB | 12.1MB |
| snoc-strix | 16% | 4% | 21.0GB | 19.0GB |
| snoc-think | 100% | 22% | 73.7GB | 2.8GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| cupy-wheel | snoc-strix | 00:00:02 | 0s | 6s | 3m07s | -97% | 11/22 |
| triton-wheel | snoc-think | 00:00:03 | 0s | 5s | 6m11s | -98% | 13/23 |
| pytorch-wheel | snoc-think | 00:00:09 | 5m52s | 7m31s | 20m44s | -64% | 5/26 |
| pytorch | snoc-think | 00:07:41 | 21s | 1m10s | 30s | +130% | 2/24 |
| aiter-wheel | snoc-strix | 00:08:52 | 43s | 1m21s | 46s | +77% | 0/26 |
| nixl-wheel | snoc-think | 00:08:52 | 1m30s | 2m03s | 2m27s | -16% | 1/28 |
| lmcache-wheel | snoc-think | 00:10:56 | 1m07s | 1m44s | 1m07s | +55% | 3/34 |
| vllm-wheel | snoc-think | 00:12:41 | 7m27s | 9m13s | 8m23s | +10% | 3/39 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261102T195216Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 423 | 128.3MB | +32s | +19m43s |
| Zot blobs (layer cache) | 142 | 19.6GB | +8s | +21m55s |

## Published artifacts

```
  pytorch-wheel  382.9 MB  (22 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-02 13:51  gfx1201   device-gfx1201   2.15.0    10.1.0-full    382.9 MB  -                torch-2.15.0a0+git31a77fc-cp314-cp314-linux_x86_64.whl
      … 20 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  431.0 MB  (27 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-02 13:51  noarch    -                3.9.0     10.1.0-full    431.0 MB  -                triton-3.9.0+gitaad2a60d-cp314-cp314-linux_x86_64.whl
      … 25 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  133.5 MB  (15 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-02 13:51  gfx1201   device-gfx1201   2.15.0    10.1.0-full    133.5 MB  -                amd_aiter-0.1.28-cp314-cp314-linux_x86_64.whl
      … 13 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  12.2 MB  (16 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-02 13:51  gfx1201   device-gfx1201   v1.5.2    10.1.0-full     12.2 MB  -                nixl-1.5.2-py3-none-any.whl
      … 14 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.5 MB  (12 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-02 13:51  gfx1201   device-gfx1201   v14.2.0   10.1.0-full     41.5 MB  -                cupy-14.2.0-cp314-cp314-linux_x86_64.whl
      … 10 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  74.8 MB  (14 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-02 13:51  gfx1201   device-gfx1201   v0.33.0   10.1.0-full     74.8 MB  -                vllm-0.33.0+rocm101-cp314-cp314-linux_x86_64.whl
      … 12 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  8.6 MB  (15 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-11-02 13:51  gfx1201   device-gfx1201   v0.5.6    10.1.0-full      8.7 MB  -                lmcache-0.5.6-cp314-cp314-linux_x86_64.whl
      … 13 older tag(s); ZOT_TAGS=0 for all
      latest
```

