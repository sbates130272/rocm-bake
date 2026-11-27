## Nightly 2026-11-26

Build result: **failure**

### gfx1201

| phase | result | wall clock | cache errors |
| --- | --- | --- | --- |
| cold | skipped | — | — |
| warm | FAIL | 59m04s | 0 |

arch `gfx1201` · 15 targets · registry `472426151104.dkr.ecr.us-west-2.amazonaws.com` · cache suffix `-nightly`

<details><summary>last 40 lines of the failing phase</summary>

```
--- warm ---
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_S3_KEY_PREFIX") (line 50)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_WEBDAV_KEY_PREFIX") (line 55)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_S3_KEY_PREFIX") (line 70)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_WEBDAV_KEY_PREFIX") (line 70)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_S3_KEY_PREFIX") (line 45)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_WEBDAV_KEY_PREFIX") (line 50)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_S3_KEY_PREFIX") (line 94)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_WEBDAV_KEY_PREFIX") (line 94)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_S3_KEY_PREFIX") (line 78)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_WEBDAV_KEY_PREFIX") (line 79)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_S3_KEY_PREFIX") (line 100)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_WEBDAV_KEY_PREFIX") (line 100)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_S3_KEY_PREFIX") (line 50)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_WEBDAV_KEY_PREFIX") (line 63)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_S3_KEY_PREFIX") (line 117)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_WEBDAV_KEY_PREFIX") (line 117)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_WEBDAV_KEY_PREFIX") (line 115)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_S3_KEY_PREFIX") (line 159)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_S3_KEY_PREFIX") (line 161)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_WEBDAV_KEY_PREFIX") (line 161)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_WEBDAV_KEY_PREFIX") (line 200)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_S3_KEY_PREFIX") (line 308)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_S3_KEY_PREFIX") (line 310)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_WEBDAV_KEY_PREFIX") (line 310)
Dockerfile.torchvision:198
--------------------
 197 |     # the life of this instruction, so it never lands in image history.
 198 | >>> RUN --mount=type=secret,id=aws,required=false --mount=type=bind,source=docker/max-jobs.sh,target=/max-jobs.sh \
 199 | >>>     if [ -s /run/secrets/aws ]; then set -a; . /run/secrets/aws; set +a; fi; \
 200 | >>>     export BUILD_VERSION="${TORCHVISION_REF#v}+rocm${ROCM_VERSION%%-*}"; \
 201 | >>>     echo "BUILD_VERSION=${BUILD_VERSION}"; \
 202 | >>>     njobs="${MAX_JOBS}"; \
 203 | >>>     [ -n "${njobs}" ] || njobs="$(sh /max-jobs.sh "${MEM_PER_JOB_GB}" "${MEM_RESERVE_GB}" "${MAX_JOBS_CEILING}")"; \
 204 | >>>     export MAX_JOBS="${njobs}"; \
 205 | >>>     python setup.py bdist_wheel --dist-dir=/raw-wheels \
 206 | >>>     2>&1 | tee /wheels-build.log \
 207 | >>>     && sccache --show-stats | tee /wheels-torchvision-sccache-stats.txt
 208 |     
--------------------
ERROR: target torchvision-wheel: failed to solve: process "/bin/bash -o pipefail -c if [ -s /run/secrets/aws ]; then set -a; . /run/secrets/aws; set +a; fi;     export BUILD_VERSION=\"${TORCHVISION_REF#v}+rocm${ROCM_VERSION%%-*}\";     echo \"BUILD_VERSION=${BUILD_VERSION}\";     njobs=\"${MAX_JOBS}\";     [ -n \"${njobs}\" ] || njobs=\"$(sh /max-jobs.sh \"${MEM_PER_JOB_GB}\" \"${MEM_RESERVE_GB}\" \"${MAX_JOBS_CEILING}\")\";     export MAX_JOBS=\"${njobs}\";     python setup.py bdist_wheel --dist-dir=/raw-wheels     2>&1 | tee /wheels-build.log     && sccache --show-stats | tee /wheels-torchvision-sccache-stats.txt" did not complete successfully: exit code: 1
```

</details>


[Run](https://github.com/sbates130272/rocm-bake/actions/runs/45805882467)
