## Nightly 2026-11-12

Build result: **failure**

### gfx1151

| phase | result | wall clock | cache errors |
| --- | --- | --- | --- |
| cold | skipped | — | — |
| warm | FAIL | 0m02s | 0 |

arch `gfx1151` · 15 targets · registry `472426151104.dkr.ecr.us-west-2.amazonaws.com` · cache suffix `-nightly`

<details><summary>last 40 lines of the failing phase</summary>

```
--- warm ---
#2 DONE 0.0s

#3 [pytorch-src internal] load build definition from Dockerfile.pytorch-src
#3 transferring dockerfile: 3.55kB done
#3 DONE 0.0s

#4 [pytorch-src] resolve image config for docker-image://docker.io/docker/dockerfile:1
#4 DONE 0.7s

#5 [pytorch-src] docker-image://docker.io/docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
#5 resolve docker.io/docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e done
#5 sha256:9d2b4f57f9e20f33279375ce25c6ff14f30f64270ed5c7b613b2b30256754f62 14.28MB / 14.28MB 0.1s done
#5 sha256:9d2b4f57f9e20f33279375ce25c6ff14f30f64270ed5c7b613b2b30256754f62 14.28MB / 14.28MB 0.1s done
#5 extracting sha256:9d2b4f57f9e20f33279375ce25c6ff14f30f64270ed5c7b613b2b30256754f62 0.1s done
#5 extracting sha256:9d2b4f57f9e20f33279375ce25c6ff14f30f64270ed5c7b613b2b30256754f62 0.1s done
#5 DONE 0.2s

#6 [rocm-runtime internal] load metadata for docker.io/rocm/dev-ubuntu-26.04:10.1.0-full
#6 ...

#7 [pytorch-src internal] load metadata for docker.io/library/ubuntu:26.04
#7 ERROR: unexpected status from HEAD request to https://registry-1.docker.io/v2/library/ubuntu/manifests/26.04: 429 Too Many Requests

#6 [rocm-runtime internal] load metadata for docker.io/rocm/dev-ubuntu-26.04:10.1.0-full
#6 ERROR: unexpected status from HEAD request to https://registry-1.docker.io/v2/rocm/dev-ubuntu-26.04/manifests/10.1.0-full: 429 Too Many Requests
------
 > [rocm-runtime internal] load metadata for docker.io/rocm/dev-ubuntu-26.04:10.1.0-full:
------
------
 > [pytorch-src internal] load metadata for docker.io/library/ubuntu:26.04:
------
Dockerfile.pytorch-src:28
--------------------
  26 |     # the supply chain — every other Dockerfile here starts from Ubuntu or
  27 |     # from something built on it.
  28 | >>> FROM ubuntu:26.04 AS clone
  29 |     
  30 |     ARG PYTORCH_VERSION
--------------------
ERROR: target pytorch-src: failed to solve: unexpected status from HEAD request to https://registry-1.docker.io/v2/library/ubuntu/manifests/26.04: 429 Too Many Requests
```

</details>


[Run](https://github.com/sbates130272/rocm-bake/actions/runs/43302792576)
