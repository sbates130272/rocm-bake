# Nightly builds

Cold and warm bake invocations on a rented CodeBuild machine, one job per architecture.

> These are **not** comparable with the [instrumented fleet runs](../perf/). Those measure a parallel build across three nodes with a shared compiler cache; these measure sequential bakes on one machine.

| run | arch | cold | warm | cost | sccache | layer cache |
| --- | --- | --- | --- | --- | --- | --- |
| [20261106T102401Z](20261106T102401Z/) | `gfx1201` | — | 52m28s | $10.49 | 64% | 0/567 |
| [20261105T102024Z](20261105T102024Z/) | `gfx1201` | — | 43m05s | — | — | — |
| [20261104T063657Z](20261104T063657Z/) | `gfx1201` | — | 66m40s | — | — | — |

