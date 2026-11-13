| phase | result | wall clock | cache errors |
| --- | --- | --- | --- |
| cold | skipped | — | — |
| warm | FAIL | 14m07s | 0 |

arch `gfx1201` · 15 targets · registry `472426151104.dkr.ecr.us-west-2.amazonaws.com` · cache suffix `-nightly`

<details><summary>last 40 lines of the failing phase</summary>

```
--- warm ---
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_WEBDAV_KEY_PREFIX") (line 56)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_S3_KEY_PREFIX") (line 91)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_WEBDAV_KEY_PREFIX") (line 91)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_WEBDAV_KEY_PREFIX") (line 166)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_S3_KEY_PREFIX") (line 202)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_S3_KEY_PREFIX") (line 204)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_WEBDAV_KEY_PREFIX") (line 204)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_S3_KEY_PREFIX") (line 74)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_S3_KEY_PREFIX") (line 46)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_S3_KEY_PREFIX") (line 41)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_WEBDAV_KEY_PREFIX") (line 51)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_WEBDAV_KEY_PREFIX") (line 75)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_WEBDAV_KEY_PREFIX") (line 46)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_S3_KEY_PREFIX") (line 61)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_S3_KEY_PREFIX") (line 93)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_S3_KEY_PREFIX") (line 43)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_WEBDAV_KEY_PREFIX") (line 61)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_S3_KEY_PREFIX") (line 82)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_WEBDAV_KEY_PREFIX") (line 93)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_WEBDAV_KEY_PREFIX") (line 56)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_WEBDAV_KEY_PREFIX") (line 82)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_S3_KEY_PREFIX") (line 105)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_WEBDAV_KEY_PREFIX") (line 105)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_WEBDAV_KEY_PREFIX") (line 95)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_S3_KEY_PREFIX") (line 111)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_S3_KEY_PREFIX") (line 113)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_WEBDAV_KEY_PREFIX") (line 113)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_WEBDAV_KEY_PREFIX") (line 191)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "SCCACHE_S3_KEY_PREFIX") (line 271)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_S3_KEY_PREFIX") (line 273)
 - SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ENV "SCCACHE_WEBDAV_KEY_PREFIX") (line 273)
Dockerfile.lmcache:298
--------------------
 296 |     # The multiprocess transport's gRPC stubs are generated into the wheel at
 297 |     # build time; importing the server module is what proves they landed.
 298 | >>> RUN python -c "import lmcache.v1.server.__main__; import lmcache.v1.api_server.__main__; print('MP entrypoints ok')"
 299 |     
 300 |     # No HSA_OVERRIDE_GFX_VERSION — see the note in Dockerfile.base. It was
--------------------
ERROR: target lmcache: failed to solve: process "/bin/sh -c python -c \"import lmcache.v1.server.__main__; import lmcache.v1.api_server.__main__; print('MP entrypoints ok')\"" did not complete successfully: exit code: 1
```

</details>
