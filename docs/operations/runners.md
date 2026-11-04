# CI runners

Every pull-request check in this repository runs on a GitHub-hosted
runner, and should. They are free for a public repository, they are
fork-safe, and nothing they do needs the fleet.

The nightly is different: it builds. That needs a Docker daemon, tens
of GB of disk and hours of wall clock, which is a machine someone has
to provide. This page is about that machine.

## SNOC is not it

The fleet is driven by hand — `make push-all`, `make perf-run` — and
registers no runner. `manifests/snoc.yml` declares no `runner`
capability, because a GitHub Actions job executing on those machines
is not wanted: they hold the registry, the compiler cache and the
tailnet, and a runner process would be one `docker` group membership
away from root on all three.

## AWS CodeBuild

CodeBuild is a managed build service: you define a project, and AWS
runs your commands in a container on hardware it administers, billed
per build-minute. In EC2 compute mode it offers privileged mode (so
BuildKit has a daemon), up to 72 vCPU and 824 GB of SSD, and build
timeouts measured in hours.

It can also act as a **GitHub Actions runner**. CodeBuild receives the
`WORKFLOW_JOB_QUEUED` webhook, starts a build, registers an ephemeral
runner for that one job, and terminates it afterwards. The workflow
just names it:

```yaml
runs-on:
  - codebuild-<project>-${{ github.run_id }}-${{ github.run_attempt }}
  - instance-size:2xlarge
```

The trailing segments override the project's configured image and
instance size per job, so one project serves every architecture in the
matrix.

!!! note "Offline runners are the steady state"
    A CodeBuild runner exists for one job. GitHub shows it as
    `Offline` the moment that job ends. An empty or all-offline runner
    list is what a healthy configuration looks like here.

### Why this rather than an EC2 fleet

The alternative in [A fleet on AWS](aws.md) is a Lambda webhook
handler, a launch template, a builder AMI kept in step with
`ansible/roles/`, a GitHub App to mint registration tokens, and a
sweep for instances whose job never arrived. CodeBuild is one project
and a webhook, and AWS maintains the parts that rot.

### Why not Lambda compute

CodeBuild offers a Lambda compute mode, and it cannot build this
repository. AWS documents it as supporting no Docker builds or runs,
no privileged mode, no caching, no EFS, nothing requiring root, no
writes outside `/tmp`, and no runtime over 15 minutes. That is the
same wall Lambda hits as a builder generally — persistent storage via
EFS does not move it, because storage was never the binding
constraint.

EC2 compute mode, not Lambda compute mode.

## Fork pull requests, and why an `if:` is not the boundary

A CodeBuild runner is a self-hosted runner as far as GitHub is
concerned. It executes whatever the workflow tells it to, with the
project's IAM role attached. A pull request from a fork is code from
outside the repository.

The obvious guard is a job-level condition:

```yaml
# NOT sufficient on its own
if: github.event.pull_request.head.repo.full_name == github.repository
```

That is worth having, and it is not a boundary. `ci.yml` triggers on
`pull_request`, not `pull_request_target`, so the workflow file that
runs for a fork PR is **the fork's copy** — and `.github/workflows/**`
is inside that file's own `paths:` filter. A fork can edit the
condition out in the same pull request that exploits it. The gate
protects against accident, not intent.

This repository is public, which makes the distinction load-bearing.
The controls that actually hold are outside the workflow file:

1. **Require approval for all outside collaborators**, not just
   first-time contributors — Settings → Actions → "Approval for
   running fork pull request workflows". The default lets a second PR
   from the same author run unapproved.
2. **Filter the CodeBuild webhook.** The project's webhook filter is
   an AWS-side control a fork cannot edit. Restrict it to the events
   and refs you intend, and it holds regardless of what the fork's
   workflow file says.
3. **Prefer scheduled and dispatch triggers.** A nightly on
   `schedule:` runs the default branch's workflow file, which no fork
   can rewrite. This is why the Dockerfile checks belong in the
   nightly rather than in the PR gate.

GitHub's own guidance is blunter: do not use self-hosted runners on
public repositories. Treat the CodeBuild project as a machine that may
one day run a stranger's code, and scope its IAM role accordingly.

## Standing the project up

None of this is provisioned by the repository. Once, in the AWS
account:

1. **Create a CodeBuild project**, type *Runner project*, runner
   provider *GitHub*, runner location *Repository*, pointed at
   `sbates130272/rocm-bake`.
2. **Environment**: EC2 compute, privileged mode **on** (BuildKit
   needs a daemon), an image with Docker and `make`.
3. **Webhook**: event type `WORKFLOW_JOB_QUEUED`. This is what makes
   the project receive jobs at all.
4. **Service role**: the build's identity. Scope it to the ECR
   repositories and S3 cache bucket the nightly uses, and nothing
   else. The build does not need, and should not have, write access to
   this repository — the nightly's report is published by a separate
   GitHub-hosted job.
5. **Repository variables**, so the workflow needs no secrets:

```bash
gh variable set CODEBUILD_PROJECT --body <project-name>
gh variable set ECR_REGISTRY      --body <acct>.dkr.ecr.<region>.amazonaws.com
gh variable set AWS_REGION        --body <region>
gh variable set NIGHTLY_ARCHES    --body gfx1201        # optional
gh variable set NIGHTLY_ENABLED   --body true           # last
```

`NIGHTLY_ENABLED` is the off switch, and belongs last. Unset it and the
nightly's first job is skipped, so nothing queues against a project
that is being rebuilt or an account that is being cleaned up.

`NIGHTLY_ARCHES` narrows the matrix. The arch list is resolved from
three places, most specific first:

