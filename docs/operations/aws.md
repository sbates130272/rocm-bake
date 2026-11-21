# Building On AWS

AWS runs one workflow for this repository, on two schedules. Monday to
Saturday is the nightly: a CodeBuild machine builds every target for
one architecture, pushes the images to ECR, and shares a compiler cache
on S3 with nothing else. Sunday is [the weekly](#the-weekly-build): the
same build for every architecture, followed by publishing the wheels.
There is no rented fleet, and no instance to stop.

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

## The Weekly Build

`nightly.yml` has a second schedule, Sunday 02:17 UTC, that differs
from the other six nights in three ways.

- **Every architecture**, from the `WEEKLY_ARCHES` repository variable
  or, unset, `ARCHES` in the Makefile. `NIGHTLY_ARCHES` is not
  consulted; it is what keeps the nightly to one.
- **Whether or not `main` moved.** A build has inputs no commit of ours
  records — the image behind a base tag, the Ubuntu archive — and the
  nightly's gate would skip them for ever.
- **It publishes.** When every architecture has built, each one's
  wheels are fetched from ECR and published by `wheels-publish.yml`,
  one architecture at a time. Wheels identical to the last published
  build upload nothing; wheels that differ become a new release beside
  it. One architecture failing holds back all of them.

Run the same shape by hand with the `weekly` input of the workflow's
dispatch form. Turn it off with `NIGHTLY_ENABLED`, which gates both.

The matrix runs one architecture at a time (`max-parallel: 1`),
because the account's quota is one concurrent `xlarge` build
(`L-04E5CA62`). GitHub does the queueing, not CodeBuild, and that
matters: a job's runner is a CodeBuild build started by a webhook sent
once, when the job is queued, and a build that then waits more than
the project's 60-minute queue timeout is failed. The first
four-architecture run queued all four at once; `gfx950` built in 65
minutes, the build queued behind it timed out at 60, and the remaining
jobs sat on GitHub with no runner coming. Raising the quota to four
would let the weekly finish in about an hour instead of four, at the
same cost; `max-parallel` in `nightly.yml` would rise with it.

!!! warning "Not yet measured"
    No weekly run has happened. Each architecture's cost should be a
    night's, from the table below — a few minutes when nothing moved,
    about a dollar for a version bump — but three of the four have
    never been built on this account at the current ROCm, so the first
    run is three cold builds. The publish step runs on `small` and has
    also never run; its sizing is an argument, not an observation.

### How A Pin Moves

The weekly is the last step of a loop that is otherwise two clicks.

1. **Monday**, `version-check.yml` compares every pin in
   `rocm-bake.hcl` with upstream. What is behind goes in the tracking
   issue, as before, and `versioncheck.py --bump` then makes the edit
   and opens a pull request on the `chore/version-bump` branch.
2. **A person** reads CI on it, pushes whatever the new version needs,
   and merges. Once the branch has a commit that is not the bot's,
   later runs comment on the pull request and stop rebuilding it.
3. **Sunday**, the weekly builds `main` and publishes.
4. **Monday**, `wheels-probe.yml` resolves every published index.

`ROCM_VERSION`, `UCX_REF` and the BuildKit pin are reported and never
moved automatically; `BUMP_HOLD` in `versioncheck.py` says why for
each. `make version-bump` makes the same edit in a working tree.

Two settings decide how much of step 1 is automatic. Opening a pull
request with the workflow's own token needs *Allow GitHub Actions to
create and approve pull requests* (Settings → Actions → General). And
GitHub starts no workflow for anything that token does, so CI does not
run on such a pull request until it is closed and reopened. Setting a
`BUMP_PR_TOKEN` secret — a fine-grained token with contents and
pull-requests write on this repository — removes that step.

## What A Night Costs

The lane runs on `instance-size:xlarge` — 36 vCPU / 72 GiB / 256 GB at
**$0.0798** a build-minute, against 2xlarge's 72 / 144 / 824 at
$0.200. Every figure below that predates 2026-11-12 was measured on
2xlarge and is marked as such.

| Scenario | Cost | Basis |
| --- | --- | --- |
| warm, one arch | ~$2.70 | 34 min, xlarge rate, not yet invoiced |
| warm, one arch (2xlarge) | $6.76 | measured 2026-11-12 |
| cold arch, first build | ~$4.34 | 54m24s gfx1151, xlarge rate |
| cold arch, first build (2xlarge) | $10.88 | measured 2026-11-12 |
| warm, three arches | ~$8 | 3× warm; arches are independent |

The schedule is **warm-only** and gated on `main` having moved, so a
quiet week bills nothing at all — 2026-11-08 and 11-09 both came to
$0.00. A cold run pushes nothing and deletes its own sccache prefix,
so it buys a measurement and nothing else: ask for it deliberately
with `-f run_cold=true`.

**ECR no longer rounds to nothing.** Billed storage reached 738 GB by
2026-11-11, about $74/month and growing ~79 GB a day, at which point it
exceeded CodeBuild on any day the gate skipped the build. See the
lifecycle section above; the rules that bound it landed 2026-11-12.

!!! warning "The xlarge rate is not yet invoice-confirmed"
    $0.0798/min comes from the Price List API, not a bill. The nightly
    report prints `(rate unverified)` next to the cost until it is
    confirmed and moved into `VERIFIED` in `nightly.sh`. Check Cost
    Explorer against a run before quoting these numbers.

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
