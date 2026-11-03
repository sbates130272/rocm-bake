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
gh variable set NIGHTLY_ENABLED   --body true
```

`NIGHTLY_ENABLED` is the off switch. Unset it and the nightly's first
job is skipped, so nothing queues against a project that is being
rebuilt or an account that is being cleaned up.

## What is still missing

There is no nightly workflow yet, and writing one needs two things
this repository does not have.

**A harness that runs on one machine.** `make perf-run` is a *fleet*
harness: it drives `balance.sh` across nodes over ssh, and reads
`journalctl -u zot`, `/var/log/nginx/sccache.log` and
`/var/cache/sccache-webdav/` locally with `sudo`. A CodeBuild runner
is one machine with none of those services, so `perf-run` there would
try to ssh to instances that do not exist and publish a report with
its registry and cache lanes empty.

`bench.sh` is the better fit — it already has named `cold` and `warm`
scenarios, runs targets serially with isolated caches, and resolves
its builder through `fleet.py --endpoint`, so a manifest whose single
node is `connection: local` makes it run entirely on the CodeBuild
machine. That manifest does not exist yet.

**Somewhere to put the layers and the objects.** A warm build is only
warm if its caches survive the machine, and CodeBuild machines do not.
That means the registry and the compiler cache move off the fleet —
ECR and S3 are the obvious answers, and both are already listed above
as the right moves on AWS, but neither is done.

Until those two land, the nightly stays a design rather than a
workflow.
