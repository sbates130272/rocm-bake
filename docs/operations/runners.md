# CI Runners

Every pull-request check in this repository runs on a GitHub-hosted
runner, and should: free for a public repository, fork-safe, and
nothing they do needs the fleet.

The nightly is different — it builds, which needs a Docker daemon, tens
of GB of disk and hours of wall clock. This page is about that machine.
[Building on AWS](aws.md) is about what it costs.

## SNOC Is Not It

The fleet is driven by hand and registers no runner. A GitHub Actions
job executing on those machines is not wanted: they hold the registry,
the compiler cache and the tailnet, and a runner process would be one
`docker` group membership away from root on all three.

## AWS CodeBuild

CodeBuild is a managed build service: you define a project, and AWS runs
your commands in a container on hardware it administers, billed per
build-minute. In EC2 compute mode it offers privileged mode (so BuildKit
has a daemon), up to 72 vCPU and 824 GB of SSD, and build timeouts
measured in hours.

It can also act as a **GitHub Actions runner**: it receives the
`WORKFLOW_JOB_QUEUED` webhook, starts a build, registers an ephemeral
runner for that one job, and terminates it afterwards. The workflow just
names it:

```yaml
runs-on:
  - codebuild-<project>-${{ github.run_id }}-${{ github.run_attempt }}
  - instance-size:2xlarge
```

The trailing segments override the project's image and instance size
per job, so one project serves every architecture in the matrix.

!!! note "Offline runners are the steady state"
    A CodeBuild runner exists for one job, and GitHub shows it
    `Offline` the moment that job ends. An empty or all-offline runner
    list is what a healthy configuration looks like here.

