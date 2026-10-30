# Cold parallel wheel build — 20261029T204149Z

- **arch** `gfx1201` · **commit** `15e12d7`
- **wall clock** 58m33s · **exit** 0
- **sample interval** 5s · **sccache prefix** `perf-20261029T204149Z`

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
| snoc-gaming | 43% | 10% | 603.7MB | 2.1GB |
| snoc-strix | 81% | 21% | 5.0GB | 4.5GB |
| snoc-think | 99% | 4% | 106.7GB | 1.4GB |

## Per-target build steps

| target | node | start | build | total | prev total | change | cached |
|---|---|---|---|---|---|---|---|
| pytorch-wheel | snoc-strix | 00:00:02 | 38m55s | 38m56s | 43m11s* | -10%* | 0 |
| vllm-wheel | snoc-think | 00:00:02 | 23m28s | 23m29s | 23m32s* | -0%* | 0 |
| aiter-wheel | snoc-gaming | 00:00:03 | 1m11s | 1m12s | 1m59s* | -40%* | 0 |
| nixl-wheel | snoc-strix | 00:39:00 | 3m00s | 3m00s | 2m29s* | +21%* | 0 |
| lmcache-wheel | snoc-think | 00:39:00 | 1m06s | 1m06s | 1m06s* | +1%* | 0 |
| triton-wheel | snoc-gaming | 00:39:01 | 16m27s | 16m28s | 16m05s* | +2%* | 0 |
| cupy-wheel | snoc-think | 00:55:31 | 3m02s | 3m02s | - | - | 0 |

*start* is elapsed from the beginning of this run, so it compares across runs. *build* is the span of the target's own steps; *total* is what the builder reported for it. The gap between them is setup plus cache export — which is why `change` is computed on *total*. A `*` marks a target whose previous run predates that measurement, so its comparison is build-vs-build and excludes the export on both sides.
*previous* is `20261029T184335Z`.

*buildkit transfer* is what BuildKit itself moved — context, layer pulls and exports. Downloads made **inside** a RUN step (apt, pip, git) are invisible to it and show up only in the node's network series above, which is why the two disagree.

## Cache writes

| stream | objects | bytes | first | last |
|---|---|---|---|---|
| sccache (compiler) | 5766 | 783.8MB | +1m32s | +58m26s |
| Zot blobs (layer cache) | 0 | - | - | - |

## Published artifacts

```
  pytorch-wheel  362.8 MB  (10 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-10-28 12:31  gfx1201   device-gfx1201   2.14.1    10.1.0-full    362.8 MB  -                torch-2.14.1a0+git5c48869-cp314-cp314-linux_x86_64.whl
      … 8 older tag(s); ZOT_TAGS=0 for all
      latest
  triton-wheel  397.8 MB  (17 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-10-28 18:26  noarch    -                3.8.0     10.1.0-full    397.8 MB  -                triton-3.8.0+git675c5987-cp314-cp314-linux_x86_64.whl
      … 15 older tag(s); ZOT_TAGS=0 for all
      latest
  aiter-wheel  131.1 MB  (6 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-10-28 18:26  gfx1201   device-gfx1201   2.14.1    10.1.0-full    131.1 MB  -                amd_aiter-0.1.27-cp314-cp314-linux_x86_64.whl
      … 4 older tag(s); ZOT_TAGS=0 for all
      latest
  nixl-wheel  12.2 MB  (4 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-10-28 12:31  gfx1201   device-gfx1201   v1.5.1    10.1.0-full     12.2 MB  -                nixl-1.5.1-py3-none-any.whl
      … 2 older tag(s); ZOT_TAGS=0 for all
      latest
  cupy-wheel  41.4 MB  (3 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-10-28 18:26  gfx1201   device-gfx1201   v14.2.0   10.1.0-full     41.4 MB  -                cupy-14.2.0-cp314-cp314-linux_x86_64.whl
      … 1 older tag(s); ZOT_TAGS=0 for all
      latest
  vllm-wheel  67.4 MB  (5 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-10-28 18:26  gfx1201   device-gfx1201   v0.32.0   10.1.0-full     67.4 MB  -                vllm-0.32.0+rocm101-cp314-cp314-linux_x86_64.whl
      … 3 older tag(s); ZOT_TAGS=0 for all
      latest
  lmcache-wheel  8.6 MB  (6 tags)
      published         arch      extra            version   rocm          size       build            wheel
      2026-10-28 18:26  gfx1201   device-gfx1201   v0.5.6    10.1.0-full      8.7 MB  -                lmcache-0.5.6-cp314-cp314-linux_x86_64.whl
      … 4 older tag(s); ZOT_TAGS=0 for all
      latest
```

