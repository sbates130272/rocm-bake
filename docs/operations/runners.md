# CI Runners

Pull-request checks run on GitHub-hosted runners — free, fork-safe,
needing nothing from the fleet. The nightly builds: a Docker daemon,
tens of GB of disk, hours of wall clock. This page is that machine;
[Building on AWS](aws.md) is its cost.

## SNOC Is Not It

The fleet is driven by hand and registers no runner: it holds the
registry, the compiler cache and the tailnet, and a runner there would
be one `docker` group membership from root on all three.

## AWS CodeBuild

CodeBuild is a managed build service billed per build-minute; EC2
compute mode gives privileged mode (so BuildKit has a daemon), up to
72 vCPU and 824 GB of SSD, and timeouts in hours.

It can also act as a **GitHub Actions runner**: it takes the
`WORKFLOW_JOB_QUEUED` webhook, registers an ephemeral runner for one
job, then terminates it. Workflows name it:

```yaml
runs-on:
  - codebuild-<project>-${{ github.run_id }}-${{ github.run_attempt }}
  - instance-size:xlarge
```

The trailing segments override image and instance size per job: one
project serves the matrix.

!!! note "Offline runners are the steady state"
    A CodeBuild runner exists for one job and goes `Offline` the moment
    it ends. An empty or all-offline runner list is healthy here.

The alternative is
[`philips-labs/terraform-aws-github-runner`](https://github.com/philips-labs/terraform-aws-github-runner):
a Lambda handler, launch template, builder AMI tracking
`ansible/roles/`, GitHub App, orphan sweep. CodeBuild is one project
and a webhook.

**EC2 compute mode, not Lambda compute mode.** Lambda allows no Docker
builds, no privileged mode, no caching and nothing over 15 minutes;
[Building on AWS](aws.md) has the table, and the measurement saying a
multi-node fleet would not have been faster anyway.

## Fork Pull Requests, And Why An `if:` Is Not The Boundary

A CodeBuild runner is self-hosted: it runs whatever the workflow says,
under the project's IAM role. The obvious guard is a job condition:

```yaml
# NOT sufficient on its own
if: github.event.pull_request.head.repo.full_name == github.repository
```

Worth having, not a boundary. `ci.yml` triggers on `pull_request`, not
`pull_request_target`, so the file that runs for a fork PR is **the
fork's copy**, and `.github/workflows/**` is inside its own `paths:`
filter — a fork edits the condition out in the same PR that exploits
it.

The repository is public; the controls that hold are outside the
workflow file:

1. **Require approval for all outside collaborators**, not just
   first-time contributors — the default lets a repeat author run
   unapproved.
2. **Filter the CodeBuild webhook** — an AWS-side control a fork cannot
   edit.
3. **Prefer scheduled and dispatch triggers.** A `schedule:` run uses
   the default branch's workflow file, which no fork can rewrite —
   hence Dockerfile checks in the nightly, not the PR gate.

GitHub's guidance is blunter: no self-hosted runners on public
repositories. Scope the IAM role as if a stranger's code will run on
it.

## Standing The Project Up

`.builders/codebuild-setup.sh` does it idempotently and prints the `gh
variable set` lines:

1. **A CodeBuild project** — type *Runner project*, provider *GitHub*,
   location *Repository* — on EC2 compute, privileged mode **on**.
2. **A webhook** on `WORKFLOW_JOB_QUEUED` — without it, no jobs.
3. **A service role** scoped to the ECR repositories and the S3 cache
   bucket, nothing more. The build does not need write access to this
   repository — the report is published by a separate GitHub-hosted
   job.
4. **Repository variables**, so the workflow needs no secrets:

```bash
gh variable set CODEBUILD_PROJECT --body <project-name>
gh variable set ECR_REGISTRY      --body <acct>.dkr.ecr.<region>.amazonaws.com
gh variable set AWS_REGION        --body <region>
gh variable set NIGHTLY_ARCHES    --body gfx1201        # optional
gh variable set NIGHTLY_ENABLED   --body true           # last
```

`NIGHTLY_ENABLED` is the off switch and belongs last: unset it and the
nightly's first job is skipped. `NIGHTLY_ARCHES` narrows the matrix, resolved
most-specific-first: `workflow_dispatch` input, then the variable, then
`ARCHES` in the Makefile.

Start at one architecture: three simultaneous failures are three times
the log for one cause and, at roughly $14 an arch, triple the bill.

## The Nightly

`.github/workflows/nightly.yml` runs at 02:17 UTC, one job per
architecture, each calling `.builders/nightly.sh` on a CodeBuild
machine. A GitHub-hosted job collects the reports, comments on one
`nightly`-labelled issue and publishes to
[data/nightly/](https://sbates130272.github.io/rocm-bake/data/nightly/).
It skips itself when `main` has not moved since the last successful
scheduled run — an unchanged tree is a bill with no result.

`nightly.sh` is deliberately not `perfrun.sh`: a rented machine has no
`balance.sh` over ssh, no `journalctl -u zot`, so it times bake
invocations and claims nothing more.

**The schedule is warm-only**, and warm — registry cache live — is what
publishes. A cold run pushes nothing and deletes its own sccache
prefix: a measurement for roughly double the bill, via
`-f run_cold=true`. When both run, cold goes first, or it reads what
the warm build wrote.

### Cache Errors Are Reported Separately From The Exit Code

Every `cache-to` carries `ignore-error=true`, so a rejected export
cannot fail an otherwise good build — but a night where *every* export
failed exits 0 with the next warm build secretly cold. The report
counts them separately: a green nightly with a climbing cache-error
count is the failure mode to watch.

### Where The Warmth Lives

Nothing on the machine survives the build. Two caches do.

**The registry cache is what makes a warm build warm.** `rocm-bake.hcl`
carries 39 `type=registry,mode=max` refs — every intermediate layer,
not just the final image's — which the next night imports from ECR.
Hence no `docker pull $REPO:nightly` plus `--cache-from`: a
single-image cache does strictly less.

**sccache on S3 is the object cache.** A rented machine cannot reach
the fleet's WebDAV endpoint, so the nightly sets `SCCACHE_BUCKET`,
which outranks `SCCACHE_WEBDAV_ENDPOINT` in the Dockerfiles; an empty
value counts as unset, so the same bake file serves the fleet.

`LOCAL_DOCKER_LAYER_CACHE` is free and worth enabling, but rarely
survives a 24-hour gap.
The **S3 zip cache must not be used for layers**: `target-costs` totals
17.6 GB per run, and shipping that around every build is the bottleneck
the registry cache avoids.

Two settings are not handled by the setup script.
`nightly.sh --ensure-ecr` creates missing repositories first — ECR does
not create one on push the way Zot does, and the failure lands at the
end of a long build — so the role needs `ecr:CreateRepository`. And set
**`REGISTRY_INSECURE=false`**: the bake file defaults it `true` for the
fleet's plain-HTTP Zot, and left that way against ECR every cache
export fails, hidden by `ignore-error=true`.

A full run is measured at **$13.94** for thirteen targets on one
architecture, with zero cache errors. See [Building on AWS](aws.md).
