# Building On AWS

AWS runs one thing for this repository: the nightly. A CodeBuild
machine builds every target for one architecture, pushes the images to
ECR, and shares a compiler cache on S3 with nothing else. There is no
rented fleet, and no instance to stop.

[CI runners](runners.md) covers the CodeBuild project itself — the
`runs-on` label, the webhook, the security boundary. This page is the
rest of the account, and what a night costs.

```bash
.builders/codebuild-setup.sh        # creates all of it, idempotently
```

## What The Account Holds

| | |
| --- | --- |
| CodeBuild project | One runner project, EC2 compute, privileged |
| ECR | 27 repositories — images plus their `*-cache` siblings |
| S3 | `rocm-bake-sccache-<account>`, 30-day object expiry |
| IAM | One service role, scoped to those two and nothing else |

Every repository carries a lifecycle policy that keeps the **three
newest untagged images** and never expires a tagged one. The `*-cache`
repositories hold BuildKit's `mode=max` exports — every intermediate
layer, not just the ones in the final image — and the artifact
repositories reuse mutable tags, so in both cases each push orphans its
predecessor and without a policy they grow without bound.

Untagged, by count, and never a tag: all three parts are load-bearing.

- **Untagged is what actually accumulates.** BuildKit only ever reads
  the tagged ref, so an orphaned cache manifest is dead weight from the
  moment it is created. Measured 2026-11-12: `pytorch-cache` held 16
  manifests, 14 of them untagged.
- **By count, not by age.** The policy here used to be `tagStatus: any,
  sinceImagePushed, 14 days`, which expires the live
  `latest-<arch>-nightly` tag along with the orphans. The
  has-main-moved gate already skips unchanged nights, so a quiet
  fortnight would have deleted the whole layer cache and left the next
  build silently cold.
- **Three, not one.** A run in flight may still be reading the
  generation it is about to replace, and one bad export should leave
  something to fall back to.

This matters more than it used to: billed ECR storage went from 264 GB
to 738 GB in the six days to 2026-11-11 — about +79 GB a day, a
$74/month run rate and climbing — and two cache repositories
(`atom-wheel-cache`, `torchvision-wheel-cache`, 347 GB between them)
had no policy at all, because they were added to the bake file after
`codebuild-setup.sh` was last run. Nothing re-applies these on its own;
re-run the script after adding a target.

The compiler cache is S3 because sccache speaks it natively and a
rented machine has no WebDAV endpoint to reach. `SCCACHE_BUCKET`
outranks `SCCACHE_WEBDAV_ENDPOINT` in the Dockerfiles, and an empty
bucket name is treated as unset — so the same bake file serves both
fleets, and the SNOC nodes keep nginx.

## What A Night Costs

Measured, on the first full run: **$13.94**.

| | |
| --- | --- |
| duration | 1h09m, 13 targets, `gfx1201` |
| billed | 69.7 min × $0.20/min |
| cache errors | 0 |

| Scenario | Cost | Basis |
| --- | --- | --- |
| warm, one arch | ~$14 | measured |
| warm, three arches | ~$42 | 3× measured; arches are independent |
| cold + warm, one arch | ~$28 | unmeasured; cold roughly doubles it |

The schedule is **warm-only**, which puts a quiet month at about $420
at one architecture. A cold run pushes nothing and deletes its own
sccache prefix, so it buys a measurement and nothing else — ask for it
deliberately with `-f run_cold=true`.

ECR and S3 round to nothing against that. Build minutes are the bill.

!!! note "Credential lifetime is the thing to watch"
    CodeBuild vends temporary credentials, and `nightly.sh` snapshots
    them with no refresh. A session lapsing mid-build turns every cache
    operation into a 403 — silently, because `ignore-error=true` hides
    it and the preflight has already passed. It held across 67 minutes.
    If a cold run ever pushes past about two hours, watch the
    cache-error column.

## Why Not A Rented Fleet

The obvious alternative is to rebuild the SNOC fleet on EC2 — three
large builders and a services node, scheduled by `balance.sh`. It was
specified and not built, for a measurable reason.

`balance.sh` resolves the targets into nine waves. Using the per-target
figures in
[`target-costs`](https://github.com/sbates130272/rocm-bake/blob/main/.builders/target-costs),
the total work is 9089 s and the sum of the wave maxima is 8835 s — a
parallelism headroom of roughly **1.03×**. The chain runs
`pytorch-base` → `triton-wheel` → `pytorch-wheel` → `pytorch` → … →
`vllm-wheel` → `vllm`, with two 2336 s targets in the middle of it. A
second builder buys almost nothing, and three idle instances cost the
same whether they build or not.

Fanning targets out also costs. On one machine `pytorch`'s inputs are
already in the local BuildKit store when it starts; across machines
that edge becomes a registry pull, and the cache rows in `target-costs`
total ~17.6 GB per run.

So the matrix axis is **architecture**, not target. `gfx950`, `gfx1201`
and `gfx1250` share no edges and no ordering, which is where splitting
the work actually buys something — and a CodeBuild job per architecture
gets it without owning an instance.

!!! note "Two caveats on those numbers"
    They are measured on `snoc-think` (32 cores), not on CodeBuild —
    absolute times differ, the shape does not. And `pytorch-wheel` and
    `pytorch` are both recorded at 2336 s, as are `vllm-wheel` and
    `vllm` at 1409 s, which looks like one compile attributed to two
    target names. If so the true critical path is shorter than 8835 s
    and the graph is *more* serial, not less.

## Why Lambda Is Not The Builder

A fleet that only exists while CI runs is the obvious next thought, and
the obvious implementation — a Lambda that runs the job — does not
work. Every limit is breached by a wide margin:

| Lambda limit | | A `pytorch-wheel` build |
| --- | --- | --- |
| 900 s per invocation | vs | hours |
| 10,240 MB memory | vs | 4 GiB per core across 48+ cores |
| 10,240 MB `/tmp` | vs | tens of GB of sources and objects |
| no Docker daemon | vs | BuildKit needs one |

The 15-minute ceiling cannot be raised by request. Lambda Managed
Instances reach 90 minutes for asynchronous invocations, still an order
of magnitude short, and the memory, storage and daemon problems remain.
Persistent storage does not rescue it either: Lambda can mount EFS, but
storage was never the binding constraint.

Two things that sound like escapes and are not: Lambda *layers* are not
Docker layers (five maximum, 250 MB unzipped), and Lambda's
container-image support means Lambda *running* an image, not *building*
one.

CodeBuild's own **Lambda compute mode** inherits all of it — AWS
documents it as supporting no Docker builds or runs, no privileged
mode, no caching and nothing over 15 minutes. The nightly needs EC2
compute mode.