| | |
| --- | --- |
| `workflow_dispatch` input | one run only |
| `NIGHTLY_ARCHES` variable | every scheduled run |
| `ARCHES` in the Makefile | the default, all three |

Start at one architecture. The first few nights are shaking out the
build image and the IAM role, and three simultaneous failures are
three times the log for the same single cause. Widen by setting the
variable — no commit, and no re-deciding it by hand on every dispatch,
which is how a temporary single-arch nightly quietly becomes a
three-arch bill.

## The nightly

`.github/workflows/nightly.yml` runs at 02:17 UTC, one job per
architecture, each calling `.builders/nightly.sh` on a CodeBuild
machine. A separate GitHub-hosted job collects the reports and files
them as a comment on one `nightly`-labelled issue — the same
one-issue-commented-on shape `version-check.yml` uses.

`nightly.sh` is deliberately *not* `perfrun.sh`. That one is a fleet
harness: it drives `balance.sh` across nodes over ssh and reads
`journalctl -u zot`, `/var/log/nginx/sccache.log` and
`/var/cache/sccache-webdav/` on the services node. None of that exists
on a rented machine, so running it there would ssh to instances that
do not exist and publish a report with its cache and registry lanes
empty. `nightly.sh` times two bake invocations and claims nothing it
cannot see.

Cold runs first and never pushes — `--no-cache` with every
`cache-from` cleared, so the previous night's export cannot leak in.
Warm is an ordinary build with the registry cache live, and it is the
one that publishes. Run them the other way round and the "cold" build
would be reading the cache the warm build had just written.

### Cache errors are reported separately from the exit code

Every `cache-to` in `rocm-bake.hcl` carries `ignore-error=true`, which
is the right default: a registry that rejects a cache export should
not fail a build that otherwise succeeded. The cost is that a night
where *every* export failed still exits 0 and looks healthy, while the
next warm build is secretly cold.

So the report counts them in their own column, and says so in prose
when the count is non-zero. A green nightly with a cache-error count
climbing is the failure mode to watch for.

### Where the warmth lives

CodeBuild destroys the container when the build ends, so nothing on
that machine survives to the next night. CodeBuild offers three
caching mechanisms, and only one of them is right here.

**Registry cache — what this uses.** `rocm-bake.hcl` already carries
39 `type=registry,mode=max` cache refs. `mode=max` exports *every*
intermediate layer, not just the ones in the final image, and the next
night imports them from ECR. Nothing is stored on the host, so the
container being destroyed costs nothing.

This is also why the nightly does **not** use the common
`docker pull $REPO:nightly || true` plus `docker build --cache-from`
pattern. That is the classic builder's single-image cache; BuildKit's
registry exporter already does strictly more, and swapping to it would
lose the intermediate layers that make a warm build warm.

**Local host cache — worth enabling anyway.** `LOCAL_DOCKER_LAYER_CACHE`
on the project (which needs privileged mode, already on) is free and
best-effort. It will rarely survive a 24-hour gap — AWS reallocates the
host — but it makes a same-day re-run or a dispatched retry much
cheaper. Enable it; just do not depend on it.

**S3 zip cache — do not use it for layers.** CodeBuild's S3 cache
zips the paths you name, uploads at the end and downloads at the
start. The cache rows in `.builders/target-costs` total **17.6 GB per
run**, with `triton-wheel` alone at 6.7 GB and `pytorch-wheel` at
5.1 GB, on top of an 8.67 GB base image layer. Serialising a
compress-upload-download-decompress of that around every build is the
bottleneck the registry cache exists to avoid.

!!! note "sccache is inert on CodeBuild, for now"
    The compiler cache here is **sccache**, not ccache, and it speaks
    `SCCACHE_WEBDAV_ENDPOINT` — nginx on the fleet's services node.
    A CodeBuild machine has no such endpoint, so the nightly gets
    *layer* reuse from ECR but no *object* reuse: anything that does
    recompile, recompiles from scratch.

    This is the one place S3 genuinely fits, and not via CodeBuild's
    zip cache — sccache speaks S3 natively through `SCCACHE_BUCKET`.
    Switching means changing `SCCACHE_WEBDAV_*` to `SCCACHE_S3_*`
    across `rocm-bake.hcl` and the Dockerfiles, which is the "real
    work, not configuration" that [the AWS page](aws.md) flags. Until
    then, expect the cold/warm gap to be wider here than on SNOC.

### What it needs in the account

Beyond the CodeBuild project above:

- **ECR repositories.** ECR does not create one on push the way Zot
  does, and the failure lands at the end of a long build rather than
  the start. `nightly.sh --ensure-ecr` creates the missing ones first;
  the project's role needs `ecr:CreateRepository` for that, or you can
  pre-create them and drop the flag.
- **`LOCAL_DOCKER_LAYER_CACHE`** on the project — free, best-effort,
  and no reason not to.
- **`REGISTRY_INSECURE=false`.** The bake file defaults it `true` for
  the fleet's plain-HTTP Zot. Left that way against ECR, every cache
  export fails — and `ignore-error=true` hides it, which is exactly
  what the column above exists to catch.
- **Repository variables**: `CODEBUILD_PROJECT`, `ECR_REGISTRY`,
  `AWS_REGION`, and `NIGHTLY_ENABLED=true`.

!!! warning "Unverified against real infrastructure"
    `nightly.sh` has been run locally — argument handling, target
    resolution, the report, and the cache-error detection all work.
    Nothing has run on CodeBuild, because the project does not exist
    yet. Expect the first run to surface missing tooling in the image
    and missing permissions on the service role.
