| phase | result | wall clock | cache errors |
| --- | --- | --- | --- |
| cold | skipped | — | — |
| warm | FAIL | 0m03s | 0 |

arch `gfx1151` · 15 targets · registry `472426151104.dkr.ecr.us-west-2.amazonaws.com` · cache suffix `-nightly`

<details><summary>last 40 lines of the failing phase</summary>

```
--- warm ---
#3 DONE 0.0s

#4 [pytorch-src] resolve image config for docker-image://docker.io/docker/dockerfile:1
#4 DONE 1.8s

#5 [pytorch-src] docker-image://docker.io/docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
#5 resolve docker.io/docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e done
#5 sha256:9d2b4f57f9e20f33279375ce25c6ff14f30f64270ed5c7b613b2b30256754f62 0B / 14.28MB 0.2s
#5 sha256:9d2b4f57f9e20f33279375ce25c6ff14f30f64270ed5c7b613b2b30256754f62 14.28MB / 14.28MB 0.6s done
#5 sha256:9d2b4f57f9e20f33279375ce25c6ff14f30f64270ed5c7b613b2b30256754f62 14.28MB / 14.28MB 0.6s done
#5 extracting sha256:9d2b4f57f9e20f33279375ce25c6ff14f30f64270ed5c7b613b2b30256754f62 0.1s done
#5 extracting sha256:9d2b4f57f9e20f33279375ce25c6ff14f30f64270ed5c7b613b2b30256754f62 0.1s done
#5 DONE 0.7s

#6 [auth] sharing credentials for 472426151104.dkr.ecr.us-west-2.amazonaws.com
#6 DONE 0.0s

#7 [rocm-runtime internal] load metadata for 472426151104.dkr.ecr.us-west-2.amazonaws.com/dockerhub/rocm/dev-ubuntu-26.04:10.1.0-full
#7 ERROR: unexpected status from HEAD request to https://472426151104.dkr.ecr.us-west-2.amazonaws.com/v2/dockerhub/rocm/dev-ubuntu-26.04/manifests/10.1.0-full: 403 Forbidden
denied: User: arn:aws:sts::472426151104:assumed-role/rocm-bake-codebuild-role/AWSCodeBuild-19a2d26c-10b7-4092-aec7-bccd609b3de0 is not authorized to perform: ecr:BatchGetImage on resource: arn:aws:ecr:us-west-2:472426151104:repository/dockerhub/rocm/dev-ubuntu-26.04 because no identity-based policy allows the ecr:BatchGetImage action

#8 [pytorch-src internal] load metadata for 472426151104.dkr.ecr.us-west-2.amazonaws.com/dockerhub/library/ubuntu:26.04
#8 ERROR: unexpected status from HEAD request to https://472426151104.dkr.ecr.us-west-2.amazonaws.com/v2/dockerhub/library/ubuntu/manifests/26.04: 403 Forbidden
denied: User: arn:aws:sts::472426151104:assumed-role/rocm-bake-codebuild-role/AWSCodeBuild-19a2d26c-10b7-4092-aec7-bccd609b3de0 is not authorized to perform: ecr:BatchGetImage on resource: arn:aws:ecr:us-west-2:472426151104:repository/dockerhub/library/ubuntu because no identity-based policy allows the ecr:BatchGetImage action
------
 > [pytorch-src internal] load metadata for 472426151104.dkr.ecr.us-west-2.amazonaws.com/dockerhub/library/ubuntu:26.04:
------
------
 > [rocm-runtime internal] load metadata for 472426151104.dkr.ecr.us-west-2.amazonaws.com/dockerhub/rocm/dev-ubuntu-26.04:10.1.0-full:
------
Dockerfile.rocm-runtime:24
--------------------
  22 |     
  23 |     # ─── Prune ───────────────────────────────────────────────────────
  24 | >>> FROM ${SDK_IMAGE} AS pruned
  25 |     
  26 |     ARG PYTORCH_ROCM_ARCH=gfx950
--------------------
ERROR: target rocm-runtime: failed to solve: unexpected status from HEAD request to https://472426151104.dkr.ecr.us-west-2.amazonaws.com/v2/dockerhub/rocm/dev-ubuntu-26.04/manifests/10.1.0-full: 403 Forbidden
denied: User: arn:aws:sts::472426151104:assumed-role/rocm-bake-codebuild-role/AWSCodeBuild-19a2d26c-10b7-4092-aec7-bccd609b3de0 is not authorized to perform: ecr:BatchGetImage on resource: arn:aws:ecr:us-west-2:472426151104:repository/dockerhub/rocm/dev-ubuntu-26.04 because no identity-based policy allows the ecr:BatchGetImage action
```

</details>