The alternative is a Lambda webhook handler, a launch template, a
builder AMI kept in step with `ansible/roles/`, a GitHub App to mint
registration tokens, and a sweep for instances whose job never arrived —
[`philips-labs/terraform-aws-github-runner`](https://github.com/philips-labs/terraform-aws-github-runner)
implements it properly. CodeBuild is one project and a webhook.

**EC2 compute mode, not Lambda compute mode.** CodeBuild's Lambda mode
allows no Docker builds, no privileged mode, no caching and nothing over
15 minutes. [Building on AWS](aws.md) has the full table, and the
measurement saying a multi-node fleet would not have been faster
anyway.

## Fork Pull Requests, And Why An `if:` Is Not The Boundary

A CodeBuild runner is self-hosted as far as GitHub is concerned: it
executes whatever the workflow tells it to, with the project's IAM role
attached, and a fork's pull request is code from outside the repository.
The obvious guard is a job-level condition:

```yaml
# NOT sufficient on its own
if: github.event.pull_request.head.repo.full_name == github.repository
```

That is worth having, and it is not a boundary. `ci.yml` triggers on
`pull_request`, not `pull_request_target`, so the workflow file that
runs for a fork PR is **the fork's copy** — and `.github/workflows/**`
is inside that file's own `paths:` filter. A fork can edit the condition
out in the same pull request that exploits it.

This repository is public, so the controls that actually hold are
outside the workflow file:

1. **Require approval for all outside collaborators**, not just
   first-time contributors. The default lets a second PR from the same
   author run unapproved.
2. **Filter the CodeBuild webhook** — an AWS-side control a fork cannot
   edit, which holds regardless of what the fork's workflow says.
3. **Prefer scheduled and dispatch triggers.** A `schedule:` run uses
   the default branch's workflow file, which no fork can rewrite. This
   is why the Dockerfile checks belong in the nightly, not the PR gate.

GitHub's own guidance is blunter: do not use self-hosted runners on
public repositories. Treat the project as a machine that may one day run
a stranger's code, and scope its IAM role accordingly.

## Standing The Project Up

`.builders/codebuild-setup.sh` does all of it, idempotently, and prints
the `gh variable set` lines at the end. What it creates:

1. **A CodeBuild project** — type *Runner project*, provider *GitHub*,
   location *Repository* — on EC2 compute with privileged mode **on**.
2. **A webhook** on `WORKFLOW_JOB_QUEUED`, which is what makes the
   project receive jobs at all.
3. **A service role** scoped to the ECR repositories and the S3 cache
   bucket, and nothing else. The build does not need write access to
   this repository — the nightly's report is published by a separate
   GitHub-hosted job.
4. **Repository variables**, so the workflow needs no secrets:

```bash
gh variable set CODEBUILD_PROJECT --body <project-name>
gh variable set ECR_REGISTRY      --body <acct>.dkr.ecr.<region>.amazonaws.com
gh variable set AWS_REGION        --body <region>
gh variable set NIGHTLY_ARCHES    --body gfx1201        # optional
gh variable set NIGHTLY_ENABLED   --body true           # last
```

`NIGHTLY_ENABLED` is the off switch and belongs last: unset it and the
nightly's first job is skipped. `NIGHTLY_ARCHES` narrows the matrix,
resolved most-specific-first from a `workflow_dispatch` input, then the
variable, then `ARCHES` in the Makefile.

Start at one architecture. Three simultaneous failures are three times
the log for one cause, and at roughly $14 an arch, three times the
bill.

## The Nightly

`.github/workflows/nightly.yml` runs at 02:17 UTC, one job per
architecture, each calling `.builders/nightly.sh` on a CodeBuild
machine. A separate GitHub-hosted job collects the reports, comments on
one `nightly`-labelled issue, and publishes to
[data/nightly/](https://sbates130272.github.io/rocm-bake/data/nightly/).
It skips itself when `main` has not moved since the last successful
scheduled run — a warm build of an unchanged tree is a bill with no
result.

`nightly.sh` is deliberately *not* `perfrun.sh`, which is a fleet
harness driving `balance.sh` over ssh and reading `journalctl -u zot`.
None of that exists on a rented machine, so `nightly.sh` times bake
invocations and claims nothing it cannot see.

**The schedule is warm-only.** Warm is an ordinary build with the
registry cache live, and the one that publishes. A cold run pushes
nothing and deletes its own sccache prefix, so it buys a measurement and
roughly doubles the bill; ask for it with `-f run_cold=true`. When both
run, cold goes first — the other way round and the "cold" build would
read what the warm build just wrote.

### Cache Errors Are Reported Separately From The Exit Code

Every `cache-to` carries `ignore-error=true`, which is the right
default: a registry that rejects a cache export should not fail a build
that otherwise succeeded. The cost is that a night where *every* export
failed still exits 0 and looks healthy, while the next warm build is
secretly cold. So the report counts them in their own column. A green
nightly with a climbing cache-error count is the failure mode to watch
for.

### Where The Warmth Lives

CodeBuild destroys the container when the build ends, so nothing on that
machine survives. Two caches do.

**The registry cache is what makes a warm build warm.** `rocm-bake.hcl`
carries 39 `type=registry,mode=max` refs — every intermediate layer, not
just the ones in the final image — and the next night imports them from
ECR. This is why the nightly does **not** use the common `docker pull
$REPO:nightly` plus `--cache-from` pattern: that is a single-image
cache, and BuildKit's registry exporter already does strictly more.

**sccache on S3 is the object cache.** Anything that does recompile
needs it, and a rented machine cannot reach the fleet's WebDAV endpoint,
so the nightly sets `SCCACHE_BUCKET` — which outranks
`SCCACHE_WEBDAV_ENDPOINT` in the Dockerfiles. An empty bucket name is
treated as unset, so the same bake file still serves the fleet.

`LOCAL_DOCKER_LAYER_CACHE` is free and worth enabling but rarely
survives a 24-hour gap. The **S3 zip cache must not be used for
layers**: `target-costs` totals 17.6 GB per run, and serialising a
compress-upload-download-decompress of that around every build is the
bottleneck the registry cache exists to avoid.

Two settings beyond the setup script matter. `nightly.sh --ensure-ecr`
creates missing repositories first — ECR does not create one on push the
way Zot does, and the failure lands at the end of a long build — so the
role needs `ecr:CreateRepository`. And **`REGISTRY_INSECURE=false`**:
the bake file defaults it `true` for the fleet's plain-HTTP Zot, and
left that way against ECR every cache export fails, hidden by
`ignore-error=true`.

A full run is measured at **$13.94** for thirteen targets on one
architecture, with zero cache errors. See [Building on AWS](aws.md).
